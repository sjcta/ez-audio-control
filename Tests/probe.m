#import "DDCBridge.h"
int main(int argc, const char **argv) { @autoreleasepool {
    NSArray<SACDisplay *> *displays = [SACDisplay discover];
    if (!displays.count) { puts("No accessible external DDC displays."); return 2; }
    for (SACDisplay *display in displays) {
        printf("Display: %s\nUUID: %s\nLocation: %s\n", display.name.UTF8String, display.identifier.UTF8String, display.location.UTF8String);
        NSError *error = nil;
        SACReading *r = [display readCode:0x62 error:&error];
        if (!r) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 3; }
        printf("Volume: %ld / %ld\n",(long)r.current,(long)r.maximum);
        SACReading *mute = [display readCode:0x8d error:&error];
        printf("Mute: %s\n",mute ? [[NSString stringWithFormat:@"%ld",(long)mute.current] UTF8String] : error.localizedDescription.UTF8String);
        if (argc == 3 && !strcmp(argv[1], "--same-value") && !strcmp(argv[2], display.identifier.UTF8String)) {
            if (![display writeCode:0x62 value:(uint16_t)r.current error:&error]) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 4; }
            SACReading *after = [display readCode:0x62 error:&error];
            if (!after || after.current != r.current || after.maximum != r.maximum) { fputs("Same-value readback mismatch\n",stderr); return 5; }
            puts("Same-value write and readback verified.");
        }
    }
    return 0;
} }
