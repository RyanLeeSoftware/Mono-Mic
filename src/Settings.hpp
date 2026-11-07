#pragma once
#import <Foundation/Foundation.h>
#include "AudioDevices.hpp"

namespace mono {
inline NSString *const kSettingsChanged = @"local.motu.monomic.settingsChanged";
inline NSString *const kStatusRequest = @"local.motu.monomic.statusRequest";
inline NSString *const kStatusResponse = @"local.motu.monomic.statusResponse";
inline NSString *const kGainChanged = @"local.motu.monomic.gainChanged";
inline NSString *const kOpenSettings = @"local.motu.monomic.openSettings";
inline NSString *const kRequestPermission = @"local.motu.monomic.requestPermission";
inline NSString *const kQuitService = @"local.motu.monomic.quitService";
inline NSString *const kServiceStopped = @"local.motu.monomic.serviceStopped";
NSString *settingsPath();
NSDictionary *readSettings();
bool validSettings(NSDictionary *settings);
bool saveSettings(NSDictionary *settings, NSError **error);
NSDictionary *routeSettings(const Device &device, UInt32 channel, UInt32 buffer, double gainDb = 0);
double gainDb(NSDictionary *settings);
bool sameAudioRoute(NSDictionary *a, NSDictionary *b);
bool channelMatches(NSDictionary *settings, const Device &device);
NSDictionary *legacyRouteSettings(NSDictionary *legacy, const std::vector<Device> &available, UInt32 initialBuffer);
int migrateSettings(UInt32 initialBuffer);
int printAgentStatus();
int runAgent();
int quitRunningService();
}
