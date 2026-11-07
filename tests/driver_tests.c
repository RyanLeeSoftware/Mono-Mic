#include "../driver/MonoDriver.c"
#include <assert.h>
#include <stdio.h>

int main(void) {
    AudioObjectPropertyAddress address = {kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    OSStatus status = BlackHole_GetStreamPropertyData(gAudioServerPlugInDriverRef, kObjectID_Stream_Input, 0, &address, 0, NULL, size, &size, &format);
    assert(status == noErr && format.mChannelsPerFrame == 1 && format.mSampleRate == 48000);
    assert(format.mBytesPerFrame == 4 && format.mBitsPerChannel == 32);
    assert(format.mFormatFlags & kAudioFormatFlagIsFloat);
    UInt32 pair[2] = {0}; size = sizeof(pair);
    address.mSelector = kAudioDevicePropertyPreferredChannelsForStereo;
    address.mScope = kAudioObjectPropertyScopeInput;
    status = BlackHole_GetDevicePropertyData(gAudioServerPlugInDriverRef, kObjectID_Device, 0, &address, 0, NULL, size, &size, pair);
    assert(status == noErr && pair[0] == 1 && pair[1] == 1);
    unsigned char layoutStorage[sizeof(AudioChannelLayout)] = {0};
    AudioChannelLayout *layout = (AudioChannelLayout *)layoutStorage;
    size = sizeof(layoutStorage); address.mSelector = kAudioDevicePropertyPreferredChannelLayout;
    status = BlackHole_GetDevicePropertyData(gAudioServerPlugInDriverRef, kObjectID_Device, 0, &address, 0, NULL, size, &size, layout);
    assert(status == noErr && layout->mNumberChannelDescriptions == 1 && layout->mChannelDescriptions[0].mChannelLabel == kAudioChannelLabel_Mono);
    const Float64 expectedRates[] = {8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000};
    assert(kDevice_SampleRatesSize == sizeof(expectedRates) / sizeof(expectedRates[0]));
    AudioValueRange ranges[11]; size = sizeof(ranges);
    address.mSelector = kAudioDevicePropertyAvailableNominalSampleRates;
    address.mScope = kAudioObjectPropertyScopeGlobal;
    status = BlackHole_GetDevicePropertyData(gAudioServerPlugInDriverRef, kObjectID_Device, 0, &address, 0, NULL, size, &size, ranges);
    assert(status == noErr && size == sizeof(ranges));
    for (UInt32 i = 0; i < kDevice_SampleRatesSize; ++i) {
        assert(ranges[i].mMinimum == expectedRates[i] && ranges[i].mMaximum == expectedRates[i]);
        gDevice_RequestedSampleRate = expectedRates[i];
        assert(BlackHole_PerformDeviceConfigurationChange(gAudioServerPlugInDriverRef, kObjectID_Device, ChangeAction_SetSampleRate, NULL) == noErr);
        assert(gDevice_SampleRate == expectedRates[i] && gDevice_HostTicksPerFrame > 0);
        for (UInt32 stream = kObjectID_Stream_Input; stream <= kObjectID_Stream_Output; stream += kObjectID_Stream_Output - kObjectID_Stream_Input) {
            size = sizeof(format); address.mSelector = kAudioStreamPropertyVirtualFormat;
            status = BlackHole_GetStreamPropertyData(gAudioServerPlugInDriverRef, stream, 0, &address, 0, NULL, size, &size, &format);
            assert(status == noErr && format.mSampleRate == expectedRates[i] && format.mChannelsPerFrame == 1);
            assert(format.mBytesPerFrame == 4 && format.mBitsPerChannel == 32 && (format.mFormatFlags & kAudioFormatFlagIsFloat));
        }
    }
    assert(!is_valid_sample_rate(12345));
    gDevice_RequestedSampleRate = 48000;
    assert(BlackHole_PerformDeviceConfigurationChange(gAudioServerPlugInDriverRef, kObjectID_Device, ChangeAction_SetSampleRate, NULL) == noErr);
    gRingBuffer = calloc(kRing_Buffer_Frame_Size, sizeof(Float32));
    assert(gRingBuffer);
    Float32 output[128], input[128];
    for (int i = 0; i < 128; ++i) output[i] = (Float32)i / 256;
    AudioServerPlugInIOCycleInfo cycle = {0};
    // Cross the driver's circular-buffer boundary.
    cycle.mOutputTime.mSampleTime = kRing_Buffer_Frame_Size - 64;
    cycle.mInputTime.mSampleTime = cycle.mOutputTime.mSampleTime;
    status = BlackHole_DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device, kObjectID_Stream_Output, 0,
        kAudioServerPlugInIOOperationWriteMix, 128, &cycle, output, NULL);
    assert(status == noErr);
    status = BlackHole_DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device, kObjectID_Stream_Input, 0,
        kAudioServerPlugInIOOperationReadInput, 128, &cycle, input, NULL);
    assert(status == noErr);
    for (int i = 0; i < 128; ++i) assert(input[i] == output[i]);
    free(gRingBuffer);
    puts("Driver tests passed: 11 sample rates, mono Float32 formats after rate changes, valid mono layout, bit-exact ring wrap.");
    return 0;
}
