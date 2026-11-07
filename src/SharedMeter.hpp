#pragma once
#include <atomic>
#include <string>

namespace mono {
// One page of local shared memory: no audio samples, files, or meter IPC per frame.
class SharedMeter {
public:
    explicit SharedMeter(std::string name = {});
    ~SharedMeter();
    SharedMeter(const SharedMeter &) = delete;
    SharedMeter &operator=(const SharedMeter &) = delete;
    bool openWriter();
    bool openReader();
    bool connected() const { return data_ != nullptr; }
    void setRunning(bool running);
    bool running() const;
    std::atomic<float> *peakSink();
    float consumePeak();
private:
    struct alignas(64) Data {
        std::atomic<unsigned> magic{0};
        std::atomic<unsigned> running{0};
        std::atomic<float> peak{0};
    };
    static_assert(std::atomic<unsigned>::is_always_lock_free);
    static_assert(std::atomic<float>::is_always_lock_free);
    bool open(bool writer);
    std::string name_;
    Data *data_ = nullptr;
    bool writer_ = false;
};
}
