#include "AudioDevices.hpp"
#include <Foundation/Foundation.h>
#include <iostream>
int main() {
    @autoreleasepool {
        for (const auto &d : mono::devices()) {
            std::cout << d.id << " | " << d.name << " | " << d.uid << " | "
                      << d.inputs << " in / " << d.outputs << " out | " << d.rate
                      << " Hz | " << d.bufferFrames << " frames\n";
            for (size_t i = 0; i < d.channelNames.size(); ++i)
                std::cout << "  " << i + 1 << ": " << d.channelNames[i] << '\n';
        }
    }
}
