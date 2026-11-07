#pragma once
#include <CoreAudio/CoreAudio.h>
#include <optional>
#include <string>
#include <vector>

namespace mono {
inline constexpr const char *kDeviceUID = "MOTUMonoMic_UID";
struct Device {
    AudioDeviceID id = kAudioObjectUnknown;
    std::string uid, name;
    double rate = 0;
    UInt32 inputs = 0, outputs = 0, bufferFrames = 0;
    std::vector<std::string> channelNames;
};
std::vector<Device> devices();
Device deviceInfo(AudioDeviceID id);
std::optional<uint64_t> devicePathDelay(AudioDeviceID id, AudioObjectPropertyScope scope, UInt32 channel);
std::string channelDisplayName(const Device &device, UInt32 channel);
bool isAlive(AudioDeviceID id);
bool healthyFormat(AudioDeviceID id, UInt32 frames, double rate);
bool supportsSampleRate(AudioDeviceID id, double rate);
OSStatus requestSampleRate(AudioDeviceID id, double rate);
std::string statusText(OSStatus status);
}
