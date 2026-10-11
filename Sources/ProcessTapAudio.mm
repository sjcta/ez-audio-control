#include "ProcessTapAudio.h"
#include "AttenuationDSP.h"
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>
#include <unordered_set>

namespace {
constexpr uint32_t maxChannels = 8, maxFrames = 4096;
constexpr uint64_t leaseNS = 1500000000ULL, firstFramesNS = 5000000000ULL, idleGapNS = 2000000000ULL;
uint64_t monotonicNow() {
    static const auto scale = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
    return uint64_t((__uint128_t(mach_continuous_time()) * scale.numer) / scale.denom);
}

// The injectable API is used by offline tests. It intentionally has no hardware
// volume, default-device, format setter, microphone or permission-request API.
struct TapAPI {
    decltype(&AudioObjectHasProperty) has = AudioObjectHasProperty;
    decltype(&AudioObjectGetPropertyData) get = AudioObjectGetPropertyData;
    decltype(&AudioObjectGetPropertyDataSize) size = AudioObjectGetPropertyDataSize;
    decltype(&AudioObjectAddPropertyListenerBlock) add = AudioObjectAddPropertyListenerBlock;
    decltype(&AudioObjectRemovePropertyListenerBlock) remove = AudioObjectRemovePropertyListenerBlock;
    OSStatus (*createTap)(CATapDescription *, AudioObjectID *) = nullptr;
    OSStatus (*destroyTap)(AudioObjectID) = nullptr;
    decltype(&AudioHardwareCreateAggregateDevice) createAggregate = AudioHardwareCreateAggregateDevice;
    decltype(&AudioHardwareDestroyAggregateDevice) destroyAggregate = AudioHardwareDestroyAggregateDevice;
    decltype(&AudioDeviceCreateIOProcID) createIO = AudioDeviceCreateIOProcID;
    decltype(&AudioDeviceStart) start = AudioDeviceStart;
    decltype(&AudioDeviceStop) stop = AudioDeviceStop;
    decltype(&AudioDeviceDestroyIOProcID) destroyIO = AudioDeviceDestroyIOProcID;
    uint64_t (*now)() = monotonicNow;
    TapAPI() {
        if (@available(macOS 14.2, *)) {
            createTap = AudioHardwareCreateProcessTap; destroyTap = AudioHardwareDestroyProcessTap;
        }
    }
};
AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}
template<class T> bool read(const TapAPI &api, AudioObjectID id, AudioObjectPropertyAddress a, T &value) {
    UInt32 bytes = sizeof(value);
    return api.get(id, &a, 0, nullptr, &bytes, &value) == noErr && bytes == sizeof(value);
}
bool streams(const TapAPI &api, AudioObjectID device, AudioObjectPropertyScope scope,
             uint32_t expectedCount, AudioStreamID *stream = nullptr) {
    auto a = address(kAudioDevicePropertyStreams, scope); UInt32 bytes = 0;
    if (api.size(device, &a, 0, nullptr, &bytes) != noErr || bytes != expectedCount * sizeof(AudioStreamID)) return false;
    if (!bytes) return true;
    return stream && read(api, device, a, *stream) && *stream != kAudioObjectUnknown;
}
bool floatPCM(const AudioStreamBasicDescription &f) {
    const auto flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    const bool planar = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved;
    return std::isfinite(f.mSampleRate) && f.mSampleRate >= 8000 && f.mSampleRate <= 192000 &&
        f.mFormatID == kAudioFormatLinearPCM && (f.mFormatFlags & ~kAudioFormatFlagIsNonInterleaved) == flags &&
        f.mBitsPerChannel == 32 && f.mChannelsPerFrame >= 1 && f.mChannelsPerFrame <= maxChannels &&
        f.mFramesPerPacket == 1 && f.mBytesPerFrame == (planar ? 4 : 4 * f.mChannelsPerFrame) &&
        f.mBytesPerPacket == f.mBytesPerFrame;
}
bool sameFormat(const AudioStreamBasicDescription &a, const AudioStreamBasicDescription &b) {
    return floatPCM(a) && floatPCM(b) && a.mSampleRate == b.mSampleRate &&
        a.mFormatFlags == b.mFormatFlags && a.mChannelsPerFrame == b.mChannelsPerFrame;
}
bool samePCM(const AudioStreamBasicDescription &a, const AudioStreamBasicDescription &b) {
    return floatPCM(a) && floatPCM(b) && a.mSampleRate == b.mSampleRate && a.mChannelsPerFrame == b.mChannelsPerFrame;
}
AudioObjectID ownProcess(const TapAPI &api) {
    auto a = address(kAudioHardwarePropertyTranslatePIDToProcessObject);
    pid_t pid = getpid(); AudioObjectID own = 0; UInt32 bytes = sizeof(own);
    if (api.get(kAudioObjectSystemObject, &a, sizeof(pid), &pid, &bytes, &own) != noErr || bytes != sizeof(own)) return 0;
    pid_t returnedPID = 0;
    return own && read(api, own, address(kAudioProcessPropertyPID), returnedPID) && returnedPID == pid ? own : 0;
}

