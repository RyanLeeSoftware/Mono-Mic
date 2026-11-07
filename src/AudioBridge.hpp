#pragma once
#include "AudioDevices.hpp"
#include "MonoPipeline.hpp"
#include "Latency.hpp"
#include <AudioUnit/AudioUnit.h>
#include <array>
#include <atomic>
#include <chrono>
#include <string>

namespace mono {
class AudioBridge {
public:
    ~AudioBridge() { stop(); }
    void start(AudioDeviceID input, UInt32 channel, UInt32 requestedFrames);
    void stop();
    bool running() const { return running_; }
    bool configurationValid() const;
    double sampleRate() const { return sampleRate_; }
    std::string summary() const;
    const std::string &bufferNote() const { return bufferNote_; }
    std::optional<LatencyEstimate> latencyEstimate() const {
        auto estimate = latency_;
        if (estimate) estimate->queueMs = pipeline.queueLatencyFrames() * 1000.0 / sampleRate_;
        return estimate;
    }
    MonoPipeline pipeline;
    std::atomic<OSStatus> callbackError{noErr};
private:
    static constexpr UInt32 maxFrames = 4096;
    static OSStatus capture(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
    static OSStatus render(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
    void restoreBuffers();
    AudioUnit inputUnit_ = nullptr, outputUnit_ = nullptr;
    AudioDeviceID inputID_ = 0, outputID_ = 0;
    UInt32 inputFrames_ = 0, outputFrames_ = 0;
    UInt32 previousInputFrames_ = 0, previousOutputFrames_ = 0;
    bool changedInput_ = false, changedOutput_ = false, running_ = false;
    double sampleRate_ = 0, pendingRate_ = 0;
    double hostSecondsPerTick_ = 0;
    std::chrono::steady_clock::time_point rateRetryAfter_{};
    std::optional<LatencyEstimate> latency_;
    std::array<float, maxFrames> captureBuffer_{};
    std::array<float, maxFrames> outputBuffer_{};
    std::string inputName_, channelName_, bufferNote_;
};
}
