#include "AudioDevices.hpp"
#include <Foundation/Foundation.h>
#include <cctype>
#include <cmath>
#include <cstring>
#include <sstream>

namespace mono {
template<class T> static T property(AudioObjectID id, AudioObjectPropertySelector selector,
                                    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    T value{};
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address{selector, scope, kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(id, &address, 0, nullptr, &size, &value);
    return value;
}
static std::string stringProperty(AudioObjectID id, AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
                                   AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) {
    CFStringRef value = nullptr;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address{selector, scope, element};
    if (AudioObjectGetPropertyData(id, &address, 0, nullptr, &size, &value) || !value) return {};
    char buffer[1024]{};
    CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8);
    CFRelease(value);
    return buffer;
}
static UInt32 channels(AudioDeviceID id, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address{kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &address, 0, nullptr, &size) || !size) return 0;
    std::vector<unsigned char> storage(size);
    if (AudioObjectGetPropertyData(id, &address, 0, nullptr, &size, storage.data())) return 0;
    const auto *list = reinterpret_cast<const AudioBufferList *>(storage.data());
    UInt32 total = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) total += list->mBuffers[i].mNumberChannels;
    return total;
}
template<class T> static std::optional<T> checkedProperty(AudioObjectID id,
    AudioObjectPropertySelector selector, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    T value{};
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address{selector, scope, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(id, &address, 0, nullptr, &size, &value) || size != sizeof(value))
        return std::nullopt;
    return value;
}
std::optional<uint64_t> devicePathDelay(AudioDeviceID id, AudioObjectPropertyScope scope, UInt32 channel) {
    const auto device = checkedProperty<UInt32>(id, kAudioDevicePropertyLatency, scope);
    const auto safety = checkedProperty<UInt32>(id, kAudioDevicePropertySafetyOffset, scope);
    if (!device || !safety) return std::nullopt;
    AudioObjectPropertyAddress address{kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &address, 0, nullptr, &size) || !size || size % sizeof(AudioStreamID))
        return std::nullopt;
    std::vector<AudioStreamID> streams(size / sizeof(AudioStreamID));
    if (AudioObjectGetPropertyData(id, &address, 0, nullptr, &size, streams.data())) return std::nullopt;
    for (size_t i = 0; i < size / sizeof(AudioStreamID); ++i) {
        const auto first = checkedProperty<UInt32>(streams[i], kAudioStreamPropertyStartingChannel);
        const auto format = checkedProperty<AudioStreamBasicDescription>(streams[i], kAudioStreamPropertyVirtualFormat);
        const uint64_t element = static_cast<uint64_t>(channel) + 1;
        if (!first || !format || element < *first || element >= static_cast<uint64_t>(*first) + format->mChannelsPerFrame)
            continue;
        const auto stream = checkedProperty<UInt32>(streams[i], kAudioStreamPropertyLatency);
        if (!stream) return std::nullopt;
        return static_cast<uint64_t>(*device) + *safety + *stream;
    }
    return std::nullopt;
}
Device deviceInfo(AudioDeviceID id) {
    Device d;
    d.id = id;
    d.name = stringProperty(id, kAudioObjectPropertyName);
    d.uid = stringProperty(id, kAudioDevicePropertyDeviceUID);
    d.rate = property<Float64>(id, kAudioDevicePropertyNominalSampleRate);
    d.inputs = channels(id, kAudioObjectPropertyScopeInput);
    d.outputs = channels(id, kAudioObjectPropertyScopeOutput);
    d.bufferFrames = property<UInt32>(id, kAudioDevicePropertyBufferFrameSize);
    for (UInt32 c = 1; c <= d.inputs; ++c) {
        auto name = stringProperty(id, kAudioObjectPropertyElementName, kAudioObjectPropertyScopeInput, c);
        if (name.empty()) name = "Input " + std::to_string(c);
        d.channelNames.push_back(name);
    }
    return d;
}
std::vector<Device> devices() {
    AudioObjectPropertyAddress address{kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size)) return {};
    std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, ids.data())) return {};
    std::vector<Device> result;
    for (auto id : ids) result.push_back(deviceInfo(id));
    return result;
}
std::string channelDisplayName(const Device &device, UInt32 channel) {
    if (channel >= device.channelNames.size()) return {};
    const auto &name = device.channelNames[channel];
    size_t matches = 0;
    for (const auto &other : device.channelNames) if (other == name) ++matches;
    return matches > 1 ? name + " (input " + std::to_string(channel + 1) + ")" : name;
}
bool isAlive(AudioDeviceID id) { return property<UInt32>(id, kAudioDevicePropertyDeviceIsAlive) != 0; }
bool healthyFormat(AudioDeviceID id, UInt32 frames, double rate) {
    const auto actual = property<Float64>(id, kAudioDevicePropertyNominalSampleRate);
    return isAlive(id) && std::isfinite(rate) && rate > 0 && std::abs(actual - rate) < 0.5 &&
        property<UInt32>(id, kAudioDevicePropertyBufferFrameSize) == frames;
}
bool supportsSampleRate(AudioDeviceID id, double rate) {
    if (!std::isfinite(rate) || rate <= 0) return false;
    AudioObjectPropertyAddress address{kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &address, 0, nullptr, &size) || !size || size % sizeof(AudioValueRange)) return false;
    std::vector<AudioValueRange> ranges(size / sizeof(AudioValueRange));
    if (AudioObjectGetPropertyData(id, &address, 0, nullptr, &size, ranges.data())) return false;
    for (size_t i = 0; i < size / sizeof(AudioValueRange); ++i)
        if (rate >= ranges[i].mMinimum && rate <= ranges[i].mMaximum) return true;
    return false;
}
OSStatus requestSampleRate(AudioDeviceID id, double rate) {
    if (!supportsSampleRate(id, rate)) return kAudioDeviceUnsupportedFormatError;
    AudioObjectPropertyAddress address{kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    Boolean settable = false;
    OSStatus result = AudioObjectIsPropertySettable(id, &address, &settable);
    if (result) return result;
    if (!settable) return kAudioHardwareIllegalOperationError;
    return AudioObjectSetPropertyData(id, &address, 0, nullptr, sizeof(rate), &rate);
}
std::string statusText(OSStatus status) {
    char s[5] = {char((status >> 24) & 255), char((status >> 16) & 255), char((status >> 8) & 255), char(status & 255), 0};
    bool printable = true;
    for (int i = 0; i < 4; ++i) printable &= std::isprint(static_cast<unsigned char>(s[i])) != 0;
    return std::to_string(status) + (printable ? std::string(" ('") + s + "')" : "");
}
}
