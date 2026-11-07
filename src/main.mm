#import <AppKit/AppKit.h>
#include "Settings.hpp"
#include "LoginService.hpp"
#include "SharedMeter.hpp"
#include "MeterEnvelope.hpp"
#include <cmath>
#include <memory>
#include <unistd.h>

static NSString *ns(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
static NSTextField *label(NSString *text, NSRect frame, CGFloat size = 13) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.frame = frame; field.font = [NSFont systemFontOfSize:size];
    field.maximumNumberOfLines = 0;
    return field;
}

@interface MonoMicSettingsDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate> {
    NSWindow *_window;
    NSPopUpButton *_devices, *_channels, *_buffers;
    NSTextField *_status, *_meterText;
    NSLevelIndicator *_meter;
    NSSlider *_gain;
    NSButton *_runAtStartup;
    NSTextField *_gainText;
    NSTimer *_meterTimer, *_gainSaveTimer;
    std::unique_ptr<mono::SharedMeter> _meterMemory;
    mono::MeterEnvelope _meterEnvelope;
    double _lastMeterTime, _fallbackPeak;
    unsigned _meterFrames;
    std::vector<mono::Device> _sources;
    NSDictionary *_settings;
    NSDate *_lastResponse;
    BOOL _loading;
    NSString *_requestID;
    BOOL _serviceStopped;
    BOOL _checkedDevelopmentCopy;
}
@end

