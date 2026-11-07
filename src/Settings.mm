#include "Settings.hpp"
#include <cstdio>
#include <cmath>
#include <algorithm>

namespace mono {
NSString *settingsPath() {
    const char *override = getenv("MONOMIC_SETTINGS_PATH");
    if (override && override[0] == '/') return [NSString stringWithUTF8String:override];
    NSString *directory = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[directory stringByAppendingPathComponent:@"MonoMic"] stringByAppendingPathComponent:@"settings.plist"];
}
bool validSettings(NSDictionary *s) {
    if (![s isKindOfClass:NSDictionary.class] || ![s[@"inputUID"] isKindOfClass:NSString.class] || ![s[@"inputUID"] length]) return false;
    if (![s[@"inputChannel"] isKindOfClass:NSNumber.class] || [s[@"inputChannel"] integerValue] < 0) return false;
    if (![s[@"channelLayout"] isKindOfClass:NSArray.class]) return false;
    for (id name in s[@"channelLayout"]) if (![name isKindOfClass:NSString.class]) return false;
    NSInteger channel = [s[@"inputChannel"] integerValue];
    if (channel >= static_cast<NSInteger>([s[@"channelLayout"] count])) return false;
    if (![s[@"bufferFrames"] isKindOfClass:NSNumber.class]) return false;
    NSInteger buffer = [s[@"bufferFrames"] integerValue];
    if (buffer != 32 && buffer != 64 && buffer != 128 && buffer != 256) return false;
    if (!s[@"gainDb"]) return true; // Existing configurations keep unity gain.
    if (![s[@"gainDb"] isKindOfClass:NSNumber.class]) return false;
    double gain = [s[@"gainDb"] doubleValue];
    return std::isfinite(gain) && gain >= -36 && gain <= 12;
}
NSDictionary *readSettings() {
    NSData *data = [NSData dataWithContentsOfFile:settingsPath()];
    if (!data) return nil;
    id settings = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    return validSettings(settings) ? settings : nil;
}
bool saveSettings(NSDictionary *s, NSError **error) {
    if (!validSettings(s)) {
        if (error) *error = [NSError errorWithDomain:@"MonoMic" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Choose a valid interface, input and buffer size."}];
        return false;
    }
    NSString *path = settingsPath();
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return false;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:s format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return false;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:kSettingsChanged object:nil userInfo:nil deliverImmediately:YES];
    return true;
}
double gainDb(NSDictionary *s) { return [s[@"gainDb"] doubleValue]; }
bool sameAudioRoute(NSDictionary *a, NSDictionary *b) {
    if (!a || !b) return false;
    for (NSString *key in @[@"inputUID", @"inputChannel", @"channelLayout", @"bufferFrames"])
        if (![a[key] isEqual:b[key]]) return false;
    return true;
}
NSDictionary *routeSettings(const Device &d, UInt32 channel, UInt32 buffer, double gain) {
    NSMutableArray *names = [NSMutableArray new];
    for (const auto &name : d.channelNames) [names addObject:[NSString stringWithUTF8String:name.c_str()]];
    return @{@"version": @1, @"inputUID": [NSString stringWithUTF8String:d.uid.c_str()],
        @"inputName": [NSString stringWithUTF8String:d.name.c_str()], @"inputChannel": @(channel),
        @"channelLayout": names, @"bufferFrames": @(buffer), @"gainDb": @(gain)};
}
bool channelMatches(NSDictionary *s, const Device &d) {
    if (!validSettings(s) || d.uid != [s[@"inputUID"] UTF8String]) return false;
    NSArray *names = s[@"channelLayout"];
    const UInt32 channel = [s[@"inputChannel"] unsignedIntValue];
    if (channel >= d.inputs || channel >= d.channelNames.size()) return false;
    bool identical = d.channelNames.size() == names.count;
    if (identical) for (size_t i = 0; i < d.channelNames.size(); ++i)
        if (d.channelNames[i] != [names[i] UTF8String]) { identical = false; break; }
    if (identical) return true;
    // Higher rates can remove ADAT channels. Keep the selected channel only
    // when its unique name is still at the same index; never guess a new route.
    NSString *name = names[channel];
    if (d.channelNames[channel] != name.UTF8String) return false;
    NSUInteger oldMatches = 0;
    for (NSString *other in names) if ([other isEqualToString:name]) ++oldMatches;
    return oldMatches == 1 && std::count(d.channelNames.begin(), d.channelNames.end(), std::string(name.UTF8String)) == 1;
}
NSDictionary *legacyRouteSettings(NSDictionary *legacy, const std::vector<Device> &available, UInt32 initialBuffer) {
    NSString *uid = legacy[@"inputUID"];
    if (![uid isKindOfClass:NSString.class] || !uid.length) return nil;
    if (![legacy[@"inputChannel"] isKindOfClass:NSNumber.class] || [legacy[@"inputChannel"] integerValue] < 0) return nil;
    for (const auto &device : available) {
        if (device.uid == uid.UTF8String) {
            UInt32 channel = [legacy[@"inputChannel"] unsignedIntValue];
            NSDictionary *s = routeSettings(device, channel, initialBuffer);
            if (legacy[@"channelLayout"] && ![legacy[@"channelLayout"] isEqual:s[@"channelLayout"]]) return nil;
            return validSettings(s) ? s : nil;
        }
    }
    return nil;
}
int migrateSettings(UInt32 initialBuffer) {
    if (readSettings()) { puts("Existing settings preserved."); return 0; }
    NSDictionary *legacy = [NSUserDefaults.standardUserDefaults persistentDomainForName:@"local.motu.monomic"];
    if (![legacy[@"inputUID"] isKindOfClass:NSString.class] || ![legacy[@"inputUID"] length]) {
        puts("First installation: choose an interface and input in Mono Mic settings."); return 0;
    }
    NSDictionary *settings = legacyRouteSettings(legacy, devices(), initialBuffer);
    if (!settings) {
        puts("Choose an interface and input in Mono Mic settings; the old selection was not changed."); return 0;
    }
    NSError *error = nil;
    if (saveSettings(settings, &error)) { puts("Imported the previous interface and input."); return 0; }
    fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
}
int printAgentStatus() {
    __block NSDictionary *response = nil;
    NSString *request = NSUUID.UUID.UUIDString;
    id observer = [NSDistributedNotificationCenter.defaultCenter addObserverForName:kStatusResponse object:nil
        queue:nil usingBlock:^(NSNotification *notification) {
            if ([notification.userInfo[@"request"] isEqual:request]) response = notification.userInfo;
        }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:kStatusRequest object:nil userInfo:@{@"request":request} deliverImmediately:YES];
    while (!response && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:observer];
    if (!response) { fputs("The background helper did not respond.\n", stderr); return 1; }
    NSData *json = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(json.bytes, 1, json.length, stdout); puts("");
    return 0;
}
}