struct CleanupDiagnostics {
    std::mutex mutex;
    EZProcessTapCleanupFailure failure{};
};
CleanupDiagnostics &cleanupDiagnostics() { static auto *value = new CleanupDiagnostics; return *value; }
void cleanupFailure(int32_t operation, AudioObjectID id, AudioObjectPropertySelector selector, OSStatus status) {
    if (status == noErr) return;
    auto &d = cleanupDiagnostics(); std::lock_guard<std::mutex> lock(d.mutex);
    d.failure = {operation, id, selector, status};
}
enum class ObjectPresence { present, gone, unknown };

struct TapSession {
    TapAPI api;
    AudioObjectID target = 0, own = 0, tap = 0, aggregate = 0, outputStream = 0;
    AudioDeviceIOProcID proc = nullptr;
    bool started = false;
    bool retainContext = false;
    NSString *aggregateUID = nil;
    NSUUID *tapUUID = nil;
    AudioStreamID inputStreamID = 0, replayStreamID = 0;
    std::unordered_set<AudioObjectID> goneObjects;
    AudioStreamBasicDescription format{};
    std::unique_ptr<EZAttenuationDSP> dsp;
    // One atomic word prevents gain/mute races. Low bits are the float, bit32 is mute.
    std::atomic<uint64_t> command{uint64_t(1) << 32}, deadline{0};
    std::atomic_bool initializing{true};
    // One atomic publication pairs the first fault with its diagnostic detail.
    // Low 32 bits are the stage; high 32 bits are the timeout reason.
    std::atomic<uint64_t> faultWord{0};
    std::atomic<uint64_t> callbacks{0}, validFrames{0}, lastCallback{0};
    std::atomic<uint64_t> callbacksInFlight{0};
    uint64_t startedAt = 0;
    AudioStreamBasicDescription inputFormat{}, outputFormat{};
    dispatch_queue_t notifications = dispatch_queue_create("local.SimpleAudioControl.ProcessTap", DISPATCH_QUEUE_SERIAL);
    AudioObjectPropertyListenerBlock listener = nil;
    struct Watch { AudioObjectID id; AudioObjectPropertyAddress property; };
    std::vector<Watch> watches;
    explicit TapSession(TapAPI a) : api(a) {}
    int32_t currentTimeout() const {
        // Start may wait for the OS permission UI. The session is not published
        // and its command is still zero/muted, so no positive gain is possible.
        if (initializing.load(std::memory_order_acquire)) return EZTapTimeoutUnknown;
        const auto now = api.now();
        if (now >= deadline.load(std::memory_order_acquire)) return EZTapTimeoutOwnerLease;
        if (!validFrames.load(std::memory_order_acquire) && now - startedAt >= firstFramesNS) return EZTapTimeoutFirstPCM;
        // Once PCM has validated the session, no callback may simply mean all
        // sources are idle. The owner lease and topology/format latches remain
        // authoritative; missing frames cannot themselves produce replay.
        return EZTapTimeoutUnknown;
    }
    bool healthy() const {
        return !faultWord.load(std::memory_order_acquire) && currentTimeout() == EZTapTimeoutUnknown;
    }
    void fault(int32_t stage = EZTapTopology) {
        const uint32_t detail = stage == EZTapTimeout ? currentTimeout() : EZTapTimeoutUnknown;
        const uint64_t value = uint32_t(stage) | (uint64_t(detail) << 32);
        uint64_t empty = 0;
        faultWord.compare_exchange_strong(empty, value, std::memory_order_acq_rel);
    }
    static void silence(AudioBufferList *out) {
        if (out) for (UInt32 i = 0; i < out->mNumberBuffers; ++i)
            if (out->mBuffers[i].mData) memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
    }
    static bool layout(const AudioBufferList *list, const AudioStreamBasicDescription &f, UInt32 &frames) {
        const bool planar = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved;
        if (!list || list->mNumberBuffers != (planar ? f.mChannelsPerFrame : 1)) return false;
        const UInt32 stride = planar ? 4 : f.mChannelsPerFrame * 4;
        for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
            const auto &b = list->mBuffers[i];
            if (!b.mData || b.mNumberChannels != (planar ? 1 : f.mChannelsPerFrame) ||
                b.mDataByteSize % stride || !b.mDataByteSize || b.mDataByteSize / stride > maxFrames) return false;
            if (i == 0) frames = b.mDataByteSize / stride;
            else if (b.mDataByteSize / stride != frames) return false;
        }
        return true;
    }
    static bool empty(const AudioBufferList *list) {
        if (!list || !list->mNumberBuffers) return true;
        for (UInt32 i=0; i<list->mNumberBuffers; ++i)
            if (list->mBuffers[i].mData && list->mBuffers[i].mDataByteSize) return false;
        return true;
    }
    static OSStatus render(AudioDeviceID, const AudioTimeStamp *, const AudioBufferList *in,
                           const AudioTimeStamp *, AudioBufferList *out, const AudioTimeStamp *, void *context) {
        auto &s = *static_cast<TapSession *>(context);
        struct Flight {
            std::atomic<uint64_t> &count;
            explicit Flight(std::atomic<uint64_t> &value) : count(value) { count.fetch_add(1, std::memory_order_acq_rel); }
            ~Flight() { count.fetch_sub(1, std::memory_order_release); }
        } flight(s.callbacksInFlight);
        // HAL may supply no input while no tapped process is producing frames.
        // Keep output silent; do not advertise readiness without valid PCM frames.
        if (!s.healthy() || !s.dsp) { silence(out); s.fault(EZTapTimeout); return noErr; }
        const auto now = s.api.now();
        const auto previous = s.lastCallback.exchange(now, std::memory_order_acq_rel);
        // There was no block in which to advance the envelope during an idle
        // gap. Resume from silence before applying the newest gain/mute command,
        // so a 0%/mute change while idle cannot replay the old gain's tail.
        if (previous && now - previous >= idleGapNS) s.dsp->silence();
        s.callbacks.fetch_add(1, std::memory_order_relaxed);
        if (empty(in) || empty(out)) {
            // No frame exists to carry the old envelope through the silent gap.
            // Resume from zero, so selecting 0% while idle cannot replay a tail
            // of the previous gain when PCM returns.
            s.dsp->silence(); silence(out); return noErr;
        }
        UInt32 inputFrames = 0, outputFrames = 0;
        if (!layout(in, s.inputFormat, inputFrames) || !layout(out, s.outputFormat, outputFrames) || inputFrames != outputFrames) {
            silence(out); s.fault(EZTapCallbackFormat); return noErr;
        }
        const float *inputs[maxChannels]{}; float *outputs[maxChannels]{};
        for (UInt32 j=0; j<out->mNumberBuffers; ++j) outputs[j] = static_cast<float *>(out->mBuffers[j].mData);
        for (UInt32 i = 0; i < in->mNumberBuffers; ++i) {
            inputs[i] = static_cast<const float *>(in->mBuffers[i].mData);
            for (UInt32 j = 0; j < out->mNumberBuffers; ++j) {
                const auto begin = reinterpret_cast<uintptr_t>(inputs[i]);
                const auto end = begin + in->mBuffers[i].mDataByteSize;
                const auto other = reinterpret_cast<uintptr_t>(out->mBuffers[j].mData);
                if (begin < other + out->mBuffers[j].mDataByteSize && other < end) {
                    silence(out); s.fault(EZTapCallbackFormat); return noErr;
                }
            }
        }
        const uint64_t cmd = s.command.load(std::memory_order_acquire);
        const uint32_t bits = uint32_t(cmd); float gain; memcpy(&gain, &bits, sizeof(gain));
        if (!s.dsp->target(cmd >> 32 ? 0 : gain)) { silence(out); s.fault(); return noErr; }
        s.dsp->process(inputs, outputs, inputFrames, s.format.mChannelsPerFrame,
                       s.inputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved,
                       s.outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
        s.validFrames.fetch_add(inputFrames, std::memory_order_release);
        // A concurrent topology fault must not leave a newly rendered block audible.
        if (!s.healthy()) { silence(out); s.fault(s.currentTimeout() != EZTapTimeoutUnknown ? EZTapTimeout : EZTapTopology); }
        return noErr;
    }
    bool watch(AudioObjectID id, AudioObjectPropertyAddress a, bool required = true) {
        if (!api.has(id, &a)) return !required;
        if (api.add(id, &a, notifications, listener) != noErr) return false;
        watches.push_back({id, a}); return true;
    }
    ObjectPresence objectClass(AudioObjectID id, int32_t operation, AudioClassID &value) {
        auto a = address(kAudioObjectPropertyClass); UInt32 bytes = sizeof(value);
        OSStatus result = api.get(id, &a, 0, nullptr, &bytes, &value);
        if (result == kAudioHardwareBadObjectError) return ObjectPresence::gone;
        if (result == noErr && bytes == sizeof(value)) return ObjectPresence::present;
        cleanupFailure(operation, id, a.mSelector, result == noErr ? kAudioHardwareBadPropertySizeError : result);
        return ObjectPresence::unknown;
    }
    ObjectPresence aggregatePresence() {
        AudioClassID type = 0;
        const auto state = objectClass(aggregate, EZTapCleanupInspectAggregate, type);
        if (state != ObjectPresence::present) return state;
        if (type != kAudioAggregateDeviceClassID) return ObjectPresence::gone; // ID was reused.
        auto a = address(kAudioDevicePropertyDeviceUID); CFStringRef ref = nullptr; UInt32 bytes = sizeof(ref);
        OSStatus result = api.get(aggregate, &a, 0, nullptr, &bytes, &ref);
        if (result == kAudioHardwareBadObjectError) return ObjectPresence::gone;
        if (result != noErr || bytes != sizeof(ref) || !ref) {
            if (ref) CFRelease(ref);
            cleanupFailure(EZTapCleanupInspectAggregate, aggregate, a.mSelector, result == noErr ? kAudioHardwareBadPropertySizeError : result);
            return ObjectPresence::unknown;
        }
        NSString *uid = CFBridgingRelease(ref);
        if (![uid isKindOfClass:NSString.class] || !aggregateUID) {
            cleanupFailure(EZTapCleanupInspectAggregate, aggregate, a.mSelector, kAudioHardwareIllegalOperationError);
            return ObjectPresence::unknown;
        }
        return [uid isEqualToString:aggregateUID] ? ObjectPresence::present : ObjectPresence::gone;
    }
    ObjectPresence tapPresence() {
        AudioClassID type = 0;
        const auto state = objectClass(tap, EZTapCleanupInspectTap, type);
        if (state != ObjectPresence::present) return state;
        if (type != kAudioTapClassID) return ObjectPresence::gone;
        auto a = address(kAudioTapPropertyDescription); CFTypeRef ref = nullptr; UInt32 bytes = sizeof(ref);
        OSStatus result = api.get(tap, &a, 0, nullptr, &bytes, &ref);
        if (result == kAudioHardwareBadObjectError) return ObjectPresence::gone;
        if (result != noErr || bytes != sizeof(ref) || !ref) {
            if (ref) CFRelease(ref);
            cleanupFailure(EZTapCleanupInspectTap, tap, a.mSelector, result == noErr ? kAudioHardwareBadPropertySizeError : result);
            return ObjectPresence::unknown;
        }
        CATapDescription *description = CFBridgingRelease(ref);
        if (![description isKindOfClass:CATapDescription.class] || !description.UUID || !tapUUID) {
            cleanupFailure(EZTapCleanupInspectTap, tap, a.mSelector, kAudioHardwareIllegalOperationError);
            return ObjectPresence::unknown;
        }
        return [description.UUID isEqual:tapUUID] ? ObjectPresence::present : ObjectPresence::gone;
    }
    void aggregateGone() {
        retainContext = true;
        for (auto id : {aggregate, inputStreamID, replayStreamID}) if (id) goneObjects.insert(id);
        aggregate = 0; proc = nullptr; started = false;
    }
    void tapGone() { retainContext = true; goneObjects.insert(tap); tap = 0; }
    bool stop() API_AVAILABLE(macos(14.2)) {
        fault(); // Every late callback stays silent, including after logical retirement.
        if (aggregate) {
            const auto presence = aggregatePresence();
            if (presence == ObjectPresence::unknown) return false;
            if (presence == ObjectPresence::gone) aggregateGone();
        }
        if (started) {
            const auto result = api.stop(aggregate, proc);
            cleanupFailure(EZTapCleanupStopIO, aggregate, 0, result);
            if (result == noErr || result == kAudioHardwareNotRunningError) started = false;
            else retainContext = true;
        }
        if (proc) {
            const auto result = api.destroyIO(aggregate, proc);
            cleanupFailure(EZTapCleanupDestroyIO, aggregate, 0, result);
            if (result == noErr) { proc = nullptr; started = false; }
            else {
                const auto presence = aggregatePresence();
                if (presence == ObjectPresence::gone) aggregateGone();
                else return false; // Preserve the IOProc and original-stream mute for retry.
            }
        }
        if (tap) {
            const auto presence = tapPresence();
            if (presence == ObjectPresence::unknown) return false;
            if (presence == ObjectPresence::gone) tapGone();
        }
        std::vector<Watch> remaining;
        for (auto &w : watches) {
            if (goneObjects.count(w.id)) continue;
            const auto result = api.remove(w.id, &w.property, notifications, listener);
            if (result == noErr) continue;
            cleanupFailure(EZTapCleanupRemoveListener, w.id, w.property.mSelector, result);
            AudioClassID type = 0;
            if (w.id != kAudioObjectSystemObject && objectClass(w.id, EZTapCleanupInspectListener, type) == ObjectPresence::gone) {
                retainContext = true; goneObjects.insert(w.id);
            } else remaining.push_back(w);
        }
        watches = std::move(remaining);
        dispatch_sync(notifications, ^{});
        if (watches.empty()) listener = nil;
        if (!watches.empty()) return false;
        // A callback already inside render may still own an output block. Do
        // not release the original-stream mute until that invocation returns.
        if (callbacksInFlight.load(std::memory_order_acquire)) {
            cleanupFailure(EZTapCleanupWaitCallbacks, aggregate, 0, kAudioHardwareNotReadyError);
            return false;
        }
        if (aggregate) {
            // IO teardown and listener drainage may have taken time. Recheck
            // ownership immediately before each destructive object operation.
            const auto presence = aggregatePresence();
            if (presence == ObjectPresence::unknown) return false;
            if (presence == ObjectPresence::gone) aggregateGone();
            else {
                const auto result = api.destroyAggregate(aggregate);
                cleanupFailure(EZTapCleanupDestroyAggregate, aggregate, 0, result);
                if (result == noErr) aggregate = 0;
                else if (aggregatePresence() == ObjectPresence::gone) aggregateGone();
                else return false;
            }
        }
        if (tap) {
            const auto presence = tapPresence();
            if (presence == ObjectPresence::unknown) return false;
            if (presence == ObjectPresence::gone) tapGone();
            else {
                const auto result = api.destroyTap(tap);
                cleanupFailure(EZTapCleanupDestroyTap, tap, 0, result);
                if (result == noErr) tap = 0;
                else if (tapPresence() == ObjectPresence::gone) tapGone();
                else return false;
            }
        }
        return true;
    }
};
static_assert(std::atomic<uint64_t>::is_always_lock_free, "Audio callback mailbox must not lock");
static_assert(std::atomic<int32_t>::is_always_lock_free && std::atomic_bool::is_always_lock_free,
              "Audio callback fault state must not lock");