@implementation MonoMicSettingsDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _settings = mono::readSettings();
    if (!_settings && mono::migrateSettings(128) == 0) _settings = mono::readSettings();
    _meterMemory = std::make_unique<mono::SharedMeter>();
    _meterMemory->openReader();
    _requestID = NSUUID.UUID.UUIDString;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSMenu *menu = [NSMenu new];
    NSMenuItem *applicationMenu = [NSMenuItem new]; [menu addItem:applicationMenu];
    NSMenu *items = [NSMenu new];
    NSMenuItem *close = [items addItemWithTitle:@"Close Settings" action:@selector(performClose:) keyEquivalent:@"w"];
    close.target = nil;
    [items addItem:NSMenuItem.separatorItem];
    [items addItemWithTitle:@"Quit Settings" action:@selector(terminate:) keyEquivalent:@"q"];
    applicationMenu.submenu = items; NSApp.mainMenu = menu;
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 550, 350)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"Mono Mic Settings"; _window.delegate = self; _window.releasedWhenClosed = NO;
    _window.contentMinSize = NSMakeSize(550, 350);
    _window.titleVisibility = NSWindowTitleVisible;
    _window.titlebarAppearsTransparent = NO;
    [self showWindowControls];
    [_window center];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 550, 350)];
    view.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    [_window.contentView addSubview:view];
    [view addSubview:label(@"Audio interface", NSMakeRect(24, 308, 110, 22))];
    _devices = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(145, 304, 321, 28) pullsDown:NO];
    _devices.target = self; _devices.action = @selector(deviceChanged:); [view addSubview:_devices];
    NSButton *refresh = [[NSButton alloc] initWithFrame:NSMakeRect(472, 304, 54, 28)];
    refresh.title = @"↻"; refresh.bezelStyle = NSBezelStyleRounded; refresh.toolTip = @"Refresh audio devices";
    refresh.target = self; refresh.action = @selector(refresh:); [view addSubview:refresh];
    [view addSubview:label(@"Input channel", NSMakeRect(24, 263, 110, 22))];
    _channels = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(145, 259, 381, 28) pullsDown:NO];
    _channels.target = self; _channels.action = @selector(optionsChanged:); [view addSubview:_channels];
    [view addSubview:label(@"Buffer", NSMakeRect(24, 218, 110, 22))];
    _buffers = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(145, 214, 381, 28) pullsDown:NO];
    for (NSNumber *size in @[@32, @64, @128, @256]) {
        [_buffers addItemWithTitle:[NSString stringWithFormat:@"%@ samples", size]];
        _buffers.lastItem.tag = size.integerValue;
    }
    NSInteger buffer = [_settings[@"bufferFrames"] integerValue];
    [_buffers selectItemWithTag:[_buffers.menu itemWithTag:buffer] ? buffer : 128];
    _buffers.target = self; _buffers.action = @selector(optionsChanged:); [view addSubview:_buffers];
    [view addSubview:label(@"Mic gain", NSMakeRect(24, 173, 110, 22))];
    _gain = [NSSlider sliderWithValue:mono::gainDb(_settings) minValue:-36 maxValue:12 target:self action:@selector(gainChanged:)];
    _gain.frame = NSMakeRect(145, 169, 285, 28); _gain.continuous = YES;
    _gain.accessibilityLabel = @"Mic gain";
    _gain.toolTip = @"0 dB keeps the original level. Negative values make your mic quieter.";
    [view addSubview:_gain];
    _gainText = label(@"", NSMakeRect(439, 170, 87, 22), 12);
    _gainText.alignment = NSTextAlignmentRight; [view addSubview:_gainText];
    [self updateGainLabel];
    _meter = [[NSLevelIndicator alloc] initWithFrame:NSMakeRect(24, 122, 405, 12)];
    _meter.levelIndicatorStyle = NSLevelIndicatorStyleContinuousCapacity;
    _meter.minValue = 0; _meter.maxValue = 60; _meter.warningValue = 54; _meter.criticalValue = 59; _meter.doubleValue = 0;
    [view addSubview:_meter];
    _meterText = label(@"−∞ dBFS", NSMakeRect(439, 116, 87, 22), 12);
    _meterText.alignment = NSTextAlignmentRight; [view addSubview:_meterText];
    _status = label(@"Connecting to the background helper…", NSMakeRect(24, 52, 502, 58)); [view addSubview:_status];
    _runAtStartup = [NSButton checkboxWithTitle:@"Run service at startup" target:self action:@selector(startupChanged:)];
    _runAtStartup.frame = NSMakeRect(24, 16, 502, 22);
    [view addSubview:_runAtStartup];
    [self updateStartupCheckbox];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(receivedStatus:)
        name:mono::kStatusResponse object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(openSettings:)
        name:mono::kOpenSettings object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(serviceStopped:)
        name:mono::kServiceStopped object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [self refresh:nil];
    [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [self updateMeterTimer];
    [self startServiceIfNeeded];
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(requestStatus:) userInfo:nil repeats:YES];
    timer.tolerance = 0.1;
    [self requestStatus:nil];
}
- (void)startServiceIfNeeded {
    _serviceStopped = NO;
    NSString *appPath = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    NSString *parent = appPath.stringByDeletingLastPathComponent;
    BOOL installed = [parent isEqualToString:@"/Applications"] ||
        [parent isEqualToString:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
    NSError *error = nil;
    BOOL reloaded = NO;
    NSString *job = [NSString stringWithFormat:@"gui/%u/local.motu.monomic.agent", getuid()];
    if (installed) {
        NSString *executable = [appPath stringByAppendingPathComponent:@"Contents/Library/LoginItems/Mono Mic Service.app/Contents/MacOS/MonoMicService"];
        NSString *logs = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/MonoMic"];
        bool changed = false;
        if (!mono::configureLoginService(mono::loginAgentPath(), executable, logs, &changed, &error)) {
            _status.stringValue = error.localizedDescription; return;
        }
        // A package installs system files; this process registers the service
        // for the actual user, never for the Installer's root account.
        if (changed) { [self launchctl:@[@"bootout", job] error:nil]; reloaded = YES; }
        if (![self launchctl:@[@"print", job] error:nil] &&
            ![self launchctl:@[@"bootstrap", [NSString stringWithFormat:@"gui/%u", getuid()], mono::loginAgentPath()] error:&error]) {
            _status.stringValue = error.localizedDescription; return;
        }
        [self updateStartupCheckbox];
    }
    if (!reloaded && [NSRunningApplication runningApplicationsWithBundleIdentifier:@"local.motu.monomic.service"].count) return;
    if (![self launchctl:@[@"kickstart", job] error:&error]) _status.stringValue = error.localizedDescription;
    else _status.stringValue = @"Starting the background service…";
    _lastResponse = NSDate.date;
}
- (BOOL)launchctl:(NSArray<NSString *> *)arguments error:(NSError **)error {
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = arguments; task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *errors = NSPipe.pipe; task.standardError = errors;
    if (![task launchAndReturnError:error]) return NO;
    NSData *data = [errors.fileHandleForReading readDataToEndOfFile]; [task waitUntilExit];
    if (!task.terminationStatus) return YES;
    if (error) {
        NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        *error = [NSError errorWithDomain:@"MonoMic" code:task.terminationStatus userInfo:@{
            NSLocalizedDescriptionKey:message.length ? message : @"Could not start Mono Mic Service. Reopen Mono Mic to retry."}];
    }
    return NO;
}
- (void)serviceStopped:(NSNotification *)notification {
    (void)notification; _serviceStopped = YES; _fallbackPeak = 0;
    _status.stringValue = @"Service stopped. Reopen Mono Mic to start it again.";
    _status.toolTip = nil;
}
- (void)showWindowControls {
    for (NSNumber *type in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
        NSButton *button = [_window standardWindowButton:static_cast<NSWindowButton>(type.unsignedIntegerValue)];
        button.hidden = NO; button.enabled = YES; button.alphaValue = 1;
    }
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification; [self showWindowControls]; [self updateStartupCheckbox];
}
- (void)updateStartupCheckbox {
    bool enabled = false; NSError *error = nil;
    _runAtStartup.enabled = mono::readStartupPreference(mono::loginAgentPath(), &enabled, &error);
    _runAtStartup.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    _runAtStartup.toolTip = error ? error.localizedDescription : @"Start the microphone service when you log in. Settings stay closed.";
}
- (void)startupChanged:(NSButton *)sender {
    NSError *error = nil;
    if (!mono::saveStartupPreference(mono::loginAgentPath(), sender.state == NSControlStateValueOn, &error)) {
        [self updateStartupCheckbox];
        NSAlert *alert = [NSAlert alertWithError:error];
        [alert beginSheetModalForWindow:_window completionHandler:nil];
    }
}
- (void)openSettings:(NSNotification *)notification {
    (void)notification;
    if (_window.miniaturized) [_window deminiaturize:nil];
    [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}
- (void)refresh:(id)sender {
    (void)sender; _loading = YES;
    _settings = mono::readSettings();
    _sources.clear(); [_devices removeAllItems];
    NSInteger chosen = -1;
    for (const auto &d : mono::devices()) {
        if (!d.inputs || d.uid == mono::kDeviceUID || d.uid == "MOTUMonoMic_2_UID") continue;
        if (_settings && d.uid == [_settings[@"inputUID"] UTF8String]) chosen = _sources.size();
        [_devices addItemWithTitle:ns(d.name)]; _sources.push_back(d);
    }
    if (chosen >= 0) [_devices selectItemAtIndex:chosen];
    else if (_settings) {
        [_devices addItemWithTitle:[NSString stringWithFormat:@"%@ (disconnected)", _settings[@"inputName"] ?: @"Saved interface"]];
        [_devices selectItemAtIndex:_devices.numberOfItems - 1];
    } else {
        [_devices addItemWithTitle:@"Choose an audio interface…"];
        [_devices selectItemAtIndex:_devices.numberOfItems - 1];
    }
    [self deviceChanged:nil]; _loading = NO;
}
- (void)deviceChanged:(id)sender {
    [_channels removeAllItems];
    NSInteger selected = _devices.indexOfSelectedItem;
    if (selected < 0 || selected >= static_cast<NSInteger>(_sources.size())) {
        [_channels addItemWithTitle:_settings ? @"Saved input will resume when connected" : @"Choose an audio interface first"];
        _channels.enabled = NO; return;
    }
    _channels.enabled = YES;
    const auto &d = _sources[selected];
    for (size_t i = 0; i < d.channelNames.size(); ++i)
        [_channels addItemWithTitle:ns(mono::channelDisplayName(d, static_cast<UInt32>(i)))];
    NSInteger channel = 0;
    if (mono::channelMatches(_settings, d)) channel = [_settings[@"inputChannel"] integerValue];
    [_channels selectItemAtIndex:channel];
    if (sender && !_loading) [self optionsChanged:sender];
}
- (void)optionsChanged:(id)sender {
    (void)sender; if (_loading) return;
    NSInteger selected = _devices.indexOfSelectedItem;
    UInt32 buffer = static_cast<UInt32>(_buffers.selectedItem.tag);
    NSDictionary *updated = nil;
    if (selected >= 0 && selected < static_cast<NSInteger>(_sources.size()) && _channels.indexOfSelectedItem >= 0)
        updated = mono::routeSettings(_sources[selected], static_cast<UInt32>(_channels.indexOfSelectedItem), buffer, _gain.doubleValue);
    else if (_settings) {
        NSMutableDictionary *copy = [_settings mutableCopy]; copy[@"bufferFrames"] = @(buffer); updated = copy;
    }
    NSError *error = nil;
    if (mono::saveSettings(updated, &error)) { _settings = updated; _status.stringValue = @"Saved. Applying your settings…"; }
    else _status.stringValue = error.localizedDescription ?: @"Choose an interface and input.";
    [self requestStatus:nil];
}
- (void)updateGainLabel {
    _gainText.stringValue = _gain.doubleValue == 0 ? @"0.0 dB" : [NSString stringWithFormat:@"%+.1f dB", _gain.doubleValue];
}
- (void)gainChanged:(id)sender {
    (void)sender;
    _gain.doubleValue = std::round(_gain.doubleValue * 2) / 2;
    [self updateGainLabel];
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:mono::kGainChanged object:nil
        userInfo:@{@"gainDb": @(_gain.doubleValue)} deliverImmediately:YES];
    [_gainSaveTimer invalidate];
    _gainSaveTimer = [NSTimer timerWithTimeInterval:0.15 target:self selector:@selector(saveGain:) userInfo:nil repeats:NO];
    [NSRunLoop.mainRunLoop addTimer:_gainSaveTimer forMode:NSRunLoopCommonModes];
}
- (void)saveGain:(NSTimer *)timer {
    (void)timer; [_gainSaveTimer invalidate]; _gainSaveTimer = nil;
    if (!_settings) { [self optionsChanged:nil]; return; }
    NSMutableDictionary *updated = [_settings mutableCopy]; updated[@"gainDb"] = @(_gain.doubleValue);
    NSError *error = nil;
    if (mono::saveSettings(updated, &error)) _settings = updated;
    else _status.stringValue = error.localizedDescription;
}
- (void)updateMeterTimer {
    BOOL visible = _window.visible && !_window.miniaturized && (_window.occlusionState & NSWindowOcclusionStateVisible);
    if (!visible) { [_meterTimer invalidate]; _meterTimer = nil; return; }
    if (_meterTimer) return;
    _meterMemory->consumePeak();
    _lastMeterTime = NSProcessInfo.processInfo.systemUptime;
    _meterTimer = [NSTimer timerWithTimeInterval:1.0/30.0 target:self selector:@selector(updateMeter:) userInfo:nil repeats:YES];
    _meterTimer.tolerance = 0.003;
    [NSRunLoop.mainRunLoop addTimer:_meterTimer forMode:NSRunLoopCommonModes];
}
- (void)windowDidChangeOcclusionState:(NSNotification *)notification { (void)notification; [self updateMeterTimer]; }
- (void)updateMeter:(NSTimer *)timer {
    (void)timer;
    double now = NSProcessInfo.processInfo.systemUptime;
    double peak = _meterMemory->connected() ? _meterMemory->consumePeak() : _fallbackPeak;
    _fallbackPeak = 0;
    double db = _meterEnvelope.update(peak, now - _lastMeterTime); _lastMeterTime = now;
    _meter.doubleValue = std::clamp(60.0 + db, 0.0, 60.0);
    if (++_meterFrames % 6 == 0)
        _meterText.stringValue = db > -100 ? [NSString stringWithFormat:@"%.1f dBFS", db] : @"−∞ dBFS";
}
- (void)requestStatus:(NSTimer *)timer {
    (void)timer;
    if (_serviceStopped || !_window.visible || _window.miniaturized) return;
    if (!_meterMemory->connected()) _meterMemory->openReader();
    if (_lastResponse && -_lastResponse.timeIntervalSinceNow > 5) _status.stringValue = @"The background helper is not responding.";
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:mono::kStatusRequest object:nil userInfo:@{@"request":_requestID} deliverImmediately:YES];
}
- (void)retireDevelopmentCopyForService:(pid_t)pid {
    if (_checkedDevelopmentCopy) return;
    NSString *appPath = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    if (![appPath isEqualToString:@"/Applications/Mono Mic.app"]) {
        _checkedDevelopmentCopy = YES;
        return;
    }
    NSString *servicePath = [appPath stringByAppendingPathComponent:
        @"Contents/Library/LoginItems/Mono Mic Service.app/Contents/MacOS/MonoMicService"];
    NSRunningApplication *service = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (![service.executableURL.path.stringByStandardizingPath isEqualToString:servicePath]) return;

    _checkedDevelopmentCopy = YES;
    NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    NSURL *userApplications = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"] isDirectory:YES];
    NSURL *olderApp = mono::olderDevelopmentApp(userApplications, build);
    if (olderApp) {
        NSError *error = nil;
        if (![NSFileManager.defaultManager trashItemAtURL:olderApp resultingItemURL:nil error:&error])
            NSLog(@"Could not move the older Mono Mic app to Trash. %@", error.localizedDescription);
    }
}
- (void)receivedStatus:(NSNotification *)notification {
    NSDictionary *state = notification.userInfo;
    if (![state[@"request"] isEqual:_requestID]) return;
    if (_serviceStopped) return;
    _lastResponse = NSDate.date;
    if ([state[@"running"] boolValue]) {
        [self retireDevelopmentCopyForService:[state[@"pid"] intValue]];
        id value = state[@"latencyMs"];
        NSString *latency = [value isKindOfClass:NSNumber.class] && std::isfinite([value doubleValue]) ?
            [NSString stringWithFormat:@"Resulting Latency: ~%.1f ms (Input → Mono Mic)", [value doubleValue]] : @"Resulting Latency: Unavailable";
        _status.stringValue = [NSString stringWithFormat:@"%@\n%@", state[@"summary"], latency];
        _status.toolTip = @"Estimated delay from your audio interface to Mono Mic. Voice apps and the network add further delay.";
    } else {
        _status.stringValue = state[@"message"] ?: @"Waiting for the background helper.";
        _status.toolTip = nil;
    }
    if (!_meterMemory->connected()) _fallbackPeak = std::max(_fallbackPeak, [state[@"peak"] doubleValue]);
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; if (_gainSaveTimer) [self saveGain:nil]; }
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    (void)sender; [self startServiceIfNeeded]; if (!visible) [_window makeKeyAndOrderFront:nil]; return YES;
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        for (int i = 1; i < argc; ++i) {
            std::string arg = argv[i];
            if (arg == "--agent") return mono::runAgent();
            if (arg == "--status") return mono::printAgentStatus();
            if (arg == "--quit-service") return mono::quitRunningService();
            if (arg == "--migrate") return mono::migrateSettings(i + 1 < argc ? static_cast<UInt32>(atoi(argv[i + 1])) : 64);
        }
        [NSApplication sharedApplication];
        MonoMicSettingsDelegate *delegate = [MonoMicSettingsDelegate new];
        NSApp.delegate = delegate; [NSApp run];
    }
}
