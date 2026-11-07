#include "../src/Settings.hpp"
#include "../src/LoginService.hpp"
#include <cassert>
#include <cstdio>
#include <unistd.h>

int main() {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *path = [directory stringByAppendingPathComponent:@"settings.plist"];
        const char *previous = getenv("MONOMIC_SETTINGS_PATH");
        const bool hadOverride = previous != nullptr;
        const std::string previousPath = previous ?: "";
        setenv("MONOMIC_SETTINGS_PATH", path.fileSystemRepresentation, 1);
        mono::Device device;
        device.uid = "test-interface-A"; device.name = "Test interface"; device.inputs = 3;
        device.channelNames = {"Mic A", "Mic B", "Line C"};
        assert(mono::channelDisplayName(device, 2) == "Line C");
        auto duplicate = device; duplicate.channelNames[0] = "Line C";
        assert(mono::channelDisplayName(duplicate, 0) == "Line C (input 1)");
        assert(mono::channelDisplayName(duplicate, 2) == "Line C (input 3)");
        assert(!mono::readSettings());
        assert(!mono::legacyRouteSettings(nil, {device}, 128));
        assert(!mono::legacyRouteSettings(@{}, {device}, 128));
        NSDictionary *oldSelection = @{@"inputUID": @"test-interface-A", @"inputChannel": @2,
            @"channelLayout": @[@"Mic A", @"Mic B", @"Line C"]};
        assert(!mono::legacyRouteSettings(oldSelection, {}, 128));
        NSDictionary *imported = mono::legacyRouteSettings(oldSelection, {device}, 128);
        assert(mono::validSettings(imported) && [imported[@"inputChannel"] unsignedIntValue] == 2);
        auto changedLegacyDevice = device; changedLegacyDevice.channelNames[2] = "Different channel";
        assert(!mono::legacyRouteSettings(oldSelection, {changedLegacyDevice}, 128));
        auto fewerChannels = device; fewerChannels.inputs = 2; fewerChannels.channelNames.resize(2);
        NSDictionary *firstInput = mono::routeSettings(device, 0, 32);
        assert(mono::channelMatches(firstInput, fewerChannels));
        auto renamedInput = fewerChannels; renamedInput.channelNames[0] = "Different mic";
        assert(!mono::channelMatches(firstInput, renamedInput));
        auto ambiguous = fewerChannels; ambiguous.channelNames[1] = "Mic A";
        assert(!mono::channelMatches(firstInput, ambiguous));
        assert(!mono::channelMatches(mono::routeSettings(device, 2, 32), fewerChannels));
        for (UInt32 frames : {32, 64, 128, 256}) {
            NSDictionary *settings = mono::routeSettings(device, 2, frames, -9.5);
            NSError *error = nil;
            assert(mono::saveSettings(settings, &error));
            // Reload through the same persisted-file path used after an agent restart.
            NSDictionary *loaded = mono::readSettings();
            assert([loaded isEqual:settings]);
            assert([loaded[@"bufferFrames"] unsignedIntValue] == frames);
            assert([loaded[@"inputChannel"] unsignedIntValue] == 2);
            assert(mono::gainDb(loaded) == -9.5);
            assert(mono::channelMatches(loaded, device));
            auto different = device; different.uid = "other-interface";
            assert(!mono::channelMatches(loaded, different));
            auto reordered = device; std::swap(reordered.channelNames[0], reordered.channelNames[2]);
            assert(!mono::channelMatches(loaded, reordered));
        }
        NSMutableDictionary *bad = [mono::readSettings() mutableCopy];
        NSMutableDictionary *legacy = [bad mutableCopy]; [legacy removeObjectForKey:@"gainDb"];
        assert(mono::validSettings(legacy) && mono::gainDb(legacy) == 0);
        assert(mono::sameAudioRoute(legacy, bad));
        bad[@"gainDb"] = @(-37); assert(!mono::validSettings(bad));
        bad[@"gainDb"] = @13; assert(!mono::validSettings(bad));
        bad[@"gainDb"] = @(-6); assert(mono::validSettings(bad));
        bad[@"bufferFrames"] = @0; assert(!mono::validSettings(bad));
        bad[@"bufferFrames"] = @64; bad[@"inputChannel"] = @(-1); assert(!mono::validSettings(bad));
        bad[@"inputChannel"] = @3; assert(!mono::validSettings(bad));
        [@"invalid plist" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        assert(!mono::readSettings());
        NSString *jobPath = [directory stringByAppendingPathComponent:@"agent.plist"];
        NSDictionary *originalJob = @{@"Label": mono::kLoginAgentLabel, @"RunAtLoad": @YES,
            @"ProgramArguments": @[@"/Applications/Mono Mic.app/Contents/Library/LoginItems/Mono Mic Service.app/Contents/MacOS/MonoMicService", @"--agent"],
            @"KeepAlive": @{@"SuccessfulExit": @NO}, @"ThrottleInterval": @10,
            @"StandardErrorPath": @"/tmp/mono-mic-test-error.log"};
        assert([originalJob writeToFile:jobPath atomically:YES]);
        bool enabled = false; NSError *startupError = nil;
        assert(mono::readStartupPreference(jobPath, &enabled, &startupError) && enabled);
        for (bool wanted : {false, true, false}) {
            assert(mono::saveStartupPreference(jobPath, wanted, &startupError));
            assert(mono::readStartupPreference(jobPath, &enabled, &startupError) && enabled == wanted);
            NSDictionary *savedJob = [NSDictionary dictionaryWithContentsOfFile:jobPath];
            assert([savedJob[@"ProgramArguments"] isEqual:originalJob[@"ProgramArguments"]]);
            assert([savedJob[@"StandardErrorPath"] isEqual:originalJob[@"StandardErrorPath"]]);
            assert([savedJob[@"ThrottleInterval"] isEqual:originalJob[@"ThrottleInterval"]]);
            // Disabled-at-login jobs must wait for manual demand before crash recovery.
            assert([savedJob[@"KeepAlive"][@"AfterInitialDemand"] boolValue]);
            assert(![savedJob[@"KeepAlive"][@"SuccessfulExit"] boolValue]);
        }
        NSDictionary *unrelated = @{@"Label": @"another.app.agent", @"RunAtLoad": @YES};
        assert([unrelated writeToFile:jobPath atomically:YES]);
        NSData *unrelatedData = [NSData dataWithContentsOfFile:jobPath];
        assert(!mono::saveStartupPreference(jobPath, false, &startupError) && startupError);
        assert([[NSData dataWithContentsOfFile:jobPath] isEqual:unrelatedData]);
        assert(!mono::readStartupPreference([directory stringByAppendingPathComponent:@"missing.plist"], &enabled, &startupError));
        NSString *freshJob = [directory stringByAppendingPathComponent:@"fresh/agent.plist"];
        NSString *logs = [directory stringByAppendingPathComponent:@"fresh/logs"];
        NSString *service = @"/Applications/Mono Mic.app/Contents/Library/LoginItems/Mono Mic Service.app/Contents/MacOS/MonoMicService";
        bool changed = false;
        assert(mono::configureLoginService(freshJob, service, logs, &changed, &startupError) && changed);
        assert(mono::readStartupPreference(freshJob, &enabled, &startupError) && enabled);
        assert(mono::configureLoginService(freshJob, service, logs, &changed, &startupError) && !changed);
        assert(mono::saveStartupPreference(freshJob, false, &startupError));
        NSString *updatedService = @"/Users/test/Applications/Mono Mic.app/Contents/Library/LoginItems/Mono Mic Service.app/Contents/MacOS/MonoMicService";
        assert(mono::configureLoginService(freshJob, updatedService, logs, &changed, &startupError) && changed);
        assert(mono::readStartupPreference(freshJob, &enabled, &startupError) && !enabled);
        NSDictionary *updatedJob = [NSDictionary dictionaryWithContentsOfFile:freshJob];
        assert(([updatedJob[@"ProgramArguments"] isEqual:@[updatedService, @"--agent"]]));
        assert([NSFileManager.defaultManager fileExistsAtPath:logs]);

        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *userApplications = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"Applications"] isDirectory:YES];
        NSURL *legacyApp = [userApplications URLByAppendingPathComponent:@"Mono Mic.app" isDirectory:YES];
        NSURL *contents = [legacyApp URLByAppendingPathComponent:@"Contents" isDirectory:YES];
        NSURL *infoURL = [contents URLByAppendingPathComponent:@"Info.plist"];
        assert(!mono::olderDevelopmentApp(userApplications, @"21"));
        assert([files createDirectoryAtURL:contents withIntermediateDirectories:YES attributes:nil error:nil]);
        NSMutableDictionary *bundleInfo = [@{@"CFBundleIdentifier": @"local.motu.monomic",
            @"CFBundlePackageType": @"APPL", @"CFBundleVersion": @"19"} mutableCopy];
        assert([bundleInfo writeToURL:infoURL atomically:YES]);
        assert([mono::olderDevelopmentApp(userApplications, @"21") isEqual:legacyApp]);
        assert(!mono::olderDevelopmentApp(userApplications, @"19"));
        assert(!mono::olderDevelopmentApp(userApplications, @"18"));

        NSURL *linkedApplications = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"LinkedApps"] isDirectory:YES];
        assert([files createSymbolicLinkAtURL:linkedApplications withDestinationURL:userApplications error:nil]);
        assert(!mono::olderDevelopmentApp(linkedApplications, @"21"));
        NSURL *otherApp = [userApplications URLByAppendingPathComponent:@"Other.app" isDirectory:YES];
        assert([files moveItemAtURL:legacyApp toURL:otherApp error:nil]);
        assert([files createSymbolicLinkAtURL:legacyApp withDestinationURL:otherApp error:nil]);
        assert(!mono::olderDevelopmentApp(userApplications, @"21"));
        assert([files removeItemAtURL:legacyApp error:nil]);
        assert([files moveItemAtURL:otherApp toURL:legacyApp error:nil]);
        bundleInfo[@"CFBundleIdentifier"] = @"another.app";
        assert([bundleInfo writeToURL:infoURL atomically:YES]);
        assert(!mono::olderDevelopmentApp(userApplications, @"21"));

        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
        if (hadOverride) setenv("MONOMIC_SETTINGS_PATH", previousPath.c_str(), 1);
        else unsetenv("MONOMIC_SETTINGS_PATH");
        puts("Settings tests passed: audio settings persist; startup preference persists without changing the service command; invalid configurations are rejected.");
    }
    return 0;
}
