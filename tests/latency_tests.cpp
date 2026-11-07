#include "../src/Latency.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>

int main() {
    // At 48 kHz, 1 ms reported input delay, a 66-sample capture queue,
    // and a 32-sample virtual output buffer yield 146 samples overall.
    auto small = mono::estimateLatency(32, 32, 48, 0);
    assert(small && std::abs(small->totalMs() - 146.0 / 48) < 1e-9);
    for (double rate : {8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000}) {
        auto estimate = mono::estimateLatency(32, 32, 48, 0, rate);
        assert(estimate && std::abs(estimate->totalMs() - 146000.0 / rate) < 1e-9);
    }
    auto large = mono::estimateLatency(64, 64, 48, 0);
    assert(large && std::abs(large->totalMs() - small->totalMs() - 96.0 / 48) < 1e-9);
    // Different actual I/O sizes use the larger block for the bridge queue.
    auto mixed = mono::estimateLatency(32, 64, 48, 24);
    assert(mixed && std::abs(mixed->totalMs() - 266.0 / 48) < 1e-9);
    // The current MOTU path reports 24 samples of input delay at 48 kHz.
    auto motu = mono::estimateLatency(32, 32, 24, 0);
    assert(motu && std::abs(motu->totalMs() - 122.0 / 48) < 1e-9);
    assert(!mono::estimateLatency(32, 32, std::nullopt, 0));
    assert(!mono::estimateLatency(32, 32, 0, std::nullopt));
    assert(!mono::estimateLatency(0, 32, 0, 0));
    assert(!mono::estimateLatency(32, 0, 0, 0));
    assert(!mono::estimateLatency(32, 32, 0, 0, 0));
    assert(!mono::estimateLatency(32, 32, 0, 0, std::numeric_limits<double>::quiet_NaN()));
    std::cout << "Latency tests passed: device delays, actual buffer sizes, and unavailable timing.\n";
    return 0;
}
