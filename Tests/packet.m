#import "DDCBridge.h"
#import <assert.h>
int main(void) {
    uint8_t p[11] = {0x6e,0x88,0x02,0,0x62,0,1,44,0,25,0};
    p[10] = 0x50; for (int i=0;i<10;i++) p[10]^=p[i];
    assert(SACValidateReply(p,11,0x62));
    assert(!SACValidateReply(p,10,0x62));
    assert(!SACValidateReply(p,11,0x8d));
    uint8_t zero[11]={0}; assert(!SACValidateReply(zero,11,0x62));
    for (int i=0;i<11;i++) {p[i]^=1;assert(!SACValidateReply(p,11,0x62));p[i]^=1;}
    p[3]=1;p[10]^=1;assert(!SACValidateReply(p,11,0x62));
    puts("DDC reply validation: valid reply, length, command, zero reply, checksum and unsupported feature passed");
    return 0;
}