struct Quarantine {
    std::mutex mutex;
    std::vector<std::shared_ptr<TapSession>> sessions, retired;
};
Quarantine &quarantine() {
    // Intentionally process-lifetime: a failed Stop/DestroyIOProc may leave HAL
    // using the context even during C++ static destruction at normal App exit.
    // The OS reclaims it at process death; never free it while callbacks may run.
    static auto *storage = new Quarantine;
    return *storage;
}
std::mutex &cleanupMutex() { static auto *value = new std::mutex; return *value; }
void retainSession(std::vector<std::shared_ptr<TapSession>> &storage, const std::shared_ptr<TapSession> &session) {
    if (std::find(storage.begin(), storage.end(), session) == storage.end()) storage.push_back(session);
}
bool stopSafely(std::shared_ptr<TapSession> session) API_AVAILABLE(macos(14.2)) {
    std::lock_guard<std::mutex> serial(cleanupMutex());
    const bool released = session->stop();
    auto &q = quarantine(); std::lock_guard<std::mutex> lock(q.mutex);
    if (!released) retainSession(q.sessions, session);
    else {
        q.sessions.erase(std::remove(q.sessions.begin(), q.sessions.end(), session), q.sessions.end());
        if (session->retainContext) retainSession(q.retired, session);
    }
    return released;
}

