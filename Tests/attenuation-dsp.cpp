#include "../Sources/AttenuationDSP.h"
#include <cassert>
#include <iostream>
#include <limits>
#include <vector>

int main() {
    unsigned scenarios = 0;
    for (float initial : {0.f, .42f, 1.f}) {
        EZAttenuationDSP initialDSP(48000, initial);
        float input[2] = {1, -1}, output[2]{};
        const float *in[] = {input}; float *out[] = {output};
        initialDSP.process(in,out,1,2,false);
        assert(output[0]==initial && output[1]==-initial); ++scenarios;
    }
    for (double rate : {8000., 44100., 48000., 96000., 192000.}) {
        for (unsigned channels : {1U, 2U, 6U, 8U}) for (bool planar : {false, true}) {
            const unsigned frames = 1000, buffers = planar ? channels : 1;
            std::vector<std::vector<float>> in(buffers, std::vector<float>(frames * (planar ? 1 : channels)));
            auto out = in;
            const float *inputs[8]{}; float *outputs[8]{};
            for (unsigned b = 0; b < buffers; ++b) {
                for (size_t i = 0; i < in[b].size(); ++i) in[b][i] = float(int((i + b) % 47) - 23) / 8.f;
                inputs[b] = in[b].data(); outputs[b] = out[b].data();
            }
            EZAttenuationDSP dsp(rate);
            dsp.process(inputs, outputs, frames, channels, planar);
            for (auto &v : out) for (float x : v) assert(x == 0 && !std::signbit(x));
            assert(dsp.target(1)); dsp.process(inputs, outputs, frames, channels, planar);
            assert(dsp.current() == 1);
            dsp.process(inputs, outputs, frames, channels, planar);
            assert(in == out); // Including peaks greater than full scale: no hidden clipping.
            for (float gain : {.01f, .5f, .999f, 0.f, 1.f}) {
                assert(dsp.target(gain)); dsp.process(inputs, outputs, frames, channels, planar);
                for (unsigned b = 0; b < buffers; ++b) for (size_t i = 0; i < in[b].size(); ++i)
                    assert(std::abs(out[b][i]) <= std::abs(in[b][i]));
                dsp.process(inputs, outputs, frames, channels, planar);
                for (unsigned b = 0; b < buffers; ++b) for (size_t i = 0; i < in[b].size(); ++i)
                    assert(out[b][i] == (gain == 0 ? 0 : in[b][i] * gain));
            }
            for (float invalid : {-1.f, 1.0001f, std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity()}) {
                assert(!dsp.target(invalid)); dsp.process(inputs, outputs, frames, channels, planar);
                for (auto &v : out) for (float x : v) assert(x == 0);
            }
            ++scenarios;
        }
    }
    // Layout conversion must preserve channel order and never add to old output.
    for (unsigned channels : {1U, 2U, 6U, 8U}) for (bool inputPlanar : {false, true}) {
        constexpr unsigned frames = 480;
        const bool outputPlanar = !inputPlanar;
        std::vector<std::vector<float>> in(inputPlanar ? channels : 1,
            std::vector<float>(frames * (inputPlanar ? 1 : channels)));
        std::vector<std::vector<float>> out(outputPlanar ? channels : 1,
            std::vector<float>(frames * (outputPlanar ? 1 : channels), 123.f));
        const float *inputs[8]{}; float *outputs[8]{};
        for (unsigned b = 0; b < in.size(); ++b) inputs[b] = in[b].data();
        for (unsigned b = 0; b < out.size(); ++b) outputs[b] = out[b].data();
        for (unsigned f = 0; f < frames; ++f) for (unsigned c = 0; c < channels; ++c)
            in[inputPlanar ? c : 0][inputPlanar ? f : f * channels + c] = float(c + 1) * (f % 2 ? -.2f : .3f);
        EZAttenuationDSP dsp(48000); assert(dsp.target(1));
        dsp.process(inputs, outputs, frames, channels, inputPlanar, outputPlanar);
        dsp.process(inputs, outputs, frames, channels, inputPlanar, outputPlanar);
        for (unsigned f = 0; f < frames; ++f) for (unsigned c = 0; c < channels; ++c)
            assert(out[outputPlanar ? c : 0][outputPlanar ? f : f * channels + c] ==
                   in[inputPlanar ? c : 0][inputPlanar ? f : f * channels + c]);
        assert(dsp.target(0)); dsp.process(inputs, outputs, frames, channels, inputPlanar, outputPlanar);
        dsp.process(inputs, outputs, frames, channels, inputPlanar, outputPlanar);
        for (auto &v : out) for (float x : v) assert(x == 0);
        ++scenarios;
    }
    EZAttenuationDSP ramp(48000);
    float input[2] = {1, -1}, output[2]; const float *ip[] = {input}; float *op[] = {output};
    assert(ramp.target(1)); float previous = 0;
    for (unsigned f = 0; f < ramp.rampFrames(); ++f) {
        assert(ramp.target(1)); // Repeated UI updates cannot restart/starve the ramp.
        ramp.process(ip, op, 1, 2, false);
        assert(output[0] >= previous && output[0] - previous <= 1.f / 240 + 1e-6);
        assert(output[1] == -output[0]); previous = output[0];
    }
    assert(previous == 1); assert(ramp.target(0));
    for (unsigned f = 0; f < ramp.rampFrames(); ++f) {
        ramp.process(ip, op, 1, 2, false); assert(output[0] <= previous); previous = output[0];
    }
    assert(previous == 0); ++scenarios;
    assert(ramp.target(1));
    for (unsigned f = 0; f < 120; ++f) ramp.process(ip, op, 1, 2, false);
    previous = output[0]; assert(ramp.target(.1f)); ramp.process(ip, op, 1, 2, false);
    assert(std::abs(output[0] - previous) < .005); ++scenarios;
    for (unsigned f = 0; f < 300; ++f) ramp.process(ip, op, 1, 2, false);
    for (float x : {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
                    -std::numeric_limits<float>::infinity(), std::numeric_limits<float>::max()}) {
        input[0] = x; ramp.process(ip, op, 1, 2, false);
        assert(std::isfinite(output[0]));
        assert(std::isfinite(x) ? std::abs(output[0]) <= std::abs(x) : output[0] == 0);
    }
    std::cout << "PASS " << ++scenarios << " DSP scenarios; synthetic PCM only\n";
}
