// GPL-3.0-or-later. A separately named, mono configuration of BlackHole.
#define kDriver_Name "MOTUMonoMic"
#define kHas_Driver_Name_Format false
#define kDevice_Name "Mono Mic"
#define kPlugIn_BundleID "local.motu.monomic.driver"
#define kPlugIn_Icon "MonoMic.icns"
#define kManufacturer_Name "Mono Mic (BlackHole based)"
#define kNumber_Of_Channels 1
#define kSampleRates 8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000
#define kLatency_Frame_Size 0
#define kCanBeDefaultSystemDevice false
#include "../vendor/BlackHole/BlackHole.c"
