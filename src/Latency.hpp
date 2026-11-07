#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>

namespace mono {
// Measured immediately before a render callback consumes its block. The extra
// samples provide lookahead for interpolation between the independent clocks.
inline constexpr uint32_t bridgeQueueTarget(uint32_t blockFrames) {
    return 2 * blockFrames + 2;
}
inline constexpr uint32_t timedBridgeQueueTarget(uint32_t blockFrames) {
    return bridgeQueueTarget(blockFrames);
}
struct LatencyEstimate {
    double captureMs, queueMs, outputMs;
    double totalMs() const { return captureMs + queueMs + outputMs; }
};
inline std::optional<LatencyEstimate> estimateLatency(
    uint32_t inputFrames, uint32_t outputFrames,
    std::optional<uint64_t> captureDelay, std::optional<uint64_t> outputDelay,
    double sampleRate = 48000) {
    if (!inputFrames || !outputFrames || !captureDelay || !outputDelay ||
        !std::isfinite(sampleRate) || sampleRate <= 0) return std::nullopt;
    const double msPerFrame = 1000.0 / sampleRate;
    // The queue is measured before pulling a block. It already includes the
    // captured input block, so adding an input I/O buffer again would double-count it.
    const double queueFrames = bridgeQueueTarget(std::max(inputFrames, outputFrames));
    return LatencyEstimate{*captureDelay * msPerFrame, queueFrames * msPerFrame,
        (static_cast<double>(*outputDelay) + outputFrames) * msPerFrame};
}
}
