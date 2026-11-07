#include "../src/SharedMeter.hpp"
#include "../src/MeterEnvelope.hpp"
#include "../src/MonoPipeline.hpp"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <limits>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

int main() {
    for (double rate : {8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000}) {
        mono::MonoPipeline pipeline;
        pipeline.reset(64, rate); pipeline.setGainDb(-6);
        float one = 1, last = 0;
        const int count = static_cast<int>(std::round(rate * 0.010));
        for (int i = 0; i < count; ++i) { pipeline.push(&one, 1); last = pipeline.peak.exchange(0); }
        const double target = std::pow(10.0, -6.0 / 20.0);
        const double expected = target + (1 - target) * std::exp(-count / (0.010 * rate));
        assert(std::abs(last - expected) < 0.0001); // Same 10 ms ramp at every rate.
    }
    {
        mono::MonoPipeline pipeline;
        std::atomic<float> meterPeak{0};
        pipeline.setPeakSink(&meterPeak);
        pipeline.setGainDb(-6); pipeline.reset(128);
        float input[512], output[128]; std::fill_n(input, 512, 1.0f);
        pipeline.push(input, 512); pipeline.pull(output, 128);
        const double minus6 = std::pow(10.0, -6.0 / 20.0);
        for (float sample : output) assert(std::abs(sample - minus6) < 0.000001);
        assert(std::abs(meterPeak.exchange(0) - minus6) < 0.000001);
        pipeline.setGainDb(-12);
        float previous = output[127];
        for (int block = 0; block < 100; ++block) {
            pipeline.push(input, 128); pipeline.pull(output, 128);
            for (float sample : output) {
                assert(std::abs(sample - previous) < 0.002); // Smooth live gain, no abrupt step.
                previous = sample;
            }
        }
        assert(std::abs(previous - std::pow(10.0, -12.0 / 20.0)) < 0.00002);
        assert(pipeline.underruns == 0 && pipeline.overruns == 0);
        assert(pipeline.rendered > 12000); // Gain changes did not reset the stream.
    }
    {
        mono::MeterEnvelope meter;
        for (int frame = 0; frame < 30; ++frame) meter.update(0.5, 1.0 / 30);
        assert(std::abs(meter.decibels() + 6.0205999) < 0.001);
        double previous = meter.decibels();
        for (int frame = 0; frame < 6; ++frame) {
            double next = meter.update(0, 1.0 / 30);
            assert(next < previous && next > previous - 2); previous = next;
        }
        assert(std::abs(meter.decibels() + 14.7064895) < 0.001);
        assert(std::isfinite(meter.update(std::numeric_limits<double>::quiet_NaN(), 1.0 / 30)));
    }
    {
        std::string name = "/monomic-test-" + std::to_string(getpid());
        shm_unlink(name.c_str());
        mono::SharedMeter writer(name);
        assert(writer.openWriter()); writer.setRunning(true);
        int ready[2], go[2]; assert(pipe(ready) == 0 && pipe(go) == 0);
        pid_t child = fork(); assert(child >= 0);
        if (child == 0) {
            close(ready[0]); close(go[1]);
            mono::SharedMeter reader(name);
            if (!reader.openReader()) _exit(2);
            char token = 1; write(ready[1], &token, 1); read(go[0], &token, 1);
            _exit(reader.running() && reader.consumePeak() == 0.75f ? 0 : 3);
        }
        close(ready[1]); close(go[0]);
        char token = 0; assert(read(ready[0], &token, 1) == 1);
        writer.peakSink()->store(0.75f); assert(write(go[1], &token, 1) == 1);
        int status = 0; assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        assert(writer.peakSink()->load() == 0);
        close(ready[0]); close(go[1]);
        writer.setRunning(false); shm_unlink(name.c_str());
    }
    puts("Audio control tests passed: exact attenuation, click-free live gain, smooth meter decay and cross-process meter transport.");
    return 0;
}
