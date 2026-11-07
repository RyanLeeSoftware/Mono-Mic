#include "../src/MonoPipeline.hpp"
#include <cassert>
#include <iostream>
#include <limits>
#include <thread>
#include <vector>

static void drift(double driftPPM, uint32_t blockSize, uint32_t rate = 48000, uint32_t seconds = 600, bool timed = false) {
    mono::MonoPipeline pipeline;
    pipeline.reset(blockSize, rate, timed);
    std::vector<float> input(blockSize), output(blockSize);
    uint64_t frame = 0;
    double nextCapture = 0;
    const double period = blockSize / (1.0 + driftPPM * 1e-6);
    // Ten minutes of independent clocks, with input arriving in real callback blocks.
    for (uint32_t callback = 0; callback < rate * seconds / blockSize; ++callback) {
        const double time = static_cast<double>(callback) * blockSize;
        while (nextCapture <= time) {
            for (uint32_t i = 0; i < blockSize; ++i, ++frame) input[i] = 0.5f * std::sin(frame * 0.03);
            pipeline.push(input.data(), blockSize, timed ? nextCapture / rate : -1);
            nextCapture += period;
        }
        pipeline.pull(output.data(), blockSize, timed ? time / rate : -1);
        for (float value : output) assert(std::isfinite(value) && std::abs(value) <= 0.501f);
    }
    assert(pipeline.underruns == 0);
    assert(pipeline.overruns == 0);
    assert(pipeline.resyncs == 0);
    assert(pipeline.rendered > rate * seconds * 0.99);
    std::cout << seconds << "-second clock simulation at " << rate << " Hz, " << blockSize << " samples, " << driftPPM << " ppm: no underruns; queue "
              << pipeline.buffered << " frames; correction " << pipeline.ppm << " ppm\n";
}
static double callbackDelay(uint64_t index, uint32_t salt, uint32_t frames) {
    // Reproducible scheduling delays up to a fifth of a callback period.
    uint32_t noise = static_cast<uint32_t>(index) * 1664525u + salt;
    noise ^= noise >> 16; noise *= 2246822519u; noise ^= noise >> 13;
    return (noise / 4294967295.0) * frames * 0.2;
}
static void jitter(double driftPPM, uint32_t inputFrames, uint32_t outputFrames, double phase, bool timed = false) {
    constexpr uint32_t rate = 48000, seconds = 120;
    mono::MonoPipeline pipeline;
    pipeline.reset(std::max(inputFrames, outputFrames), rate, timed);
    std::vector<float> input(inputFrames, 0.25f), output(outputFrames);
    uint64_t capture = 0;
    const double inputPeriod = inputFrames / (1.0 + driftPPM * 1e-6);
    auto captureTime = [&] {
        return phase * inputFrames + capture * inputPeriod + callbackDelay(capture, 1013904223u, inputFrames);
    };
    double nextCapture = captureTime();
    uint32_t minimum = UINT32_MAX, maximum = 0;
    for (uint32_t callback = 0; callback < rate * seconds / outputFrames; ++callback) {
        const double time = static_cast<double>(callback) * outputFrames + callbackDelay(callback, 2654435761u, outputFrames);
        while (nextCapture <= time) {
            pipeline.push(input.data(), inputFrames, timed ? nextCapture / rate : -1); ++capture; nextCapture = captureTime();
        }
        pipeline.pull(output.data(), outputFrames, timed ? time / rate : -1);
        if (pipeline.rendered) {
            minimum = std::min(minimum, pipeline.buffered.load());
            maximum = std::max(maximum, pipeline.buffered.load());
        }
        for (float value : output) assert(value == 0 || value == 0.25f);
    }
    std::cout << "Jitter simulation " << inputFrames << "/" << outputFrames << " samples, "
              << driftPPM << " ppm, phase " << phase << ": queue " << minimum << "–" << maximum
              << ", underruns " << pipeline.underruns << std::endl;
    assert(pipeline.underruns == 0 && pipeline.overruns == 0 && pipeline.resyncs == 0);
    assert(pipeline.rendered > rate * seconds * 0.99);
}
int main() {
    {
        mono::MonoPipeline p; p.reset(32, 48000, true);
        float input[32], output[32]; std::fill_n(input, 32, 0.25f);
        for (int i = 0; i < 3; ++i) p.push(input, 32, i * 32.0 / 48000);
        p.pull(output, 32, 64.0 / 48000);
        assert(p.queueTargetFrames() == 66 && p.buffered == 82);
        // Report the actual raw queue delay, not the phase-normalized target.
        assert(p.queueLatencyFrames() == 82);
        for (float sample : output) assert(sample == 0.25f);
        p.push(input, 32); // Missing timing keeps the same two-block margin.
        p.pull(output, 32, 96.0 / 48000);
        assert(p.queueTargetFrames() == 66 && p.resyncs == 0 && p.underruns == 0);
        for (float sample : output) assert(sample == 0.25f);
    }
    {
        mono::MonoPipeline p; p.reset(32);
        float input[96], output[32];
        for (int i = 0; i < 96; ++i) input[i] = i / 128.0f;
        p.push(input, 96); p.pull(output, 32);
        // Start exactly 66 samples behind capture, rather than holding the
        // entire third capture block while waiting for clock correction.
        for (int i = 0; i < 32; ++i) assert(output[i] == (i + 30) / 128.0f);
        assert(p.buffered == 66 && p.underruns == 0 && p.resyncs == 0);
    }
    {
        mono::MonoPipeline p; p.reset(64);
        float output[64]; p.pull(output, 64);
        for (float v : output) assert(v == 0);
        assert(p.underruns == 0); // Intentional startup silence isn't a dropout.
        float input[256]; std::fill_n(input, 256, 0.375f);
        p.push(input, 256); p.pull(output, 64);
        for (float v : output) assert(std::abs(v - 0.375f) < 0.000001f); // No attenuation.
    }
    {
        mono::MonoPipeline p; p.reset(128);
        float input[512], output[128];
        std::fill_n(input, 512, std::numeric_limits<float>::quiet_NaN());
        p.push(input, 512); p.pull(output, 128);
        for (float v : output) assert(v == 0);
        p.reset(128); std::fill_n(input, 512, 2.0f);
        p.push(input, 512); p.pull(output, 128);
        for (float v : output) assert(v == 1.0f);
    }
    {
        mono::MonoPipeline p; p.reset(128);
        std::vector<float> input(8192, 0.5f); float output[128];
        p.push(input.data(), 8192); p.push(input.data(), 1);
        assert(p.overruns == 1);
        p.pull(output, 128);
        assert(p.resyncs == 1); // Recovery drops stale audio instead of adding latency.
        for (float v : output) assert(v == 0.5f);
    }
    for (uint32_t blockSize : {32, 64, 128, 256})
        for (double ppm : {0.0, -100.0, 100.0, -350.0, 350.0}) drift(ppm, blockSize);
    for (uint32_t rate : {44100, 96000, 192000})
        for (double ppm : {-350.0, 350.0}) drift(ppm, 32, rate, 120);
    for (uint32_t blockSize : {32, 64, 128, 256})
        for (double ppm : {-350.0, 0.0, 350.0})
            for (double phase : {0.0, 0.25, 0.5, 0.75}) jitter(ppm, blockSize, blockSize, phase);
    // Actual input and output devices may accept different buffer sizes.
    for (double ppm : {-350.0, 350.0}) {
        jitter(ppm, 32, 128, 0.5);
        jitter(ppm, 128, 32, 0.5);
    }
    for (uint32_t blockSize : {32, 64, 128, 256}) {
        for (double ppm : {-350.0, -100.0, 0.0, 100.0, 350.0}) drift(ppm, blockSize, 48000, 600, true);
        for (double ppm : {-350.0, 0.0, 350.0})
            for (double phase : {0.0, 0.25, 0.5, 0.75}) jitter(ppm, blockSize, blockSize, phase, true);
    }
    for (uint32_t rate : {44100, 96000, 192000})
        for (double ppm : {-350.0, 350.0}) drift(ppm, 32, rate, 120, true);
    for (double ppm : {-350.0, 350.0}) {
        jitter(ppm, 32, 128, 0.5, true); jitter(ppm, 128, 32, 0.5, true);
    }
    for (bool timed : {false, true}) {
        mono::MonoPipeline p; p.reset(128, 48000, timed);
        // Exercise acquire/release publication with callbacks on independent threads.
        std::thread producer([&] {
            float block[128]; std::fill_n(block, 128, 0.25f);
            for (int i = 0; i < 200000; ++i) {
                p.push(block, 128, timed ? i * 128.0 / 48000 : -1);
                if (i % 32 == 0) std::this_thread::yield();
            }
        });
        std::thread consumer([&] {
            float block[128];
            for (int i = 0; i < 200000; ++i) {
                p.pull(block, 128, timed ? i * 128.0 / 48000 : -1);
                for (float value : block) assert(value == 0 || value == 0.25f);
                if (i % 32 == 0) std::this_thread::yield();
            }
        });
        producer.join(); consumer.join();
    }
    std::cout << "All pipeline tests passed.\n";
    return 0;
}
