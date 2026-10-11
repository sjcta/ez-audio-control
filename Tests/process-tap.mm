// Includes the implementation to exercise real callback/lifecycle code with an
// entirely fake CoreAudio table. Never creates a system tap, aggregate or IOProc.
#include "../Sources/ProcessTapAudio.mm"
#include <cassert>
#include <iostream>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <functional>

namespace {
struct Fake {
    static Fake *current;
    std::vector<std::string> events;
    std::vector<AudioObjectPropertyListenerBlock> listeners;
    CATapDescription *description = nil;
    AudioDeviceIOProc callback = nullptr; void *context = nullptr;
    uint64_t time = 100;
    uint64_t startDelay = 0;
    AudioObjectID own = 90, output = 10;
    unsigned reads = 0, defaultReads = 0, failAt = 0, operations = 0;
    bool inputDevice = false, mismatch = false, unmuted = false, hogged = false, routeRace = false;
    bool failStop = false, failDestroy = false, failRemove = false, aggregateAlive = true, planarInput = false;
    bool formatRace = false, failAggregateDestroy = false, failTapDestroy = false;
    OSStatus tapFailure = noErr, startFailure = noErr;
    NSString *aggregateUID = nil;
    std::unordered_set<AudioObjectID> missing;
    std::unordered_map<AudioObjectID, OSStatus> classErrors;
    AudioObjectID failedRemoveObject = 0;
    OSStatus stopStatus = noErr, destroyIOStatus = noErr, removeStatus = noErr;
    OSStatus destroyAggregateStatus = noErr, destroyTapStatus = noErr;
    bool aggregateReused = false, tapReused = false;
    bool aggregateGoneOnDestroyIO = false;
    bool aggregateReusedOnDestroyIO = false, tapReusedOnDestroyAggregate = false;
    std::function<void()> clockHook;
    AudioStreamBasicDescription format{48000, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0};
    Fake() { current = this; }
    bool operation(const char *label) {
        events.emplace_back(label); ++operations; return failAt && operations == failAt;
    }
    template<class T> static OSStatus give(UInt32 *size, void *data, T value) {
        if (*size != sizeof(T)) return kAudioHardwareBadPropertySizeError;
        memcpy(data, &value, sizeof(T)); return noErr;
    }
    static OSStatus get(AudioObjectID id, const AudioObjectPropertyAddress *a, UInt32 qualifierSize,
                        const void *qualifier, UInt32 *size, void *data) {
        auto &f = *current; ++f.reads;
        if (f.missing.count(id)) return kAudioHardwareBadObjectError;
        switch (a->mSelector) {
        case kAudioObjectPropertyClass:
            if (f.classErrors.count(id)) return f.classErrors[id];
            return give(size, data, AudioClassID(id == 50 ? kAudioAggregateDeviceClassID : id == 30 ? kAudioTapClassID : kAudioObjectClassID));
        case kAudioHardwarePropertyDefaultOutputDevice:
            ++f.defaultReads; return give(size, data, AudioObjectID(f.routeRace && f.defaultReads > 1 ? 11 : f.output));
        case kAudioHardwarePropertyTranslatePIDToProcessObject:
            assert(qualifierSize == sizeof(pid_t) && *static_cast<const pid_t *>(qualifier) == getpid());
            return give(size, data, f.own);
        case kAudioProcessPropertyPID: return give(size, data, getpid());
        case kAudioDevicePropertyDeviceIsAlive: return give(size, data, UInt32(id == 50 && !f.aggregateAlive ? 0 : 1));
        case kAudioDevicePropertyTransportType: return give(size, data, UInt32(kAudioDeviceTransportTypeUSB));
        case kAudioDevicePropertyBufferFrameSize: return give(size, data, UInt32(256));
        case kAudioDevicePropertyHogMode: return give(size, data, pid_t(f.hogged ? 1234 : -1));
        case kAudioDevicePropertyDeviceUID:
            return give(size, data, CFStringRef(CFRetain(id == 50 ? (__bridge CFStringRef)(f.aggregateReused ? @"foreign-aggregate" : f.aggregateUID) : CFSTR("fake-output"))));
        case kAudioDevicePropertyStreams: return give(size, data, AudioStreamID(id == 10 ? 20 : a->mScope == kAudioDevicePropertyScopeInput ? 40 : 41));
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioTapPropertyFormat: {
            auto format = f.format;
            if (id == 40 && f.planarInput) { format.mFormatFlags |= kAudioFormatFlagIsNonInterleaved; format.mBytesPerFrame = format.mBytesPerPacket = 4; }
            if (f.mismatch && id == 40) format.mSampleRate = 44100;
            return give(size, data, format);
        }
        case kAudioTapPropertyDescription:
            if (f.unmuted) f.description.muteBehavior = CATapUnmuted;
            if (f.tapReused) {
                CATapDescription *other = [[CATapDescription alloc] initExcludingProcesses:f.description.processes andDeviceUID:f.description.deviceUID withStream:0];
                return give(size, data, CFTypeRef(CFRetain((__bridge CFTypeRef)other)));
            }
            return give(size, data, CFTypeRef(CFRetain((__bridge CFTypeRef)f.description)));
        default: assert(false && "Unexpected HAL read"); return -1;
        }
    }
    static Boolean has(AudioObjectID, const AudioObjectPropertyAddress *) { return true; }
    static OSStatus size(AudioObjectID id, const AudioObjectPropertyAddress *a, UInt32, const void *, UInt32 *bytes) {
        assert(a->mSelector == kAudioDevicePropertyStreams);
        *bytes = id == 10 && a->mScope == kAudioDevicePropertyScopeInput && !current->inputDevice ? 0 : 4; return noErr;
    }
    static OSStatus createTap(CATapDescription *d, AudioObjectID *id) {
        auto &f = *current; if (f.operation("createTap")) return -1;
        if (f.tapFailure) return f.tapFailure;
        assert(d.isExclusive && d.isPrivate && !d.isMixdown && d.muteBehavior == CATapMuted);
        assert(d.processes.count == 1 && [d.processes containsObject:@(f.own)]);
        f.description = d; *id = 30; return noErr;
    }
    static OSStatus createAggregate(CFDictionaryRef dictionary, AudioObjectID *id) {
        auto &f = *current; if (f.operation("createAggregate")) return -1;
        NSDictionary *d = (__bridge NSDictionary *)dictionary;
        f.aggregateUID = d[@kAudioAggregateDeviceUIDKey];
        assert([d[@kAudioAggregateDeviceIsPrivateKey] boolValue]);
        assert(![d[@kAudioAggregateDeviceTapAutoStartKey] boolValue]);
        NSArray *devices = d[@kAudioAggregateDeviceSubDeviceListKey];
        assert(devices.count == 1 && [devices[0][@kAudioSubDeviceInputChannelsKey] unsignedIntValue] == 0);
        NSArray *taps = d[@kAudioAggregateDeviceTapListKey];
        assert(taps.count == 1 && [taps[0][@kAudioSubTapUIDKey] isEqualToString:f.description.UUID.UUIDString]);
        *id = 50; return noErr;
    }
    static OSStatus add(AudioObjectID, const AudioObjectPropertyAddress *a, dispatch_queue_t, AudioObjectPropertyListenerBlock b) {
        auto &f = *current; if (f.operation("add")) return -1; f.listeners.push_back([b copy]);
        if (f.formatRace && a->mSelector == kAudioTapPropertyFormat) f.mismatch = true;
        return noErr;
    }
    static OSStatus remove(AudioObjectID id, const AudioObjectPropertyAddress *, dispatch_queue_t, AudioObjectPropertyListenerBlock) {
        current->events.emplace_back("remove");
        if (current->missing.count(id)) return kAudioHardwareBadObjectError;
        if (current->failRemove || current->failedRemoveObject == id) return -1;
        return current->removeStatus;
    }
    static OSStatus createIO(AudioObjectID id, AudioDeviceIOProc callback, void *context, AudioDeviceIOProcID *proc) {
        auto &f = *current; if (f.operation("createIO")) return -1;
        assert(id == 50); f.callback = callback; f.context = context; *proc = callback; return noErr;
    }
    static OSStatus start(AudioObjectID id, AudioDeviceIOProcID) { assert(id == 50); current->time += current->startDelay; return current->operation("start") ? -1 : current->startFailure; }
    static OSStatus stop(AudioObjectID id, AudioDeviceIOProcID) { current->events.emplace_back("stop"); return current->missing.count(id) ? kAudioHardwareBadDeviceError : current->failStop ? -1 : current->stopStatus; }
    static OSStatus destroyIO(AudioObjectID id, AudioDeviceIOProcID) {
        current->events.emplace_back("destroyIO");
        if (current->aggregateGoneOnDestroyIO) current->missing.insert(id);
        if (current->aggregateReusedOnDestroyIO) current->aggregateReused=true;
        return current->missing.count(id) ? kAudioHardwareBadDeviceError : current->failDestroy ? -1 : current->destroyIOStatus;
    }
    static OSStatus destroyAggregate(AudioObjectID id) {
        assert(!current->aggregateReused); current->events.emplace_back("destroyAggregate");
        if (current->tapReusedOnDestroyAggregate) current->tapReused=true;
        return current->missing.count(id) ? kAudioHardwareBadObjectError : current->failAggregateDestroy ? -1 : current->destroyAggregateStatus;
    }
    static OSStatus destroyTap(AudioObjectID id) { assert(!current->tapReused); current->events.emplace_back("destroyTap"); return current->missing.count(id) ? kAudioHardwareBadObjectError : current->failTapDestroy ? -1 : current->destroyTapStatus; }
    static uint64_t now() { if (current->clockHook) current->clockHook(); return current->time; }
    TapAPI api() {
        TapAPI a; a.has = has; a.get = get; a.size = size; a.createTap = createTap; a.createAggregate = createAggregate;
        a.add = add; a.remove = remove; a.createIO = createIO; a.start = start; a.stop = stop;
        a.destroyIO = destroyIO; a.destroyAggregate = destroyAggregate; a.destroyTap = destroyTap; a.now = now;
        return a;
    }
    void notify(AudioObjectPropertySelector selector) {
        auto a = address(selector); assert(!listeners.empty()); listeners[0](1, &a);
    }
    bool happened(const char *event) { return std::find(events.begin(), events.end(), event) != events.end(); }
    void render(float value, float expected, bool malformed = false) {
        float input[512], output[512]; std::fill_n(input, 512, value); std::fill_n(output, 512, 17.f);
        AudioBufferList in{1, {{2, sizeof(input), input}}}, out{1, {{2, sizeof(output), output}}};
        if (malformed) in.mBuffers[0].mDataByteSize -= 4;
        AudioTimeStamp timestamp{};
        assert(callback); callback(50, &timestamp, &in, &timestamp, &out, &timestamp, context);
        // Ramp is done by frame 240; 256 frames here.
        assert(output[510] == expected && output[511] == expected);
        if (expected == 0) for (float x : output) assert(x == 0);
    }
};
Fake *Fake::current = nullptr;
}

