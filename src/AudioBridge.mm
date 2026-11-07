#include "AudioBridge.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <sstream>
#include <stdexcept>
#include <mach/mach_time.h>

namespace mono {
static void check(OSStatus status, const char *operation) {
    if (status) throw std::runtime_error(std::string(operation) + ": " + statusText(status));
}
static AudioUnit makeUnit() {
    AudioComponentDescription description{kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
                                           kAudioUnitManufacturer_Apple, 0, 0};
    auto component = AudioComponentFindNext(nullptr, &description);
    if (!component) throw std::runtime_error("The Apple HAL audio unit is unavailable.");
    AudioUnit unit = nullptr;
    check(AudioComponentInstanceNew(component, &unit), "Create HAL audio unit");
    return unit;
}
static AudioStreamBasicDescription monoFormat(double rate) {
    AudioStreamBasicDescription f{};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    f.mBytesPerPacket = f.mBytesPerFrame = sizeof(float);
    f.mFramesPerPacket = 1; f.mChannelsPerFrame = 1; f.mBitsPerChannel = 32;
    return f;
}
static UInt32 requestBuffer(AudioDeviceID id, UInt32 requested) {
    AudioObjectPropertyAddress address{kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
    Boolean settable = false;
    if (!AudioObjectIsPropertySettable(id, &address, &settable) && settable)
        AudioObjectSetPropertyData(id, &address, 0, nullptr, sizeof(requested), &requested);
    return deviceInfo(id).bufferFrames;
}
void AudioBridge::start(AudioDeviceID input, UInt32 channel, UInt32 requestedFrames) {
    stop();
    const auto source = deviceInfo(input);
    if (!source.inputs || channel >= source.inputs) throw std::runtime_error("Choose a valid input channel.");
    if (source.uid == kDeviceUID) throw std::runtime_error("The virtual microphone cannot be its own source.");
    if (!std::isfinite(source.rate) || source.rate <= 0)
        throw std::runtime_error("Waiting for the interface to report its sample rate.");
    Device destination;
    for (const auto &d : devices()) if (d.uid == kDeviceUID) destination = d;
    if (!destination.id) throw std::runtime_error("Install the Mono Mic driver, then refresh devices.");
    if (destination.inputs != 1 || destination.outputs != 1)
        throw std::runtime_error("Mono Mic must report one input and one output channel.");
    if (!supportsSampleRate(destination.id, source.rate))
        throw std::runtime_error("The Mono Mic driver does not support the interface's sample rate. Update the driver or select a supported rate on the interface.");
    sampleRate_ = source.rate;
    if (std::abs(destination.rate - sampleRate_) >= 0.5) {
        // HAL driver changes are asynchronous. Wait for its rate notification;
        // the agent's health timer retries if the host aborts the request.
        const auto now = std::chrono::steady_clock::now();
        if (pendingRate_ != sampleRate_ || now >= rateRetryAfter_) {
            check(requestSampleRate(destination.id, sampleRate_), "Follow interface sample rate");
            pendingRate_ = sampleRate_; rateRetryAfter_ = now + std::chrono::seconds(5);
        }
        std::ostringstream message;
        message << "Following interface: switching Mono Mic to " << sampleRate_ / 1000 << " kHz…";
        throw std::runtime_error(message.str());
    }
    pendingRate_ = 0;
    inputID_ = input; outputID_ = destination.id;
    inputName_ = source.name;
    channelName_ = channelDisplayName(source, channel);
    previousInputFrames_ = source.bufferFrames; previousOutputFrames_ = destination.bufferFrames;
    try {
        inputFrames_ = requestBuffer(inputID_, requestedFrames);
        changedInput_ = inputFrames_ != previousInputFrames_;
        outputFrames_ = requestBuffer(outputID_, requestedFrames);
        changedOutput_ = outputFrames_ != previousOutputFrames_;
        if (!inputFrames_ || !outputFrames_ || inputFrames_ > maxFrames || outputFrames_ > maxFrames)
            throw std::runtime_error("The audio device buffer size is unsupported.");
        bufferNote_.clear();
        if (inputFrames_ != requestedFrames || outputFrames_ != requestedFrames)
            bufferNote_ = "The device chose " + std::to_string(inputFrames_) + "/" + std::to_string(outputFrames_) + " samples instead of the requested size.";
        mach_timebase_info_data_t timebase{};
        check(mach_timebase_info(&timebase), "Read host clock scale");
        hostSecondsPerTick_ = static_cast<double>(timebase.numer) / timebase.denom * 1e-9;
        pipeline.reset(std::max(inputFrames_, outputFrames_), sampleRate_, true);
        callbackError.store(noErr);
        inputUnit_ = makeUnit();
        UInt32 on = 1, off = 0;
        check(AudioUnitSetProperty(inputUnit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof(on)), "Enable capture");
        check(AudioUnitSetProperty(inputUnit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sizeof(off)), "Disable capture playback");
        check(AudioUnitSetProperty(inputUnit_, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputID_, sizeof(inputID_)), "Select interface");
        auto format = monoFormat(sampleRate_);
        check(AudioUnitSetProperty(inputUnit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof(format)), "Set Float32 capture format");
        SInt32 channelMap = static_cast<SInt32>(channel);
        check(AudioUnitSetProperty(inputUnit_, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &channelMap, sizeof(channelMap)), "Select interface channel");
        UInt32 maximum = maxFrames;
        check(AudioUnitSetProperty(inputUnit_, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, sizeof(maximum)), "Set capture maximum");
        check(AudioUnitSetProperty(inputUnit_, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, &off, sizeof(off)), "Use preallocated capture buffer");
        AURenderCallbackStruct captureCallback{capture, this};
        check(AudioUnitSetProperty(inputUnit_, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &captureCallback, sizeof(captureCallback)), "Set capture callback");
        outputUnit_ = makeUnit();
        check(AudioUnitSetProperty(outputUnit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, sizeof(off)), "Disable virtual-device capture");
        check(AudioUnitSetProperty(outputUnit_, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outputID_, sizeof(outputID_)), "Select virtual microphone");
        check(AudioUnitSetProperty(outputUnit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)), "Set virtual microphone format");
        check(AudioUnitSetProperty(outputUnit_, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, sizeof(maximum)), "Set output maximum");
        AURenderCallbackStruct renderCallback{render, this};
        check(AudioUnitSetProperty(outputUnit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback, sizeof(renderCallback)), "Set output callback");
        check(AudioUnitInitialize(inputUnit_), "Initialize capture");
        check(AudioUnitInitialize(outputUnit_), "Initialize virtual microphone");
        if (!healthyFormat(inputID_, inputFrames_, sampleRate_) || !healthyFormat(outputID_, outputFrames_, sampleRate_))
            throw std::runtime_error("The sample rate changed during setup. Reconnecting…");
        check(AudioOutputUnitStart(inputUnit_), "Start capture");
        check(AudioOutputUnitStart(outputUnit_), "Start virtual microphone");
        latency_ = estimateLatency(inputFrames_, outputFrames_,
            devicePathDelay(inputID_, kAudioObjectPropertyScopeInput, channel),
            devicePathDelay(outputID_, kAudioObjectPropertyScopeOutput, 0), sampleRate_);
        running_ = true;
    } catch (...) { stop(); throw; }
}
void AudioBridge::restoreBuffers() {
    // Restore only if the device still uses our size; do not undo another app's change.
    if (changedInput_ && isAlive(inputID_) && deviceInfo(inputID_).bufferFrames == inputFrames_)
        requestBuffer(inputID_, previousInputFrames_);
    if (changedOutput_ && isAlive(outputID_) && deviceInfo(outputID_).bufferFrames == outputFrames_)
        requestBuffer(outputID_, previousOutputFrames_);
    changedInput_ = changedOutput_ = false;
}
void AudioBridge::stop() {
    running_ = false;
    latency_.reset();
    if (outputUnit_) { AudioOutputUnitStop(outputUnit_); AudioUnitUninitialize(outputUnit_); AudioComponentInstanceDispose(outputUnit_); outputUnit_ = nullptr; }
    if (inputUnit_) { AudioOutputUnitStop(inputUnit_); AudioUnitUninitialize(inputUnit_); AudioComponentInstanceDispose(inputUnit_); inputUnit_ = nullptr; }
    restoreBuffers();
}
bool AudioBridge::configurationValid() const {
    return running_ && healthyFormat(inputID_, inputFrames_, sampleRate_) && healthyFormat(outputID_, outputFrames_, sampleRate_);
}
std::string AudioBridge::summary() const {
    std::ostringstream s;
    s << inputName_ << " · " << channelName_ << "\n" << sampleRate_ / 1000 << " kHz · mono · ";
    if (inputFrames_ == outputFrames_) s << inputFrames_ << " samples";
    else s << inputFrames_ << "/" << outputFrames_ << " samples (input/output)";
    return s.str();
}
OSStatus AudioBridge::capture(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                              UInt32, UInt32 frames, AudioBufferList *) {
    auto &self = *static_cast<AudioBridge *>(context);
    if (frames > maxFrames) { self.callbackError.store(kAudioUnitErr_TooManyFramesToProcess); return kAudioUnitErr_TooManyFramesToProcess; }
    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0] = AudioBuffer{1, frames * UInt32(sizeof(float)), self.captureBuffer_.data()};
    OSStatus error = AudioUnitRender(self.inputUnit_, flags, time, 1, frames, &list);
    if (error) { self.callbackError.store(error); return error; }
    self.pipeline.push(self.captureBuffer_.data(), frames, mach_absolute_time() * self.hostSecondsPerTick_);
    return noErr;
}
OSStatus AudioBridge::render(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *,
                             UInt32, UInt32 frames, AudioBufferList *list) {
    auto &self = *static_cast<AudioBridge *>(context);
    if (!list) return kAudio_ParamError;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i)
        if (list->mBuffers[i].mData) std::memset(list->mBuffers[i].mData, 0, list->mBuffers[i].mDataByteSize);
    if (frames > maxFrames || list->mNumberBuffers != 1 || list->mBuffers[0].mNumberChannels != 1 ||
        list->mBuffers[0].mDataByteSize < frames * sizeof(float)) {
        self.callbackError.store(kAudioUnitErr_FormatNotSupported);
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    auto &buffer = list->mBuffers[0];
    if (!buffer.mData) buffer.mData = self.outputBuffer_.data();
    self.pipeline.pull(static_cast<float *>(buffer.mData), frames, mach_absolute_time() * self.hostSecondsPerTick_);
    buffer.mDataByteSize = frames * sizeof(float);
    return noErr;
}
}