bool inspectOutput(const TapAPI &api, AudioObjectID target, AudioObjectID &outputStream,
                   AudioStreamBasicDescription &format) {
    UInt32 alive = 0, transport = 0, bufferFrames = 0; pid_t hog = 0;
    AudioObjectID current = 0;
    if (!target || !read(api, kAudioObjectSystemObject, address(kAudioHardwarePropertyDefaultOutputDevice), current) || current != target ||
        !read(api, target, address(kAudioDevicePropertyDeviceIsAlive), alive) || alive != 1 ||
        !read(api, target, address(kAudioDevicePropertyTransportType), transport) ||
        transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate ||
        !read(api, target, address(kAudioDevicePropertyHogMode), hog) || hog != -1 ||
        !read(api, target, address(kAudioDevicePropertyBufferFrameSize), bufferFrames) || !bufferFrames || bufferFrames > maxFrames ||
        !streams(api, target, kAudioDevicePropertyScopeInput, 0) ||
        !streams(api, target, kAudioDevicePropertyScopeOutput, 1, &outputStream) ||
        !read(api, outputStream, address(kAudioStreamPropertyVirtualFormat), format) || !floatPCM(format)) return false;
    AudioStreamBasicDescription physical{};
    return read(api, outputStream, address(kAudioStreamPropertyPhysicalFormat), physical) &&
        physical.mFormatID == kAudioFormatLinearPCM && physical.mSampleRate == format.mSampleRate &&
        physical.mChannelsPerFrame == format.mChannelsPerFrame;
}
bool descriptionMatches(CATapDescription *d, AudioObjectID own, NSString *uid) {
    return d && d.UUID && d.processes.count == 1 && d.isPrivate && d.isExclusive && !d.isMixdown && d.muteBehavior == CATapMuted &&
        [d.processes containsObject:@(own)] && [d.deviceUID isEqualToString:uid] && d.stream && d.stream.integerValue == 0;
}