int main() { @autoreleasepool {
    unsigned scenarios = 0, startupOperations = 0;
    { Fake f; EZProcessTapFailure error{};
      assert(EZProcessTapAvailable() && !EZProcessTapCreate(10, 0, 0, 1, &error) && error.stage == EZTapConsent && f.reads == 0);
      ++scenarios; }
    { Fake f; OSStatus error; auto s = createSession(f.api(), 10, error); assert(s && error == noErr);
      startupOperations = f.operations; TapHandle h(s); f.render(2, 0);
      assert(EZProcessTapSetGain(&h, 1, 0)); f.render(2, 2); // no full-scale limiter or doubling
      assert(EZProcessTapSetGain(&h, .5, 0)); f.render(2, 1);
      float gain; int muted; assert(EZProcessTapSnapshot(&h, &gain, &muted) && gain == .5 && muted == 0);
      f.notify(kAudioHardwarePropertyProcessObjectList); assert(s->healthy()); // future apps don't disable global exclusion
      f.notify(kAudioHardwarePropertyDevices); assert(s->healthy()); // our own aggregate list notification
      f.time += leaseNS / 2; EZProcessTapHeartbeat(&h); assert(s->healthy());
      assert(EZProcessTapSetGain(&h, 0, 0));
      // First zero command ramps. The following block is exact silence.
      float in[512]{}, out[512]{}; AudioBufferList il{1,{{2,sizeof(in),in}}}, ol{1,{{2,sizeof(out),out}}};
      AudioTimeStamp timestamp{};
      f.callback(50,&timestamp,&il,&timestamp,&ol,&timestamp,f.context); f.render(2, 0);
      assert(stopSafely(s));
      auto index = [&](const char *e) { return std::find(f.events.begin(),f.events.end(),e)-f.events.begin(); };
      assert(index("stop") < index("destroyIO") && index("destroyIO") < index("destroyAggregate") && index("destroyAggregate") < index("destroyTap"));
      scenarios += 7; }
    // Every creation/listener/start error unwinds without replay or unmanaged mute.
    for (unsigned n = 1; n <= startupOperations; ++n) {
        Fake f; f.failAt = n; OSStatus error = 0; auto s = createSession(f.api(),10,error);
        assert(!s && error != noErr);
        if (f.happened("createAggregate")) assert(f.happened("destroyTap"));
        if (f.happened("start")) assert(f.happened("stop"));
        ++scenarios;
    }
    for (UInt32 channels : {1U, 2U, 6U, 8U}) for (bool planar : {false, true}) {
        Fake f;
        f.format.mChannelsPerFrame = channels;
        f.format.mFormatFlags |= planar ? kAudioFormatFlagIsNonInterleaved : 0;
        f.format.mBytesPerFrame = f.format.mBytesPerPacket = planar ? 4 : 4 * channels;
        OSStatus error; auto s = createSession(f.api(),10,error); assert(s); TapHandle h(s);
        assert(EZProcessTapSetGain(&h,.5,0));
        struct List { UInt32 count; AudioBuffer buffers[8]; } input{}, output{};
        const UInt32 frames = 256, buffers = planar ? channels : 1;
        input.count = output.count = buffers;
        std::vector<std::vector<float>> in(buffers, std::vector<float>(frames * (planar ? 1 : channels)));
        auto out = in;
        for (UInt32 b = 0; b < buffers; ++b) {
            for (size_t i = 0; i < in[b].size(); ++i) in[b][i] = float(int((i + b) % 17) - 8) / 2;
            input.buffers[b] = {planar ? 1 : channels, UInt32(in[b].size()*4), in[b].data()};
            output.buffers[b] = {planar ? 1 : channels, UInt32(out[b].size()*4), out[b].data()};
        }
        AudioTimeStamp timestamp{};
        for (unsigned block = 0; block < 2; ++block)
            f.callback(50,&timestamp,reinterpret_cast<AudioBufferList*>(&input),&timestamp,
                       reinterpret_cast<AudioBufferList*>(&output),&timestamp,f.context);
        for (UInt32 b = 0; b < buffers; ++b) for (size_t i = 0; i < in[b].size(); ++i) assert(out[b][i] == in[b][i] * .5f);
        assert(stopSafely(s)); ++scenarios;
    }
    { Fake f; f.planarInput = true; OSStatus error; auto s = createSession(f.api(),10,error); assert(s); TapHandle h(s);
      EZProcessTapProgress progress{};
      assert(EZProcessTapReadProgress(&h,&progress) && !progress.ready && !progress.validFrames);
      struct StereoPlanes { UInt32 count; AudioBuffer buffers[2]; } input{};
      float left[256], right[256], output[512];
      std::fill_n(left,256,.4f); std::fill_n(right,256,-.8f);
      input = {2,{{1,sizeof(left),left},{1,sizeof(right),right}}};
      AudioBufferList out{1,{{2,sizeof(output),output}}}; AudioTimeStamp timestamp{};
      assert(EZProcessTapSetGain(&h,.5,0));
      for(int n=0;n<2;++n) f.callback(50,&timestamp,reinterpret_cast<AudioBufferList*>(&input),&timestamp,&out,&timestamp,f.context);
      for(unsigned i=0;i<256;++i) assert(output[i*2] == .2f && output[i*2+1] == -.4f);
      assert(EZProcessTapReadProgress(&h,&progress) && progress.ready && progress.validFrames == 512);
      assert(stopSafely(s)); scenarios += 3; }
    { Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); TapHandle h(s);
      float output[512]; std::fill_n(output,512,7.f);
      AudioBufferList empty{0,{}}, out{1,{{2,sizeof(output),output}}}; AudioTimeStamp timestamp{};
      f.callback(50,&timestamp,&empty,&timestamp,&out,&timestamp,f.context);
      for(float x:output) assert(x==0);
      EZProcessTapProgress progress{}; assert(EZProcessTapReadProgress(&h,&progress) && !progress.ready && progress.callbacks==1);
      for(int i=0;i<21;++i) {f.time+=250000000;EZProcessTapHeartbeat(&h);}
      assert(!EZProcessTapHealthy(&h));
      assert(EZProcessTapReadProgress(&h,&progress) && progress.stage==EZTapTimeout && progress.status==EZTapTimeoutFirstPCM);
      assert(stopSafely(s)); scenarios += 2; }
    { Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); TapHandle h(s); f.render(1,0);
      // An already validated stream may stop calling back while all sources are
      // idle. Owner heartbeats keep the same session available without replay.
      for(int i=0;i<7200;++i) {
          f.time+=250000000; EZProcessTapHeartbeat(&h); assert(EZProcessTapHealthy(&h));
      }
      EZProcessTapProgress progress{};
      assert(EZProcessTapReadProgress(&h,&progress) && progress.ready && progress.stage==EZTapNone);
      assert(EZProcessTapSetGain(&h,0,0)); f.render(1,0);
      assert(stopSafely(s)); ++scenarios; }
    { Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); TapHandle h(s);
      assert(EZProcessTapSetGain(&h,.4,0)); f.render(1,.4f);
      float output[512]; AudioBufferList empty{0,{}}, out{1,{{2,sizeof(output),output}}}; AudioTimeStamp timestamp{};
      // Empty callbacks over a long silent period remain healthy after initial
      // PCM validation, and every output block is exact silence.
      for(int i=0;i<7200;++i) {
          f.time+=250000000; EZProcessTapHeartbeat(&h);
          std::fill_n(output,512,7.f);
          f.callback(50,&timestamp,&empty,&timestamp,&out,&timestamp,f.context);
          assert(EZProcessTapHealthy(&h)); for(float x:output) assert(x==0);
      }
      assert(stopSafely(s)); ++scenarios; }
    for(unsigned command=0;command<3;++command) {
      Fake f; OSStatus error; auto s=createSession(f.api(),10,error,nullptr,1,0); assert(s); TapHandle h(s); f.render(1,1);
      for(int i=0;i<20;++i) { f.time+=250000000; EZProcessTapHeartbeat(&h); }
      const float gain=command==0 ? 0.f : command==1 ? .65f : .25f;
      const int muted=command==1 ? 1 : 0;
      assert(EZProcessTapSetGain(&h,gain,muted));
      float input[512], output[512]; std::fill_n(input,512,1.f); std::fill_n(output,512,7.f);
      AudioBufferList in{1,{{2,sizeof(input),input}}}, out{1,{{2,sizeof(output),output}}}; AudioTimeStamp timestamp{};
      f.callback(50,&timestamp,&in,&timestamp,&out,&timestamp,f.context);
      if(command<2) { for(float x:output) assert(x==0); }
      else {
          assert(output[0]>0 && output[0]<gain); // Fresh ramp, no old 100% envelope.
          assert(output[510]==gain && output[511]==gain);
          for(float x:output) assert(x>=0 && x<=gain);
      }
      float confirmed; int confirmedMute;
      assert(EZProcessTapSnapshot(&h,&confirmed,&confirmedMute) && confirmed==gain && confirmedMute==muted);
      assert(stopSafely(s)); ++scenarios;
    }
    // Progress and the owner heartbeat may detect the same lease expiry at
    // once. Every observed timeout must include its cause in that same read.
    for(unsigned cycle=0;cycle<500;++cycle) {
      Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); TapHandle h(s); f.render(1,0);
      f.time+=leaseNS; std::atomic_bool begin{false};
      std::thread owner([&] { while(!begin.load(std::memory_order_acquire)) {} EZProcessTapHeartbeat(&h); });
      std::thread reader([&] {
          while(!begin.load(std::memory_order_acquire)) {}
          for(unsigned read=0;read<20;++read) {
              EZProcessTapProgress progress{};
              assert(EZProcessTapReadProgress(&h,&progress) && !progress.ready &&
                     progress.stage==EZTapTimeout && progress.status==EZTapTimeoutOwnerLease);
          }
      });
      begin.store(true,std::memory_order_release); owner.join(); reader.join();
      assert(stopSafely(s));
    }
    ++scenarios;
    { Fake f; f.startDelay = 10000000000ULL; OSStatus error; auto s=createSession(f.api(),10,error); assert(s);
      f.render(1,0); assert(s->healthy()); assert(stopSafely(s)); ++scenarios; }
    { Fake f; f.formatRace = true; OSStatus error; auto s=createSession(f.api(),10,error);
      assert(!s && !f.happened("start")); ++scenarios; }
    { Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); TapHandle h(s);
      assert(EZProcessTapSetGain(&h,1,0)); f.render(1,1);
      float output[512]; AudioBufferList empty{0,{}}, out{1,{{2,sizeof(output),output}}}; AudioTimeStamp timestamp{};
      f.callback(50,&timestamp,&empty,&timestamp,&out,&timestamp,f.context);
      assert(EZProcessTapSetGain(&h,0,0));
      f.callback(50,&timestamp,&empty,&timestamp,&out,&timestamp,f.context);
      f.render(1,0); // Resuming after an empty stream at 0% must have no old-gain tail.
      assert(stopSafely(s)); ++scenarios; }
    // A system refusal is surfaced exactly, without hardware fallback or retry.
    for (bool refusedAtStart : {false, true}) {
        Fake f; const OSStatus refusal = -555;
        if (refusedAtStart) f.startFailure = refusal; else f.tapFailure = refusal;
        OSStatus error = 0; int32_t stage = 0; auto s = createSession(f.api(),10,error,&stage);
        assert(!s && error == refusal && stage == (refusedAtStart ? EZTapStartIO : EZTapCreate));
        assert(f.happened("start") == refusedAtStart);
        if (refusedAtStart) assert(f.happened("stop") && f.happened("destroyIO") && f.happened("destroyAggregate") && f.happened("destroyTap"));
        assert(quarantine().sessions.empty()); ++scenarios;
    }
    // Repeated successful lifetimes must not leave a quarantined session behind.
    for (int cycle = 0; cycle < 100; ++cycle) {
        Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); TapHandle h(s);
        f.render(1,0); assert(EZProcessTapSetGain(&h,1,0)); f.render(1,1);
        assert(stopSafely(s) && quarantine().sessions.empty());
    }
    ++scenarios;
    // UI commands race with the actual renderer; outputs remain finite and
    // sample-wise bounded, then settle to exact zero. No system audio is used.
    { Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); TapHandle h(s);
      std::thread writer([&] { for (int i=0;i<20000;++i) assert(EZProcessTapSetGain(&h,float(i%101)/100.f,i%13==0)); });
      float input[512], output[512]; for(unsigned i=0;i<512;++i) input[i]=float(int(i%37)-18)/4.f;
      AudioBufferList in{1,{{2,sizeof(input),input}}}, out{1,{{2,sizeof(output),output}}}; AudioTimeStamp t{};
      for(int block=0;block<2000;++block) {
        f.callback(50,&t,&in,&t,&out,&t,f.context);
        for(unsigned i=0;i<512;++i) assert(std::isfinite(output[i]) && std::abs(output[i])<=std::abs(input[i]));
      }
      writer.join(); assert(EZProcessTapSetGain(&h,0,1)); f.callback(50,&t,&in,&t,&out,&t,f.context); f.render(1,0);
      assert(stopSafely(s)); ++scenarios; }
    for (unsigned defect = 0; defect < 6; ++defect) {
        Fake f;
        if (defect == 0) f.inputDevice = true;
        if (defect == 1) f.mismatch = true;
        if (defect == 2) f.unmuted = true;
        if (defect == 3) f.own = 0;
        if (defect == 4) f.hogged = true;
        if (defect == 5) f.routeRace = true;
        OSStatus error; assert(!createSession(f.api(),10,error) && !f.happened("start")); ++scenarios;
    }
    for (auto selector : {kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice,
                          kAudioHardwarePropertyDevices, kAudioHardwarePropertyProcessObjectList}) {
        Fake f; OSStatus error; auto s = createSession(f.api(),10,error); assert(s); TapHandle h(s);
        assert(EZProcessTapSetGain(&h,1,0)); f.render(1,1);
        if (selector == kAudioHardwarePropertyProcessObjectList) f.own = 91;
        if (selector == kAudioHardwarePropertyDevices) f.aggregateAlive = false;
        f.notify(selector); f.render(1,0); assert(!EZProcessTapSetGain(&h,1,0));
        assert(stopSafely(s)); ++scenarios;
    }
    for (unsigned defect = 0; defect < 8; ++defect) {
        Fake f; OSStatus error; auto s = createSession(f.api(),10,error); assert(s); TapHandle h(s);
        assert(EZProcessTapSetGain(&h,1,0)); f.render(1,1);
        switch (defect) {
        case 0: assert(!EZProcessTapSetGain(&h,1.01,0)); break;
        case 1: assert(!EZProcessTapSetGain(&h,NAN,0)); break;
        case 2: {
            f.time += leaseNS; EZProcessTapHeartbeat(&h);
            EZProcessTapProgress progress{};
            assert(EZProcessTapReadProgress(&h,&progress) && progress.stage==EZTapTimeout && progress.status==EZTapTimeoutOwnerLease);
            break;
        }
        case 3: EZProcessTapPause(&h); break; // sleep/exit intent
        case 4: f.notify(kAudioStreamPropertyVirtualFormat); break;
        case 5: f.notify(kAudioTapPropertyDescription); break;
        case 6: f.render(1,0,true); break;
        case 7: assert(!EZProcessTapSetGain(&h,-.01,0)); break;
        }
        f.render(1,0); assert(!s->healthy()); assert(stopSafely(s)); ++scenarios;
    }
    { Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); f.render(1,0);
      f.failStop=true; const auto retired=quarantine().retired.size();
      assert(stopSafely(s) && quarantine().sessions.empty() && quarantine().retired.size()==retired+1);
      f.render(1,0); const auto operations=f.events.size(); assert(stopSafely(s) && f.events.size()==operations);
      ++scenarios; }
    { Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); f.render(1,0);
      f.missing.insert(20); assert(stopSafely(s) && quarantine().sessions.empty()); ++scenarios; }
    for(unsigned disappearance=0;disappearance<6;++disappearance) {
      Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); f.render(1,0);
      if(disappearance==0) f.missing.insert(50);
      if(disappearance==1) f.aggregateGoneOnDestroyIO=true;
      if(disappearance==2) f.aggregateReused=true;
      if(disappearance==3) f.tapReused=true;
      if(disappearance==4) f.aggregateReusedOnDestroyIO=true;
      if(disappearance==5) f.tapReusedOnDestroyAggregate=true;
      auto callback=f.callback; auto context=f.context; std::weak_ptr<TapSession> weak=s;
      const auto retired=quarantine().retired.size();
      assert(stopSafely(s) && quarantine().sessions.empty() && quarantine().retired.size()==retired+1);
      if(disappearance==0 || disappearance==2) assert(!f.happened("stop") && !f.happened("destroyIO") && !f.happened("destroyAggregate"));
      if(disappearance==3 || disappearance==5) assert(!f.happened("destroyTap"));
      if(disappearance==4) assert(!f.happened("destroyAggregate"));
      f.listeners.clear(); s.reset(); assert(!weak.expired());
      float input[512], output[512]; std::fill_n(input,512,1.f); std::fill_n(output,512,7.f);
      AudioBufferList in{1,{{2,sizeof(input),input}}}, out{1,{{2,sizeof(output),output}}}; AudioTimeStamp t{};
      callback(50,&t,&in,&t,&out,&t,context); for(float value:output) assert(value==0);
      // Retained silent contexts do not block a new validated session.
      f.missing.clear(); f.aggregateGoneOnDestroyIO=false; f.aggregateReused=false; f.tapReused=false;
      f.aggregateReusedOnDestroyIO=f.tapReusedOnDestroyAggregate=false;
      auto next=createSession(f.api(),10,error); assert(next && stopSafely(next)); ++scenarios;
    }
    { Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); f.render(1,0);
      f.classErrors[50]=kAudioHardwareNotReadyError;
      assert(!stopSafely(s) && s->proc && s->started && !f.happened("stop"));
      EZProcessTapCleanupFailure detail{};
      const auto reads=f.reads; const auto events=f.events.size();
      assert(EZProcessTapReadCleanupFailure(&detail) && detail.operation==EZTapCleanupInspectAggregate &&
             detail.objectID==50 && detail.selector==kAudioObjectPropertyClass && detail.status==kAudioHardwareNotReadyError);
      assert(f.reads==reads && f.events.size()==events);
      assert(!EZProcessTapRetryCleanup(&detail) && detail.operation==EZTapCleanupInspectAggregate);
      assert(!EZProcessTapRetryCleanup(nullptr));
      f.classErrors.clear(); assert(EZProcessTapRetryCleanup(&detail) && detail.operation==EZTapCleanupNone);
      assert(quarantine().sessions.empty()); ++scenarios;
    }
    { Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); f.render(1,0);
      f.stopStatus=f.destroyIOStatus=kAudioHardwareBadDeviceError;
      assert(!stopSafely(s) && s->proc && s->aggregate && s->tap && !f.happened("destroyAggregate"));
      EZProcessTapCleanupFailure detail{};
      assert(EZProcessTapReadCleanupFailure(&detail) && detail.operation==EZTapCleanupDestroyIO && detail.status==kAudioHardwareBadDeviceError);
      f.stopStatus=f.destroyIOStatus=noErr; assert(EZProcessTapRetryCleanup(&detail)); ++scenarios;
    }
    for(unsigned failure=0;failure<4;++failure) {
      Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); f.render(1,0);
      if(failure==0) f.failedRemoveObject=20;
      if(failure==1) { f.failedRemoveObject=kAudioObjectSystemObject; f.classErrors[kAudioObjectSystemObject]=kAudioHardwareBadObjectError; }
      if(failure==2) f.failAggregateDestroy=true;
      if(failure==3) f.failTapDestroy=true;
      assert(!stopSafely(s) && !quarantine().sessions.empty());
      assert(!s->proc && !s->started);
      if(failure<2) assert(!s->watches.empty() && s->listener && !f.happened("destroyAggregate"));
      const auto stops=std::count(f.events.begin(),f.events.end(),"stop");
      const auto destroys=std::count(f.events.begin(),f.events.end(),"destroyIO");
      const auto creates=std::count(f.events.begin(),f.events.end(),"createTap");
      f.failedRemoveObject=0; f.classErrors.clear(); f.failAggregateDestroy=f.failTapDestroy=false;
      EZProcessTapCleanupFailure detail{}; assert(EZProcessTapRetryCleanup(&detail));
      assert(std::count(f.events.begin(),f.events.end(),"stop")==stops &&
             std::count(f.events.begin(),f.events.end(),"destroyIO")==destroys &&
             std::count(f.events.begin(),f.events.end(),"createTap")==creates);
      const auto events=f.events.size(); const auto reads=f.reads;
      assert(EZProcessTapRetryCleanup(&detail) && detail.operation==0 && events==f.events.size() && reads==f.reads);
      assert(EZProcessTapRetryCleanup(nullptr) && events==f.events.size() && reads==f.reads);
      ++scenarios;
    }
    { Fake f; OSStatus error; auto s=createSession(f.api(),10,error); assert(s); f.render(1,0);
      std::atomic_bool entered{false}, release{false};
      f.clockHook=[&] { entered.store(true,std::memory_order_release); while(!release.load(std::memory_order_acquire)) {} };
      std::thread audio([&] { f.render(1,0); });
      while(!entered.load(std::memory_order_acquire)) {}
      assert(!stopSafely(s) && !f.happened("destroyAggregate") && !f.happened("destroyTap"));
      EZProcessTapCleanupFailure detail{};
      assert(EZProcessTapReadCleanupFailure(&detail) && detail.operation==EZTapCleanupWaitCallbacks);
      release.store(true,std::memory_order_release); audio.join(); f.clockHook=nullptr;
      assert(EZProcessTapRetryCleanup(&detail)); ++scenarios;
    }
    for (unsigned defect = 0; defect < 5; ++defect) {
        Fake f; OSStatus error; auto s = createSession(f.api(),10,error); assert(s);
        f.failStop = defect == 0; f.failDestroy = defect == 0 || defect == 1; f.failRemove = defect == 2;
        f.failAggregateDestroy = defect == 3; f.failTapDestroy = defect == 4;
        assert(!stopSafely(s)); f.render(1,0);
        assert(f.happened("destroyAggregate") == (defect >= 3));
        assert(f.happened("destroyTap") == (defect == 4));
        OSStatus blocked; assert(!createSession(f.api(),10,blocked));
        // This fixture has no system objects or asynchronous HAL callbacks.
        quarantine().sessions.clear(); ++scenarios;
    }
    for (float initial : {0.f, .42f, 1.f}) {
        Fake f; OSStatus error; auto s = createSession(f.api(),10,error,nullptr,initial,0); assert(s); TapHandle h(s);
        float gain; int muted; assert(EZProcessTapSnapshot(&h,&gain,&muted) && gain==initial && muted==0);
        f.render(1,initial); assert(s->dsp->current()==initial); assert(stopSafely(s)); ++scenarios;
    }
    { Fake f; OSStatus error; auto s=createSession(f.api(),10,error,nullptr,2.f,0);
      assert(!s && f.reads==0 && f.events.empty()); ++scenarios; }
    // Quarantined fake callbacks are never executed after this fixture lifetime.
    quarantine().sessions.clear();
    std::cout << "PASS " << scenarios << " process-tap lifecycle/callback scenarios; fake CoreAudio only\n";
} }
