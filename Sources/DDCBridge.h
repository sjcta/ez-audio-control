#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SACReading : NSObject
- (instancetype)initWithCurrent:(NSInteger)current maximum:(NSInteger)maximum;
@property(nonatomic, readonly) NSInteger current;
@property(nonatomic, readonly) NSInteger maximum;
@end
@interface SACDisplay : NSObject
@property(nonatomic, readonly) NSString *identifier;
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSString *location;
@property(nonatomic, readonly) uint32_t displayID;
+ (NSArray<SACDisplay *> *)discover;
- (nullable SACReading *)readCode:(uint8_t)code error:(NSError **)error;
- (BOOL)writeCode:(uint8_t)code value:(uint16_t)value error:(NSError **)error;
@end
// Packet validation is shared by hardware reads and deterministic tests.
BOOL SACValidateReply(const uint8_t *reply, size_t length, uint8_t code);
NS_ASSUME_NONNULL_END

// Offline-gated process-tap candidate; never called by native/DDC backends.
#include "ProcessTapAudio.h"
