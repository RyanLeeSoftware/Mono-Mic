#pragma once
#import <Foundation/Foundation.h>

namespace mono {
inline NSString *const kLoginAgentLabel = @"local.motu.monomic.agent";
inline NSString *loginAgentPath() {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/local.motu.monomic.agent.plist"];
}
inline NSURL *olderDevelopmentApp(NSURL *userApplications, NSString *installedBuild) {
    if (!installedBuild.length) return nil;
    NSURL *app = [userApplications URLByAppendingPathComponent:@"Mono Mic.app" isDirectory:YES];
    NSArray<NSURLResourceKey> *keys = @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey];
    for (NSURL *directory in @[userApplications, app]) {
        NSDictionary<NSURLResourceKey, id> *values = [directory resourceValuesForKeys:keys error:nil];
        if (![values[NSURLIsDirectoryKey] boolValue] || [values[NSURLIsSymbolicLinkKey] boolValue]) return nil;
    }
    NSURL *infoURL = [app URLByAppendingPathComponent:@"Contents/Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:infoURL];
    NSString *build = info[@"CFBundleVersion"];
    if (![info[@"CFBundleIdentifier"] isEqual:@"local.motu.monomic"] ||
        ![info[@"CFBundlePackageType"] isEqual:@"APPL"] ||
        ![build isKindOfClass:NSString.class] || !build.length ||
        [build compare:installedBuild options:NSNumericSearch] != NSOrderedAscending) return nil;
    return app;
}
inline NSDictionary *loginAgentConfiguration(NSString *executable, NSString *logs, bool startup) {
    return @{@"Label": kLoginAgentLabel, @"ProgramArguments": @[executable, @"--agent"],
        @"RunAtLoad": @(startup), @"KeepAlive": @{@"AfterInitialDemand": @YES, @"SuccessfulExit": @NO},
        @"ThrottleInterval": @10, @"LimitLoadToSessionType": @"Aqua", @"ProcessType": @"Interactive",
        @"StandardOutPath": [logs stringByAppendingPathComponent:@"agent.log"],
        @"StandardErrorPath": [logs stringByAppendingPathComponent:@"agent-error.log"]};
}
inline NSDictionary *readLoginAgent(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;
    id job = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:error];
    if (!job) return nil;
    if (![job isKindOfClass:NSDictionary.class] || ![job[@"Label"] isEqual:kLoginAgentLabel] ||
        (job[@"RunAtLoad"] && ![job[@"RunAtLoad"] isKindOfClass:NSNumber.class])) {
        if (error) *error = [NSError errorWithDomain:@"MonoMic" code:2 userInfo:@{
            NSLocalizedDescriptionKey:@"Mono Mic’s background service configuration is invalid. Reinstall the background service."}];
        return nil;
    }
    return job;
}
inline bool readStartupPreference(NSString *path, bool *enabled, NSError **error) {
    NSDictionary *job = readLoginAgent(path, error);
    if (!job) return false;
    if (enabled) *enabled = [job[@"RunAtLoad"] boolValue];
    return true;
}
inline bool saveStartupPreference(NSString *path, bool enabled, NSError **error) {
    NSMutableDictionary *job = [readLoginAgent(path, error) mutableCopy];
    if (!job) return false;
    job[@"RunAtLoad"] = @(enabled);
    // Wait for login/manual demand before evaluating crash recovery. Without
    // this guard, SuccessfulExit=false can launch a disabled-at-login service.
    job[@"KeepAlive"] = @{@"AfterInitialDemand": @YES, @"SuccessfulExit": @NO};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:job
        format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    // Update the next-login definition without unloading the current service.
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}
inline bool configureLoginService(NSString *path, NSString *executable, NSString *logs, bool *changed, NSError **error) {
    NSDictionary *previous = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
        previous = readLoginAgent(path, error);
        if (!previous) return false;
    }
    const bool startup = previous ? [previous[@"RunAtLoad"] boolValue] : true;
    NSDictionary *job = loginAgentConfiguration(executable, logs, startup);
    *changed = ![job isEqual:previous];
    if (!*changed) return true;
    for (NSString *directory in @[path.stringByDeletingLastPathComponent, logs])
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0700} error:error]) return false;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:job format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}
}
