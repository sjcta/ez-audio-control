// DDC packet/IOAVService and framebuffer discovery adapted from m1ddc (MIT,
// Copyright (c) 2021 waydabber) and MonitorControl Arm64DDC (MIT,
// Copyright © 2017; © MonitorControl, @JoniVR, @theOneyouseek, @waydabber and others).
// Full licenses and pinned revisions: Licenses/ and THIRD_PARTY.md.
#import "DDCBridge.h"
#import <IOKit/IOKitLib.h>
#import <CoreGraphics/CoreGraphics.h>
#import <unistd.h>
typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef, io_service_t);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID);

static NSError *failure(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:@"SimpleAudioControl.DDC" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}
BOOL SACValidateReply(const uint8_t *p, size_t n, uint8_t code) {
    if (n != 11 || p[0] != 0x6e || p[1] != 0x88 || p[2] != 0x02 || p[3] != 0 || p[4] != code) return NO;
    uint8_t checksum = 0x50;
    for (size_t i = 0; i < n; i++) checksum ^= p[i];
    return checksum == 0;
}
@interface SACReading ()
@property(nonatomic) NSInteger current;
@property(nonatomic) NSInteger maximum;
@end
@implementation SACReading
- (instancetype)initWithCurrent:(NSInteger)current maximum:(NSInteger)maximum {
    if ((self = [super init])) { _current = current; _maximum = maximum; }
    return self;
}
@end
@interface SACDisplay ()
@property(nonatomic) NSString *identifier;
@property(nonatomic) NSString *name;
@property(nonatomic) NSString *location;
@property(nonatomic) uint32_t displayID;
@property(nonatomic) IOAVServiceRef avService;
@property(nonatomic) uint32_t chipAddress;
@end
@implementation SACDisplay
- (void)dealloc { if (_avService) CFRelease(_avService); }
+ (NSArray<SACDisplay *> *)discover {
    NSMutableArray *result = [NSMutableArray array];
    CGDirectDisplayID ids[32]; CGDisplayCount count = 0;
    if (CGGetOnlineDisplayList(32, ids, &count) != kCGErrorSuccess) return result;
    for (unsigned i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(ids[i])) continue;
        NSDictionary *info = CFBridgingRelease(CoreDisplay_DisplayCreateInfoDictionary(ids[i]));
        NSString *path = info[@"IODisplayLocation"], *uuid = info[@"kCGDisplayUUID"];
        if (![path isKindOfClass:NSString.class] || ![uuid isKindOfClass:NSString.class]) continue;
        io_registry_entry_t adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, (__bridge CFStringRef)path);
        uint64_t targetID = 0;
        if (!adapter) continue;
        IOReturn status = IORegistryEntryGetRegistryEntryID(adapter, &targetID);
        IOObjectRelease(adapter);
        if (status) continue;
        io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
        io_iterator_t iterator = 0;
        status = IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iterator);
        IOObjectRelease(root);
        if (status) continue;
        BOOL matches = NO; io_service_t entry;
        while ((entry = IOIteratorNext(iterator))) {
            if (IOObjectConformsTo(entry, "IOMobileFramebuffer")) {
                uint64_t entryID = 0;
                matches = !IORegistryEntryGetRegistryEntryID(entry, &entryID) && entryID == targetID;
            } else if (matches && IOObjectConformsTo(entry, "DCPAVServiceProxy")) {
                NSString *location = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), kCFAllocatorDefault, 0));
                IOAVServiceRef service = [location isEqual:@"External"] ? IOAVServiceCreateWithService(kCFAllocatorDefault, entry) : NULL;
                if (service) {
                    SACDisplay *d = [SACDisplay new]; d.avService = service; d.chipAddress = 0x37;
                    d.identifier = uuid; d.location = path; d.displayID = ids[i];
                    NSDictionary *names = info[@"DisplayProductName"];
                    d.name = names[@"en_US"] ?: names.allValues.firstObject ?: NSLocalizedString(@"外接显示器", nil);
                    io_registry_entry_t parent = 0;
                    if (!IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)) {
                        NSString *provider = CFBridgingRelease(IORegistryEntryCreateCFProperty(parent, CFSTR("EPICProviderClass"), kCFAllocatorDefault, 0));
                        if ([provider isEqual:@"AppleDCPMCDP29XX"]) d.chipAddress = 0xb7;
                        IOObjectRelease(parent);
                    }
                    [result addObject:d]; IOObjectRelease(entry); break;
                }
            }
            IOObjectRelease(entry);
        }
        IOObjectRelease(iterator);
    }
    return result;
}
- (SACReading *)readCode:(uint8_t)code error:(NSError **)error {
    if (code != 0x62 && code != 0x8d) { if (error) *error = failure(NSLocalizedString(@"只允许音量或静音操作", nil), -1); return nil; }
    IOReturn status = 0;
    for (unsigned attempt = 0; attempt < 3; attempt++) {
        uint8_t request[4] = {0x82, 0x01, code, (uint8_t)(0x6e ^ 0x82 ^ 0x01 ^ code)};
        usleep(10000);
        status = IOAVServiceWriteI2C(_avService, _chipAddress, 0x51, request, sizeof(request));
        if (status) continue;
        usleep(50000);
        uint8_t reply[11] = {0};
        status = IOAVServiceReadI2C(_avService, _chipAddress, 0, reply, sizeof(reply));
        if (!status && SACValidateReply(reply, sizeof(reply), code)) {
            SACReading *r = [SACReading new];
            r.maximum = ((uint16_t)reply[6] << 8) | reply[7];
            r.current = ((uint16_t)reply[8] << 8) | reply[9];
            if (code == 0x62 && (r.maximum == 0 || r.current > r.maximum)) break;
            if (code == 0x8d && r.current != 1 && r.current != 2) break;
            return r;
        }
        usleep(20000);
    }
    if (error) *error = failure([NSString stringWithFormat:NSLocalizedString(@"DDC 0x%02X 读取失败（0x%08X）：请检查连接与 DDC/CI", nil), code, status], status ?: -2);
    return nil;
}
- (BOOL)writeCode:(uint8_t)code value:(uint16_t)value error:(NSError **)error {
    if ((code != 0x62 && code != 0x8d) || (code == 0x8d && value != 1 && value != 2)) {
        if (error) *error = failure(NSLocalizedString(@"无效音量命令", nil), -1); return NO;
    }
    uint8_t request[6] = {0x84, 0x03, code, value >> 8, value & 255, 0};
    request[5] = 0x6e ^ 0x51;
    for (int i = 0; i < 5; i++) request[5] ^= request[i];
    usleep(10000);
    IOReturn status = IOAVServiceWriteI2C(_avService, _chipAddress, 0x51, request, sizeof(request));
    if (status && error) *error = failure([NSString stringWithFormat:NSLocalizedString(@"DDC 写入失败（0x%08X）", nil), status], status);
    return status == 0;
}
@end
