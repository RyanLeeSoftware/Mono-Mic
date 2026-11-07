#include "Settings.hpp"
#include "AudioBridge.hpp"
#include "SharedMeter.hpp"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#include <csignal>
#include <fcntl.h>
#include <memory>
#include <sys/file.h>
#include <unistd.h>

@interface MonoMicAgent : NSObject <NSApplicationDelegate, NSMenuDelegate> {
    std::unique_ptr<mono::AudioBridge> _bridge;
    std::unique_ptr<mono::SharedMeter> _meter;
    NSDictionary *_settings;
    NSString *_message;
    dispatch_source_t _termination;
    uint64_t _lastCaptured;
    unsigned _stalledChecks;
    BOOL _active;
    double _gainDb;
    NSStatusItem *_statusItem;
    NSMenuItem *_menuStatus, *_menuRoute, *_menuFormat, *_menuPermission;
    BOOL _requestingPermission;
    AudioDeviceID _sourceRateDevice, _virtualRateDevice;
    AudioObjectPropertyListenerBlock _rateListener;
}
- (void)start;
- (void)shutdown;
- (BOOL)isActive;
@end

@implementation MonoMicAgent
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification; [self start]; [self requestMicrophonePermission:nil];
}
- (void)createMenuBarItem {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"MenuBarIcon" ofType:@"pdf"];
    NSImage *image = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
    if (!image) image = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:@"Mono Mic"];
    image.size = NSMakeSize(18, 18); [image setTemplate:YES];
    _statusItem.button.image = image;
    if (!image) _statusItem.button.title = @"Mic";
    _statusItem.button.accessibilityLabel = @"Mono Mic";
    _statusItem.button.toolTip = @"Mono Mic — microphone settings";
    NSMenu *menu = [NSMenu new]; menu.delegate = self; menu.autoenablesItems = NO;
    _menuStatus = [menu addItemWithTitle:@"Mono Mic" action:nil keyEquivalent:@""]; _menuStatus.enabled = NO;
    _menuRoute = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""]; _menuRoute.enabled = NO;
    _menuFormat = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""]; _menuFormat.enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings = [menu addItemWithTitle:@"Open Settings…" action:@selector(openSettings:) keyEquivalent:@","];
    settings.target = self;
    _menuPermission = [menu addItemWithTitle:@"Microphone Permissions…" action:@selector(requestMicrophonePermission:) keyEquivalent:@""];
    _menuPermission.target = self; _menuPermission.hidden = YES;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit" action:@selector(quitService:) keyEquivalent:@"q"];
    quit.target = self;
    _statusItem.menu = menu;
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    (void)menu;
    _menuStatus.title = _bridge->running() ? @"Mono Mic · Running" : @"Mono Mic · Waiting";
    _menuRoute.title = _bridge->running() ? [[NSString stringWithUTF8String:_bridge->summary().c_str()] componentsSeparatedByString:@"\n"].firstObject : (_message ?: @"Waiting for audio");
    _menuFormat.title = [NSString stringWithFormat:@"%@ samples · %.1f dB", _settings[@"bufferFrames"] ?: @0, _gainDb == 0 ? 0.0 : _gainDb];
    _menuPermission.hidden = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized;
}
- (void)openSettings:(id)sender {
    (void)sender;
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"local.motu.monomic"]) {
        if (app.processIdentifier == getpid()) continue;
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:mono::kOpenSettings object:nil userInfo:nil deliverImmediately:YES];
        [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        return;
    }
    NSURL *url = NSBundle.mainBundle.bundleURL;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"local.motu.monomic"]) {
        NSURL *parent = url.URLByDeletingLastPathComponent;
        if ([parent.lastPathComponent isEqualToString:@"LoginItems"])
            for (int i = 0; i < 4; ++i) url = url.URLByDeletingLastPathComponent;
        else
            // Xcode runs the service product beside the settings app.
            url = [parent URLByAppendingPathComponent:@"Mono Mic.app" isDirectory:YES];
    }
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.activates = YES;
    configuration.createsNewApplicationInstance = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"local.motu.monomic"];
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:configuration completionHandler:^(NSRunningApplication *app, NSError *error) {
        (void)app;
        if (error) fprintf(stderr, "Open settings: %s\n", error.localizedDescription.UTF8String);
    }];
}
- (void)requestMicrophonePermission:(id)sender {
    AVAuthorizationStatus permission = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (permission == AVAuthorizationStatusAuthorized) return;
    if (permission == AVAuthorizationStatusDenied || permission == AVAuthorizationStatusRestricted) {
        if (sender) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
        return;
    }
    if (_requestingPermission) return;
    _requestingPermission = YES;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_requestingPermission = NO;
            if (granted) [self maintain:nil];
        });
    }];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    (void)sender; (void)visible; [self openSettings:nil]; return NO;
}
- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; [self shutdown]; }
- (void)quitService:(id)sender {
    (void)sender;
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:mono::kServiceStopped object:nil userInfo:nil deliverImmediately:YES];
    [NSApp terminate:nil];
}
- (void)start {
    if (_active) return;
    _active = YES;
    __weak MonoMicAgent *weakSelf = self;
    _rateListener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        (void)count; (void)addresses;
        MonoMicAgent *agent = weakSelf;
        if (agent && agent->_active) [agent maintain:nil];
    };
    _bridge = std::make_unique<mono::AudioBridge>();
    _meter = std::make_unique<mono::SharedMeter>();
    if (_meter->openWriter()) _bridge->pipeline.setPeakSink(_meter->peakSink());
    _message = @"Waiting for the saved audio interface.";
    [self createMenuBarItem];
    NSDistributedNotificationCenter *center = NSDistributedNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(settingsChanged:) name:mono::kSettingsChanged object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [center addObserver:self selector:@selector(statusRequested:) name:mono::kStatusRequest object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [center addObserver:self selector:@selector(gainChanged:) name:mono::kGainChanged object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [center addObserver:self selector:@selector(permissionRequested:) name:mono::kRequestPermission object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [center addObserver:self selector:@selector(quitService:) name:mono::kQuitService object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    signal(SIGTERM, SIG_IGN);
    _termination = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_termination, ^{
        [NSApp terminate:nil];
    });
    dispatch_resume(_termination);
    NSTimer *timer = [NSTimer timerWithTimeInterval:2 target:self selector:@selector(maintain:) userInfo:nil repeats:YES];
    timer.tolerance = 0.25;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    [self maintain:nil];
}
- (void)permissionRequested:(NSNotification *)notification { [self requestMicrophonePermission:notification]; }
- (void)watchRate:(AudioDeviceID)device previous:(AudioDeviceID *)previous {
    if (*previous == device) return;
    AudioObjectPropertyAddress address{kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (*previous) AudioObjectRemovePropertyListenerBlock(*previous, &address, dispatch_get_main_queue(), _rateListener);
    *previous = 0;
    if (device && !AudioObjectAddPropertyListenerBlock(device, &address, dispatch_get_main_queue(), _rateListener))
        *previous = device;
}
- (void)settingsChanged:(NSNotification *)notification { (void)notification; [self maintain:nil]; }
- (void)gainChanged:(NSNotification *)notification {
    id value = notification.userInfo[@"gainDb"];
    if (![value isKindOfClass:NSNumber.class]) return;
    double gain = [value doubleValue];
    if (!std::isfinite(gain) || gain < -36 || gain > 12) return;
    _gainDb = gain; _bridge->pipeline.setGainDb(gain);
}
- (void)maintain:(NSTimer *)timer {
    (void)timer;
    if (!_active) return;
    NSDictionary *latest = mono::readSettings();
    if (![_settings isEqual:latest]) {
        if (!mono::sameAudioRoute(_settings, latest)) { _meter->setRunning(false); _bridge->stop(); }
        _settings = latest;
        _gainDb = mono::gainDb(latest); _bridge->pipeline.setGainDb(_gainDb);
    }
    if (_bridge->running()) {
        uint64_t captured = _bridge->pipeline.captured.load();
        _stalledChecks = captured == _lastCaptured ? _stalledChecks + 1 : 0;
        _lastCaptured = captured;
        if (_bridge->callbackError.load() || !_bridge->configurationValid() || _stalledChecks >= 2) {
            _meter->setRunning(false); _bridge->stop(); _message = @"Audio configuration changed. Reconnecting…";
        } else return;
    }
    if (!_settings) { _message = @"Open Mono Mic settings to choose an interface and input."; return; }
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
        _message = @"Allow microphone access for Mono Mic Service."; return;
    }
    const auto available = mono::devices();
    AudioDeviceID output = 0;
    for (const auto &device : available) if (device.uid == mono::kDeviceUID) output = device.id;
    [self watchRate:output previous:&_virtualRateDevice];
    for (const auto &source : available) {
        if (source.uid != [_settings[@"inputUID"] UTF8String]) continue;
        [self watchRate:source.id previous:&_sourceRateDevice];
        if (!mono::channelMatches(_settings, source)) {
            _message = @"The input layout changed. Open settings and confirm your input channel."; return;
        }
        try {
            _bridge->start(source.id, [_settings[@"inputChannel"] unsignedIntValue], [_settings[@"bufferFrames"] unsignedIntValue]);
            _lastCaptured = 0; _stalledChecks = 0;
            _meter->setRunning(true);
            _message = @"Microphone is running in the background.";
        } catch (const std::exception &e) { _message = [NSString stringWithUTF8String:e.what()]; }
        return;
    }
    _message = @"Waiting for the saved audio interface to reconnect.";
}
- (void)statusRequested:(NSNotification *)notification {
    NSString *request = notification.userInfo[@"request"];
    if (![request isKindOfClass:NSString.class] || request.length > 100) return;
    const float peak = _bridge->pipeline.peak.exchange(0);
    const auto latency = _bridge->latencyEstimate();
    NSMutableDictionary *status = [@{
        @"request": request, @"pid": @(getpid()), @"running": @(_bridge->running()),
        @"message": _message ?: @"", @"summary": [NSString stringWithUTF8String:_bridge->summary().c_str()],
        @"bufferFrames": _settings[@"bufferFrames"] ?: @0, @"inputChannel": _settings[@"inputChannel"] ?: @0,
        @"queueTargetFrames": @(_bridge->pipeline.queueTargetFrames()),
        @"queueLatencyFrames": @(_bridge->pipeline.queueLatencyFrames()),
        @"driftCorrectionPpm": @(_bridge->pipeline.ppm.load()),
        @"inputUID": _settings[@"inputUID"] ?: @"", @"queueFrames": @(_bridge->pipeline.buffered.load()),
        @"capturedFrames": @(_bridge->pipeline.captured.load()), @"renderedFrames": @(_bridge->pipeline.rendered.load()),
        @"underruns": @(_bridge->pipeline.underruns.load()), @"overruns": @(_bridge->pipeline.overruns.load()),
        @"resyncs": @(_bridge->pipeline.resyncs.load()), @"peak": @(peak), @"callbackError": @(_bridge->callbackError.load())
        , @"permissionRequired": @([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized),
        @"gainDb": @(_gainDb), @"sharedMeter": @(_meter->connected()), @"menuBarIcon": @(_statusItem != nil),
        @"sampleRate": @(_bridge->sampleRate()), @"rateMode": @"followInterface"
    } mutableCopy];
    // Distributed notification payloads must be property lists; NSNull would
    // discard the entire reply when audio/permission is unavailable.
    if (latency) {
        status[@"latencyMs"] = @(latency->totalMs());
        status[@"captureLatencyMs"] = @(latency->captureMs);
        status[@"bridgeLatencyMs"] = @(latency->queueMs);
        status[@"outputLatencyMs"] = @(latency->outputMs);
    }
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:mono::kStatusResponse object:nil userInfo:status deliverImmediately:YES];
}
- (BOOL)isActive { return _active; }
- (void)shutdown {
    _active = NO;
    [self watchRate:0 previous:&_sourceRateDevice];
    [self watchRate:0 previous:&_virtualRateDevice];
    if (_meter) _meter->setRunning(false);
    if (_bridge) _bridge->stop();
}
@end

namespace mono {
int quitRunningService() {
    if (![NSRunningApplication runningApplicationsWithBundleIdentifier:@"local.motu.monomic.service"].count) {
        puts("Service is already stopped."); return 0;
    }
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:kQuitService object:nil userInfo:nil deliverImmediately:YES];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while (deadline.timeIntervalSinceNow > 0) {
        if (![NSRunningApplication runningApplicationsWithBundleIdentifier:@"local.motu.monomic.service"].count) {
            puts("Service stopped."); return 0;
        }
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    fputs("Service did not stop within four seconds.\n", stderr); return 1;
}
int runAgent() {
    // Protect against two instances writing to the same virtual microphone.
    NSString *directory = settingsPath().stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"agent.lock"];
    int lock = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB)) { fputs("Another Mono Mic agent is running.\n", stderr); return 1; }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    MonoMicAgent *agent = [MonoMicAgent new]; NSApp.delegate = agent;
    [NSApp run];
    [agent shutdown];
    close(lock);
    return 0;
}
}
