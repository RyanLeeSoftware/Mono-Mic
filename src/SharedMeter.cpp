#include "SharedMeter.hpp"
#include <fcntl.h>
#include <new>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace mono {
static const size_t pageSize = static_cast<size_t>(getpagesize());
static constexpr unsigned magic = 0x4d4d3031;
SharedMeter::SharedMeter(std::string name)
    : name_(name.empty() ? "/monomic-meter-" + std::to_string(getuid()) : std::move(name)) {}
SharedMeter::~SharedMeter() {
    if (data_) { if (writer_) setRunning(false); munmap(data_, pageSize); }
}
bool SharedMeter::openWriter() { return open(true); }
bool SharedMeter::openReader() { return open(false); }
bool SharedMeter::open(bool writer) {
    if (data_) return true;
    bool created = false;
    int fd = -1;
    if (writer) { fd = shm_open(name_.c_str(), O_RDWR | O_CREAT | O_EXCL, 0600); created = fd >= 0; }
    if (fd < 0) fd = shm_open(name_.c_str(), O_RDWR, 0600);
    if (fd < 0) return false;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct stat info{};
    if (fstat(fd, &info) || info.st_uid != getuid() ||
        (created ? ftruncate(fd, static_cast<off_t>(pageSize)) != 0 : info.st_size != static_cast<off_t>(pageSize))) { close(fd); return false; }
    void *memory = mmap(nullptr, pageSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (memory == MAP_FAILED) return false;
    auto *data = static_cast<Data *>(memory);
    if (created) new (data) Data;
    if (writer) {
        data->running.store(0); data->peak.store(0);
        data->magic.store(magic, std::memory_order_release);
    } else if (data->magic.load(std::memory_order_acquire) != magic) { munmap(data, pageSize); return false; }
    data_ = data; writer_ = writer;
    if (!writer) data_->peak.exchange(0);
    return true;
}
void SharedMeter::setRunning(bool value) {
    if (data_) { if (!value) data_->peak.store(0); data_->running.store(value, std::memory_order_release); }
}
bool SharedMeter::running() const { return data_ && data_->running.load(std::memory_order_acquire); }
std::atomic<float> *SharedMeter::peakSink() { return data_ ? &data_->peak : nullptr; }
float SharedMeter::consumePeak() { return running() ? data_->peak.exchange(0, std::memory_order_relaxed) : 0; }
}
