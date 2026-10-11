#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>

// Audio-thread owned. UI commands are transferred by the backend's atomic mailbox.
// The reference is the incoming PCM, not a hardware/UI volume percentage.
class EZAttenuationDSP {
    float current_ = 0, target_ = 0, step_ = 0;
    uint32_t remaining_ = 0, rampFrames_;
public:
    explicit EZAttenuationDSP(double sampleRate, float initialGain = 0)
        : current_(initialGain), target_(initialGain), rampFrames_(uint32_t(std::clamp(sampleRate * .005, 1., 960.))) {}
    bool target(float gain) {
        if (!std::isfinite(gain) || gain < 0 || gain > 1) { silence(); return false; }
        if (gain != target_) {
            target_ = gain; remaining_ = rampFrames_;
            step_ = (target_ - current_) / float(remaining_);
        }
        return true;
    }
    void silence() { current_ = target_ = step_ = 0; remaining_ = 0; }
    float current() const { return current_; }
    uint32_t rampFrames() const { return rampFrames_; }
    // All channels of a frame share the same envelope. No summing, clipping,
    // normalization, channel mixing, resampling, allocation or locks.
    void process(const float *const *input, float *const *output,
                 uint32_t frames, uint32_t channels, bool planar) {
        process(input, output, frames, channels, planar, planar);
    }
    void process(const float *const *input, float *const *output,
                 uint32_t frames, uint32_t channels, bool inputPlanar, bool outputPlanar) {
        for (uint32_t frame = 0; frame < frames; ++frame) {
            if (remaining_) {
                current_ = --remaining_ ? std::clamp(current_ + step_, 0.f, 1.f) : target_;
            }
            for (uint32_t channel = 0; channel < channels; ++channel) {
                const float x = input[inputPlanar ? channel : 0][inputPlanar ? frame : frame * channels + channel];
                output[outputPlanar ? channel : 0][outputPlanar ? frame : frame * channels + channel] =
                    current_ == 0 || !std::isfinite(x) ? 0.f : current_ == 1 ? x : x * current_;
            }
        }
    }
};