// Not exported: offline tests call this only with an entirely fake TapAPI.
std::shared_ptr<TapSession> createSession(TapAPI api, AudioObjectID target, OSStatus &error, int32_t *failureStage = nullptr, float initialGain = 0, int initialMuted = 1) API_AVAILABLE(macos(14.2)) {
    error = kAudioHardwareIllegalOperationError;
    auto stage = [&](int32_t value) { if (failureStage) *failureStage = value; };
    stage(EZTapCleanup);
    { auto &q = quarantine(); std::lock_guard<std::mutex> lock(q.mutex); if (!q.sessions.empty()) return {}; }
    if (!std::isfinite(initialGain) || initialGain < 0 || initialGain > 1 || (initialMuted != 0 && initialMuted != 1)) { error = kAudioHardwareIllegalOperationError; return {}; }
    auto s = std::make_shared<TapSession>(api); s->target = target;
    stage(EZTapInspectOutput);
    if (!inspectOutput(api, target, s->outputStream, s->format)) return {};
    stage(EZTapOwnProcess);
    if (!(s->own = ownProcess(api))) return {};
    CFStringRef uidRef = nullptr;
    if (!read(api, target, address(kAudioDevicePropertyDeviceUID), uidRef) || !uidRef) return {};
    NSString *uid = CFBridgingRelease(uidRef);
    // Device stream tap avoids stereo mixdown normalization/channel conversion.
    // Exclusion covers future processes targeting this stream without enumerating them.
    auto *description = [[CATapDescription alloc] initExcludingProcesses:@[@(s->own)] andDeviceUID:uid withStream:0];
    description.privateTap = YES; description.muteBehavior = CATapMuted;
    description.name = @"EzAc software attenuation";
    if (@available(macOS 26.0, *)) description.bundleIDs = @[@"local.SimpleAudioControl"];
    if (!descriptionMatches(description, s->own, uid)) return {};
    s->tapUUID = description.UUID;
    auto fail = [&] { if (error == noErr) error = kAudioHardwareIllegalOperationError; if (!stopSafely(s)) stage(EZTapCleanup); return std::shared_ptr<TapSession>{}; };
    stage(EZTapCreate);
    error = api.createTap(description, &s->tap); if (error != noErr || !s->tap) return fail();
    // Read back the actual mute/exclusion contract before any replay starts.
    stage(EZTapDescription);
    CFTypeRef actualRef = nullptr; AudioStreamBasicDescription tapped{};
    if (!read(api, s->tap, address(kAudioTapPropertyDescription), actualRef)) return fail();
    CATapDescription *actual = CFBridgingRelease(actualRef);
    if (![actual isKindOfClass:CATapDescription.class] || !descriptionMatches(actual, s->own, uid) ||
        ![actual.UUID isEqual:s->tapUUID] ||
        !read(api, s->tap, address(kAudioTapPropertyFormat), tapped) || !samePCM(s->format, tapped)) return fail();
    NSDictionary *composition = @{
        @kAudioAggregateDeviceNameKey: @"EzAc private attenuation",
        @kAudioAggregateDeviceUIDKey: [@"local.SimpleAudioControl.tap." stringByAppendingString:NSUUID.UUID.UUIDString],
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceIsStackedKey: @NO,
        @kAudioAggregateDeviceMainSubDeviceKey: uid,
        @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey: uid, @kAudioSubDeviceInputChannelsKey: @0,
            @kAudioSubDeviceOutputChannelsKey: @(s->format.mChannelsPerFrame)}],
        @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: actual.UUID.UUIDString, @kAudioSubTapDriftCompensationKey: @NO}],
        @kAudioAggregateDeviceTapAutoStartKey: @NO
    };
    s->aggregateUID = composition[@kAudioAggregateDeviceUIDKey];
    stage(EZTapAggregate);
    error = api.createAggregate((__bridge CFDictionaryRef)composition, &s->aggregate);
    if (error != noErr || !s->aggregate) return fail();
    stage(EZTapFormats);
    AudioStreamID inputStream = 0, replayStream = 0; AudioStreamBasicDescription input{}, output{}; UInt32 frames = 0;
    if (!streams(api, s->aggregate, kAudioDevicePropertyScopeInput, 1, &inputStream) ||
        !streams(api, s->aggregate, kAudioDevicePropertyScopeOutput, 1, &replayStream) ||
        !read(api, inputStream, address(kAudioStreamPropertyVirtualFormat), input) || !samePCM(tapped, input) ||
        !read(api, replayStream, address(kAudioStreamPropertyVirtualFormat), output) || !samePCM(tapped, output) ||
        !read(api, s->aggregate, address(kAudioDevicePropertyBufferFrameSize), frames) || !frames || frames > maxFrames) return fail();
    s->inputFormat = input; s->outputFormat = output;
    s->inputStreamID = inputStream; s->replayStreamID = replayStream;
    s->dsp = std::make_unique<EZAttenuationDSP>(tapped.mSampleRate, initialMuted ? 0 : initialGain);
    uint32_t initialBits; memcpy(&initialBits, &initialGain, sizeof(initialBits));
    s->command.store(uint64_t(initialBits) | (uint64_t(initialMuted) << 32));
    // All topology/format/default-route changes latch silence. New processes are
    // included by the tap itself; a process-list change only revalidates our exclusion.
    stage(EZTapListeners);
    s->listener = ^(UInt32 count, const AudioObjectPropertyAddress *properties) {
        for (UInt32 i = 0; i < count; ++i) {
            if (properties[i].mSelector == kAudioHardwarePropertyProcessObjectList) {
                if (ownProcess(s->api) != s->own) s->fault();
            } else if (properties[i].mSelector == kAudioHardwarePropertyDevices) {
                // Creating our own private aggregate also changes this list.
                // Only invalidate if the actual target or our aggregate disappeared.
                AudioObjectID stream = 0; AudioStreamBasicDescription f{}; UInt32 alive = 0;
                if (!inspectOutput(s->api, s->target, stream, f) || stream != s->outputStream ||
                    !sameFormat(f, s->format) || !read(s->api, s->aggregate, address(kAudioDevicePropertyDeviceIsAlive), alive) || alive != 1) s->fault();
            } else s->fault();
        }
    };
    for (auto selector : std::initializer_list<AudioObjectPropertySelector>{kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice,
                          kAudioHardwarePropertyDevices, kAudioHardwarePropertyProcessObjectList})
        if (!s->watch(kAudioObjectSystemObject, address(selector))) return fail();
    for (auto id : {target, s->aggregate}) {
        for (auto selector : std::initializer_list<AudioObjectPropertySelector>{kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate,
                              kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyHogMode})
            if (!s->watch(id, address(selector), selector != kAudioDevicePropertyHogMode)) return fail();
        for (auto scope : {kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput})
            for (auto selector : std::initializer_list<AudioObjectPropertySelector>{kAudioDevicePropertyStreams, kAudioDevicePropertyStreamConfiguration})
                if (!s->watch(id, address(selector, scope))) return fail();
    }
    for (auto id : {s->outputStream, inputStream, replayStream})
        for (auto selector : std::initializer_list<AudioObjectPropertySelector>{kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat})
            if (!s->watch(id, address(selector))) return fail();
    if (!s->watch(s->tap, address(kAudioTapPropertyDescription)) || !s->watch(s->tap, address(kAudioTapPropertyFormat))) return fail();
    // Close every read/register gap, including the aggregate/tap formats. A
    // property can change after its first read but before its listener is added.
    AudioObjectID finalStream = 0; AudioStreamBasicDescription finalFormat{};
    if (!inspectOutput(api, target, finalStream, finalFormat) || finalStream != s->outputStream ||
        !sameFormat(finalFormat, s->format) || ownProcess(api) != s->own || s->faultWord.load()) return fail();
    CFTypeRef finalDescriptionRef = nullptr;
    if (!read(api, s->tap, address(kAudioTapPropertyDescription), finalDescriptionRef)) return fail();
    CATapDescription *finalDescription = CFBridgingRelease(finalDescriptionRef);
    if (![finalDescription isKindOfClass:CATapDescription.class] || !descriptionMatches(finalDescription, s->own, uid) ||
        ![finalDescription.UUID isEqual:actual.UUID] ||
        !read(api, s->tap, address(kAudioTapPropertyFormat), finalFormat) || !sameFormat(finalFormat, tapped)) return fail();
    for (const auto &stream : {std::make_pair(inputStream, s->inputFormat), std::make_pair(replayStream, s->outputFormat)})
        if (!read(api, stream.first, address(kAudioStreamPropertyVirtualFormat), finalFormat) || !sameFormat(finalFormat, stream.second)) return fail();
    AudioStreamID finalInput = 0, finalOutput = 0; UInt32 alive = 0, finalFrames = 0;
    if (!streams(api, s->aggregate, kAudioDevicePropertyScopeInput, 1, &finalInput) || finalInput != inputStream ||
        !streams(api, s->aggregate, kAudioDevicePropertyScopeOutput, 1, &finalOutput) || finalOutput != replayStream ||
        !read(api, s->aggregate, address(kAudioDevicePropertyDeviceIsAlive), alive) || alive != 1 ||
        !read(api, s->aggregate, address(kAudioDevicePropertyBufferFrameSize), finalFrames) || !finalFrames || finalFrames > maxFrames || s->faultWord.load()) return fail();
    s->startedAt = api.now(); s->deadline.store(s->startedAt + leaseNS);
    stage(EZTapCreateIO);
    error = api.createIO(s->aggregate, TapSession::render, s.get(), &s->proc);
    if (error != noErr || !s->proc) return fail();
    stage(EZTapStartIO);
    s->started = true; // Also attempt to stop after a failed/uncertain start.
    error = api.start(s->aggregate, s->proc);
    s->startedAt = api.now(); s->deadline.store(s->startedAt + leaseNS);
    s->initializing.store(false, std::memory_order_release);
    if (error != noErr) return fail();
    if (!s->healthy()) {
        const auto failureStage = int32_t(uint32_t(s->faultWord.load(std::memory_order_acquire)));
        stage(failureStage ? failureStage : EZTapTimeout); return fail();
    }
    stage(EZTapNone);
    return s;
}
using TapHandle = std::shared_ptr<TapSession>;
} // namespace

