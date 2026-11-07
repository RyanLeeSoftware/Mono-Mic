#pragma once
#include <algorithm>
#include <cmath>

namespace mono {
class MeterEnvelope {
public:
    double update(double peak, double elapsed) {
        if (!std::isfinite(peak) || peak < 0) peak = 0;
        elapsed = std::clamp(elapsed, 0.0, 0.25);
        const double timeConstant = peak > value_ ? 0.012 : 0.20;
        value_ += (peak - value_) * (1.0 - std::exp(-elapsed / timeConstant));
        return decibels();
    }
    double decibels() const { return value_ > 0.000001 ? 20 * std::log10(value_) : -120; }
private:
    double value_ = 0;
};
}
