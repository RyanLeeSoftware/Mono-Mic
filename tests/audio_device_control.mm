#include "../src/AudioDevices.hpp"
#import <Foundation/Foundation.h>
#include <cstdio>
#include <cstdlib>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2 && argc != 3) return 2;
        for (const auto &device : mono::devices()) {
            if (device.uid != argv[1]) continue;
            if (argc == 3) {
                const double rate = std::strtod(argv[2], nullptr);
                const OSStatus result = mono::requestSampleRate(device.id, rate);
                if (result) { fprintf(stderr, "%s\n", mono::statusText(result).c_str()); return 1; }
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
                while (deadline.timeIntervalSinceNow > 0 && std::abs(mono::deviceInfo(device.id).rate - rate) >= 0.5)
                    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                return std::abs(mono::deviceInfo(device.id).rate - rate) < 0.5 ? 0 : 1;
            }
            UInt32 running = 0, size = sizeof(running);
            AudioObjectPropertyAddress address{kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            if (AudioObjectGetPropertyData(device.id, &address, 0, nullptr, &size, &running)) return 1;
            NSMutableArray *names = [NSMutableArray new];
            for (const auto &name : device.channelNames) [names addObject:[NSString stringWithUTF8String:name.c_str()]];
            NSDictionary *result = @{@"rate": @(device.rate), @"running": @(running != 0),
                @"uid": [NSString stringWithUTF8String:device.uid.c_str()],
                @"name": [NSString stringWithUTF8String:device.name.c_str()], @"channels": names};
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout); puts(""); return 0;
        }
        return 1;
    }
}