extern "C" int EZProcessTapAvailable() {
    if (@available(macOS 14.2, *)) return 1;
    return 0;
}
extern "C" void *EZProcessTapCreate(uint32_t outputDevice, int consentConfirmed, float initialGain, int initialMuted, EZProcessTapFailure *error) {
    if (!error) return nullptr;
    *error = {EZTapConsent, kAudioHardwareIllegalOperationError};
    if (consentConfirmed != 1) return nullptr;
    if (@available(macOS 14.2, *)) {
        auto session = createSession(TapAPI{}, outputDevice, error->status, &error->stage, initialGain, initialMuted);
        return session ? new TapHandle(session) : nullptr;
    }
    error->stage = EZTapUnsupportedOS;
    return nullptr;
}
extern "C" int EZProcessTapReadProgress(void *handle, EZProcessTapProgress *progress) {
    if (!handle || !progress) return 0;
    auto &s = *static_cast<TapHandle *>(handle);
    if (!s->healthy()) s->fault(EZTapTimeout);
    const auto fault = s->faultWord.load(std::memory_order_acquire);
    *progress = {s->callbacks.load(), s->validFrames.load(), int(s->healthy() && s->validFrames.load() > 0),
                 int32_t(uint32_t(fault)), int32_t(uint32_t(fault >> 32))};
    return 1;
}
extern "C" int EZProcessTapSetGain(void *handle, float gain, int muted) {
    if (!handle) return 0;
    auto &s = *static_cast<TapHandle *>(handle);
    if (!s->healthy()) { s->fault(EZTapTimeout); return 0; }
    if (!std::isfinite(gain) || gain < 0 || gain > 1 || (muted != 0 && muted != 1)) { s->fault(); return 0; }
    uint32_t bits; memcpy(&bits, &gain, sizeof(bits));
    s->command.store(uint64_t(bits) | (uint64_t(muted) << 32), std::memory_order_release); return 1;
}
extern "C" int EZProcessTapSnapshot(void *handle, float *gain, int *muted) {
    if (!handle || !gain || !muted) return 0;
    auto &s = *static_cast<TapHandle *>(handle); if (!s->healthy()) return 0;
    auto cmd = s->command.load(std::memory_order_acquire); uint32_t bits = uint32_t(cmd);
    memcpy(gain, &bits, sizeof(bits)); *muted = int(cmd >> 32); return 1;
}
extern "C" int EZProcessTapHealthy(void *handle) { return handle && (*static_cast<TapHandle *>(handle))->healthy(); }
extern "C" void EZProcessTapHeartbeat(void *handle) {
    if (handle) { auto &s = *static_cast<TapHandle *>(handle); if (s->healthy()) s->deadline.store(s->api.now() + leaseNS); else s->fault(EZTapTimeout); }
}
extern "C" void EZProcessTapPause(void *handle) { if (handle) (*static_cast<TapHandle *>(handle))->fault(); }
extern "C" int EZProcessTapDestroy(void *handle) {
    if (!handle) return 1;
    if (@available(macOS 14.2, *)) {
        auto *p = static_cast<TapHandle *>(handle); bool result = stopSafely(*p); delete p; return result;
    }
    return 0;
}
extern "C" int EZProcessTapReadCleanupFailure(EZProcessTapCleanupFailure *failure) {
    if (!failure) return 0;
    auto &d = cleanupDiagnostics(); std::lock_guard<std::mutex> lock(d.mutex);
    *failure = d.failure;
    return failure->operation != EZTapCleanupNone;
}
extern "C" int EZProcessTapRetryCleanup(EZProcessTapCleanupFailure *failure) {
    if (failure) *failure = {};
    if (@available(macOS 14.2, *)) {
        std::lock_guard<std::mutex> serial(cleanupMutex());
        auto &q = quarantine(); std::vector<std::shared_ptr<TapSession>> pending;
        { std::lock_guard<std::mutex> lock(q.mutex); pending = q.sessions; }
        for (const auto &session : pending) {
            if (!session->stop()) continue;
            std::lock_guard<std::mutex> lock(q.mutex);
            q.sessions.erase(std::remove(q.sessions.begin(), q.sessions.end(), session), q.sessions.end());
            if (session->retainContext) retainSession(q.retired, session);
        }
        bool released;
        { std::lock_guard<std::mutex> lock(q.mutex); released = q.sessions.empty(); }
        if (!released && failure) EZProcessTapReadCleanupFailure(failure);
        return released;
    }
    return 1;
}
