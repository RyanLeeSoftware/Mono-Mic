#pragma once
#include "Latency.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>

namespace mono {
// One producer (interface callback), one consumer (virtual-device callback).
// Never overwrites unread samples; neither callback allocates, waits or locks.
class MonoPipeline {
public:
    static constexpr uint64_t capacity = 8192;
    void setPeakSink(std::atomic<float> *sink) { peakSink_ = sink; }
    void setGainDb(double db) {
        if (!std::isfinite(db)) return;
        targetGain_.store(static_cast<float>(std::pow(10.0, std::clamp(db, -36.0, 12.0) / 20.0)), std::memory_order_relaxed);
    }
    void reset(uint32_t bufferFrames, double sampleRate = 48000, bool callbackTiming = false) {
        write_.store(0); read_.store(0);
        blockFrames_ = bufferFrames; sampleRate_ = sampleRate; timingEnabled_ = callbackTiming;
        target_ = bridgeQueueTarget(bufferFrames);
        targetFrames_.store(target_);
        rawAverage_ = target_; queueLatencyFrames_.store(static_cast<float>(target_));
        // Proportional control recenters the queue; integral control learns the
        // sustained clock mismatch without consuming the smaller queue's headroom.
        correctionGain_ = (callbackTiming ? 8192.0 : 1024.0) / std::max<uint32_t>(bufferFrames, 1);
        gainCoefficient_ = static_cast<float>(-std::expm1(-1.0 / (0.010 * sampleRate)));
        maximum_ = std::max<uint32_t>(target_ * 3, 1024);
        phase_ = 0; average_ = target_; clockCorrection_ = 0; primed_ = false;
        clockSequence_.store(0); clockFrameEnd_.store(0); clockSeconds_.store(-1); clockFrames_.store(0);
        cachedClockValid_ = false;
        underruns.store(0); overruns.store(0); resyncs.store(0);
        captured.store(0); rendered.store(0); buffered.store(0); ppm.store(0); peak.store(0);
        currentGain_ = targetGain_.load(std::memory_order_relaxed);
        if (peakSink_) peakSink_->store(0, std::memory_order_relaxed);
    }
    void push(const float *input, uint32_t count, double callbackSeconds = -1) noexcept {
        const auto w = write_.load(std::memory_order_relaxed);
        const auto r = read_.load(std::memory_order_acquire);
        if (count > capacity - (w - r)) { overruns.fetch_add(1, std::memory_order_relaxed); return; }
        float p = 0;
        const float targetGain = targetGain_.load(std::memory_order_relaxed);
        for (uint32_t i = 0; i < count; ++i) {
            float x = std::isfinite(input[i]) ? input[i] : 0;
            // A 10 ms ramp prevents clicks while moving the gain slider.
            currentGain_ += gainCoefficient_ * (targetGain - currentGain_);
            x *= currentGain_;
            samples_[(w + i) & (capacity - 1)] = x;
            p = std::max(p, std::abs(x));
        }
        if (timingEnabled_) {
            clockSequence_.fetch_add(1, std::memory_order_acq_rel);
            clockFrameEnd_.store(w + count, std::memory_order_relaxed);
            clockSeconds_.store(callbackSeconds, std::memory_order_relaxed);
            clockFrames_.store(count, std::memory_order_relaxed);
            clockSequence_.fetch_add(1, std::memory_order_release);
        }
        write_.store(w + count, std::memory_order_release);
        captured.fetch_add(count, std::memory_order_relaxed);
        float old = peak.load(std::memory_order_relaxed);
        while (p > old && !peak.compare_exchange_weak(old, p, std::memory_order_relaxed)) {}
        if (peakSink_) {
            old = peakSink_->load(std::memory_order_relaxed);
            while (p > old && !peakSink_->compare_exchange_weak(old, p, std::memory_order_relaxed)) {}
        }
    }
    void pull(float *output, uint32_t count, double callbackSeconds = -1) noexcept {
        auto r = read_.load(std::memory_order_relaxed);
        const auto w = write_.load(std::memory_order_acquire);
        auto available = w - r;
        double elapsed = 0;
        uint32_t captureFrames = 0;
        const bool timed = timingEnabled_ && clockPhase(w, callbackSeconds, elapsed, captureFrames);
        if (timingEnabled_) {
            blockFrames_ = std::max({blockFrames_, count, captureFrames});
            const uint32_t desiredTarget = timed ? timedBridgeQueueTarget(blockFrames_) : bridgeQueueTarget(blockFrames_);
            if (desiredTarget != target_) {
                // Increasing the safety margin requires refilling; only lower
                // it while priming, before a contiguous output stream begins.
                if (primed_ && desiredTarget > target_) {
                    primed_ = false; phase_ = 0;
                    resyncs.fetch_add(1, std::memory_order_relaxed);
                }
                if (!primed_) {
                    target_ = desiredTarget; average_ = target_;
                    targetFrames_.store(target_, std::memory_order_relaxed);
                }
            }
        }
        if (available > maximum_) {
            r = w - target_; phase_ = 0; average_ = target_;
            read_.store(r, std::memory_order_release);
            available = target_;
            resyncs.fetch_add(1, std::memory_order_relaxed);
        }
        buffered.store(static_cast<uint32_t>(available), std::memory_order_relaxed);
        const double phaseOffset = timed ? elapsed - captureFrames * 0.5 : 0;
        const auto desired = static_cast<uint32_t>(std::ceil(std::max<double>(count + 2, target_ - phaseOffset)));
        if (!primed_) {
            if (available < desired) {
                std::fill_n(output, count, 0.0f); return;
            }
            // Capture arrives in whole blocks. Start with the newest target
            // window instead of retaining the extra startup block indefinitely.
            r = w - desired;
            available = w - r;
            read_.store(r, std::memory_order_release);
            buffered.store(static_cast<uint32_t>(available), std::memory_order_relaxed);
            rawAverage_ = static_cast<double>(available);
            primed_ = true;
        }
        // Smooth callback ordering jitter before correcting independent device clocks.
        // Remove the normal rise/fall caused by the position between capture
        // callbacks, so feedback can detect drift before a whole block is late.
        average_ += 0.005 * (static_cast<double>(available) + phaseOffset - average_);
        rawAverage_ += 0.005 * (static_cast<double>(available) - rawAverage_);
        queueLatencyFrames_.store(static_cast<float>(rawAverage_), std::memory_order_relaxed);
        const double proportional = (average_ - target_) * correctionGain_;
        clockCorrection_ = std::clamp(clockCorrection_ + proportional / (timingEnabled_ ? 8192.0 : 1024.0), -1000.0, 1000.0);
        const double correction = std::clamp(proportional + clockCorrection_, -1000.0, 1000.0);
        const double step = 1.0 + correction * 0.000001;
        ppm.store(static_cast<float>(correction), std::memory_order_relaxed);
        const auto needed = static_cast<uint64_t>(std::floor(phase_ + (count ? count - 1 : 0) * step)) + 2;
        if (available < needed) {
            std::fill_n(output, count, 0.0f);
            primed_ = false;
            phase_ = 0; average_ = target_;
            underruns.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        double position = phase_;
        for (uint32_t i = 0; i < count; ++i, position += step) {
            const auto index = static_cast<uint64_t>(position);
            const float fraction = static_cast<float>(position - index);
            const float a = samples_[(r + index) & (capacity - 1)];
            const float b = samples_[(r + index + 1) & (capacity - 1)];
            output[i] = std::clamp(a + fraction * (b - a), -1.0f, 1.0f);
        }
        const auto consumed = static_cast<uint64_t>(position);
        phase_ = position - consumed;
        read_.store(r + consumed, std::memory_order_release);
        rendered.fetch_add(count, std::memory_order_relaxed);
    }
    std::atomic<uint64_t> underruns{0}, overruns{0}, resyncs{0}, captured{0}, rendered{0};
    std::atomic<uint32_t> buffered{0};
    std::atomic<float> ppm{0}, peak{0};
    uint32_t queueTargetFrames() const { return targetFrames_.load(std::memory_order_relaxed); }
    float queueLatencyFrames() const { return queueLatencyFrames_.load(std::memory_order_relaxed); }
private:
    bool clockPhase(uint64_t writeEnd, double now, double &elapsedFrames, uint32_t &captureFrames) noexcept {
        if (!std::isfinite(now) || now < 0) return false;
        const auto sequence = clockSequence_.load(std::memory_order_acquire);
        const auto end = clockFrameEnd_.load(std::memory_order_relaxed);
        const auto seconds = clockSeconds_.load(std::memory_order_relaxed);
        const auto frames = clockFrames_.load(std::memory_order_relaxed);
        // Keep payload reads before the closing sequence check on ARM as well
        // as x86; a changed sequence means the snapshot raced the producer.
        std::atomic_thread_fence(std::memory_order_acquire);
        const auto after = clockSequence_.load(std::memory_order_relaxed);
        if (!(sequence & 1) && sequence == after && end == writeEnd) {
            cachedClockValid_ = frames && std::isfinite(seconds) && seconds >= 0;
            if (cachedClockValid_) {
                cachedFrameEnd_ = end; cachedSeconds_ = seconds; cachedFrames_ = frames;
            }
        }
        // Never spin waiting for the capture thread. A racing publication can
        // use the preceding timestamp for at most two input blocks.
        if (!cachedClockValid_ || writeEnd < cachedFrameEnd_ || writeEnd - cachedFrameEnd_ > 2 * cachedFrames_)
            return false;
        const double latest = cachedSeconds_ + (writeEnd - cachedFrameEnd_) / sampleRate_;
        const double elapsed = (now - latest) * sampleRate_;
        if (elapsed < -0.25 * cachedFrames_ || elapsed > 2.0 * cachedFrames_) return false;
        elapsedFrames = std::max(0.0, elapsed); captureFrames = cachedFrames_;
        return true;
    }
    static_assert(std::atomic<uint64_t>::is_always_lock_free);
    static_assert(std::atomic<float>::is_always_lock_free);
    static_assert(std::atomic<double>::is_always_lock_free);
    alignas(64) std::atomic<uint64_t> write_{0};
    alignas(64) std::atomic<uint64_t> read_{0};
    alignas(64) std::array<float, capacity> samples_{};
    uint32_t target_ = bridgeQueueTarget(128), maximum_ = 1024;
    std::atomic<uint32_t> targetFrames_{bridgeQueueTarget(128)};
    std::atomic<float> queueLatencyFrames_{static_cast<float>(bridgeQueueTarget(128))};
    std::atomic<uint64_t> clockSequence_{0}, clockFrameEnd_{0};
    std::atomic<double> clockSeconds_{-1};
    std::atomic<uint32_t> clockFrames_{0};
    uint32_t blockFrames_ = 128, cachedFrames_ = 0;
    uint64_t cachedFrameEnd_ = 0;
    double sampleRate_ = 48000, cachedSeconds_ = 0;
    bool timingEnabled_ = false, cachedClockValid_ = false;
    double phase_ = 0, average_ = bridgeQueueTarget(128), correctionGain_ = 8, clockCorrection_ = 0;
    double rawAverage_ = bridgeQueueTarget(128);
    bool primed_ = false;
    std::atomic<float> targetGain_{1};
    float currentGain_ = 1;
    float gainCoefficient_ = 0.0020811647f;
    std::atomic<float> *peakSink_ = nullptr;
};
}
