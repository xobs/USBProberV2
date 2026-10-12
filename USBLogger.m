/*
 * Copyright � 1998-2012 Apple Inc.  All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

#import "USBLogger.h"
#import <IOKit/IOReturn.h>
#import <IOKit/usb/IOUSBHostFamilyDefinitions.h>
#import <libkern/OSByteOrder.h>
#import <sys/select.h>
#import <net/if.h>
#import <time.h>

// Each XHCn capture interface delivers packets with this little-endian header
// (LINKTYPE_USB_DARWIN, layout as decoded by Wireshark's packet-usb.c).  The
// payload starts at headerLength; for a control SUBMIT it begins with the
// 8-byte setup packet.
//
#define kDarwinUSBHeaderMinLength   32

#define kDarwinUSBRequestSubmit     0
#define kDarwinUSBRequestComplete   1

#define kMaxCaptureInterfaces       16
#define kCaptureSnapLength          65535
#define kCaptureBufferSize          (4 * 1024 * 1024)
#define kMaxPendingControlRequests  4096

typedef struct {
    USBLogger *     logger;
    pcap_t *        handle;
    char            name[IF_NAMESIZE + 1];
} USBCaptureInterface;

static USBCaptureInterface  gInterfaces[kMaxCaptureInterfaces];
static int                  gInterfaceCount = 0;

@interface USBLogger (Private)
- (void)captureThread;
- (void)handlePacket:(const u_char *)bytes header:(const struct pcap_pkthdr *)header interface:(const char *)ifName;
- (void)emit:(NSString *)text level:(int)level time:(struct timeval)ts;
@end

static void HandlePacket(u_char *user, const struct pcap_pkthdr *header, const u_char *bytes)
{
    USBCaptureInterface *intf = (USBCaptureInterface *)user;
    [intf->logger handlePacket:bytes header:header interface:intf->name];
}

static NSString * TransferTypeName(UInt8 type)
{
    switch (type) {
        case 0: return @"Control";
        case 1: return @"Isoch";
        case 2: return @"Bulk";
        case 3: return @"Interrupt";
        default: return [NSString stringWithFormat:@"Type%d", type];
    }
}

static NSString * SpeedName(UInt8 speed)
{
    switch (speed) {
        case 0: return @"Low";
        case 1: return @"Full";
        case 2: return @"High";
        case 3: return @"Super";
        case 4: return @"Super+";
        default: return [NSString stringWithFormat:@"Speed%d", speed];
    }
}

static NSString * StatusName(IOReturn status)
{
    switch (status) {
        case kIOReturnSuccess:          return @"Success";
        case kIOReturnError:            return @"kIOReturnError";
        case kIOReturnNoDevice:         return @"kIOReturnNoDevice";
        case kIOReturnBadArgument:      return @"kIOReturnBadArgument";
        case kIOReturnIOError:          return @"kIOReturnIOError";
        case kIOReturnTimeout:          return @"kIOReturnTimeout";
        case kIOReturnNotResponding:    return @"kIOReturnNotResponding";
        case kIOReturnUnderrun:         return @"kIOReturnUnderrun";
        case kIOReturnOverrun:          return @"kIOReturnOverrun";
        case kIOReturnDeviceError:      return @"kIOReturnDeviceError";
        case kIOReturnAborted:          return @"kIOReturnAborted";
        case kIOReturnNoBandwidth:      return @"kIOReturnNoBandwidth";
        case kIOReturnIsoTooOld:        return @"kIOReturnIsoTooOld";
        case kIOReturnIsoTooNew:        return @"kIOReturnIsoTooNew";
        case kIOReturnOffline:          return @"kIOReturnOffline";
        case kUSBHostReturnPipeStalled: return @"kUSBHostReturnPipeStalled";
        default:                        return [NSString stringWithFormat:@"0x%08x", status];
    }
}

static NSString * DescriptorTypeName(UInt8 type)
{
    switch (type) {
        case 0x01: return @"Device";
        case 0x02: return @"Configuration";
        case 0x03: return @"String";
        case 0x04: return @"Interface";
        case 0x05: return @"Endpoint";
        case 0x06: return @"DeviceQualifier";
        case 0x07: return @"OtherSpeedConfiguration";
        case 0x0B: return @"InterfaceAssociation";
        case 0x0F: return @"BOS";
        case 0x21: return @"HID";
        case 0x22: return @"HIDReport";
        case 0x29: return @"Hub";
        case 0x2A: return @"SuperSpeedHub";
        default:   return [NSString stringWithFormat:@"0x%02x", type];
    }
}

// Human readable summary of an 8-byte setup packet
static NSString * DescribeSetupPacket(const u_char *setup)
{
    UInt8   bmRequestType = setup[0];
    UInt8   bRequest = setup[1];
    UInt16  wValue = OSReadLittleInt16(setup, 2);
    UInt16  wIndex = OSReadLittleInt16(setup, 4);
    UInt16  wLength = OSReadLittleInt16(setup, 6);
    NSString *request = nil;

    switch ((bmRequestType >> 5) & 0x3) {
        case 0:
            switch (bRequest) {
                case 0x00: request = @"GET_STATUS"; break;
                case 0x01: request = @"CLEAR_FEATURE"; break;
                case 0x03: request = @"SET_FEATURE"; break;
                case 0x05: request = [NSString stringWithFormat:@"SET_ADDRESS(%d)", wValue]; break;
                case 0x06: request = [NSString stringWithFormat:@"GET_DESCRIPTOR(%@ #%d)", DescriptorTypeName(wValue >> 8), wValue & 0xff]; break;
                case 0x07: request = [NSString stringWithFormat:@"SET_DESCRIPTOR(%@ #%d)", DescriptorTypeName(wValue >> 8), wValue & 0xff]; break;
                case 0x08: request = @"GET_CONFIGURATION"; break;
                case 0x09: request = [NSString stringWithFormat:@"SET_CONFIGURATION(%d)", wValue]; break;
                case 0x0A: request = @"GET_INTERFACE"; break;
                case 0x0B: request = [NSString stringWithFormat:@"SET_INTERFACE(%d alt %d)", wIndex, wValue]; break;
                case 0x0C: request = @"SYNCH_FRAME"; break;
                case 0x30: request = @"SET_SEL"; break;
                case 0x31: request = @"SET_ISOCH_DELAY"; break;
                default:   request = [NSString stringWithFormat:@"Standard request 0x%02x", bRequest]; break;
            }
            break;
        case 1:  request = [NSString stringWithFormat:@"Class request 0x%02x", bRequest]; break;
        case 2:  request = [NSString stringWithFormat:@"Vendor request 0x%02x", bRequest]; break;
        default: request = [NSString stringWithFormat:@"Reserved request 0x%02x", bRequest]; break;
    }

    return [NSString stringWithFormat:@"%@  [%02x %02x %04x %04x %04x]", request, bmRequestType, bRequest, wValue, wIndex, wLength];
}

@implementation USBLogger

+ (NSArray *)captureInterfacesWithFlags:(bpf_u_int32)requiredFlags absent:(bpf_u_int32)absentFlags {
    NSMutableArray *    names = [NSMutableArray array];
    pcap_if_t *         allDevs = NULL;
    pcap_if_t *         dev;
    char                errbuf[PCAP_ERRBUF_SIZE];

    if (pcap_findalldevs(&allDevs, errbuf) != 0) {
        NSLog(@"USB Prober: pcap_findalldevs failed: %s\n", errbuf);
        return names;
    }
    for (dev = allDevs; dev != NULL; dev = dev->next) {
        if (strncmp(dev->name, "XHC", 3) != 0)
            continue;
        if ((dev->flags & requiredFlags) != requiredFlags || (dev->flags & absentFlags) != 0)
            continue;
        [names addObject:[NSString stringWithUTF8String:dev->name]];
    }
    pcap_freealldevs(allDevs);
    return names;
}

+ (NSArray *)captureInterfaces {
    return [self captureInterfacesWithFlags:0 absent:0];
}

+ (NSArray *)downCaptureInterfaces {
    return [self captureInterfacesWithFlags:0 absent:PCAP_IF_UP];
}

- initWithListener:(id <USBLoggerListener> )listener level:(int)level {
    if (self = [super init]) {
        if (listener == nil) {
            [NSException raise:@"USB ProberBadListener" format:@"Listener must be non-nil"];
            [self release];
            return nil;
        }
        _listener = [listener retain];
        _loggingLevel = level;
        _isLogging = NO;
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
    [_listener release];
    [super dealloc];
}

- (BOOL)beginLogging {
    NSArray *       names;
    NSEnumerator *  nameEnumerator;
    NSString *      name;
    char            errbuf[PCAP_ERRBUF_SIZE];
    BOOL            permissionDenied = NO;

    if (_isLogging || gInterfaceCount != 0) {
        [_listener usbLoggerTextAvailable:@"USB Prober: [ERR] A capture is already running\n" forLevel:0];
        return NO;
    }

    names = [USBLogger captureInterfaces];
    if ([names count] == 0) {
        [_listener usbLoggerTextAvailable:@"USB Prober: [ERR] No USB capture interfaces (XHCn) were found\n" forLevel:0];
        return NO;
    }

    nameEnumerator = [names objectEnumerator];
    while ((name = [nameEnumerator nextObject]) && gInterfaceCount < kMaxCaptureInterfaces) {
        USBCaptureInterface *   intf = &gInterfaces[gInterfaceCount];
        pcap_t *                handle;
        int                     rc;

        handle = pcap_create([name UTF8String], errbuf);
        if (handle == NULL) {
            [_listener usbLoggerTextAvailable:[NSString stringWithFormat:@"USB Prober: [ERR] %@: %s\n", name, errbuf] forLevel:0];
            continue;
        }
        pcap_set_snaplen(handle, kCaptureSnapLength);
        pcap_set_immediate_mode(handle, 1);
        pcap_set_buffer_size(handle, kCaptureBufferSize);

        rc = pcap_activate(handle);
        if (rc < 0) {
            if (rc == PCAP_ERROR_PERM_DENIED)
                permissionDenied = YES;
            [_listener usbLoggerTextAvailable:[NSString stringWithFormat:@"USB Prober: [ERR] %@: %s\n", name, pcap_geterr(handle)] forLevel:0];
            pcap_close(handle);
            continue;
        }
        if (pcap_datalink(handle) != DLT_USB_DARWIN) {
            [_listener usbLoggerTextAvailable:[NSString stringWithFormat:@"USB Prober: [ERR] %@: unexpected link type %d\n", name, pcap_datalink(handle)] forLevel:0];
            pcap_close(handle);
            continue;
        }
        if (pcap_setnonblock(handle, 1, errbuf) != 0) {
            [_listener usbLoggerTextAvailable:[NSString stringWithFormat:@"USB Prober: [ERR] %@: %s\n", name, errbuf] forLevel:0];
            pcap_close(handle);
            continue;
        }

        intf->logger = self;
        intf->handle = handle;
        strlcpy(intf->name, [name UTF8String], sizeof(intf->name));
        gInterfaceCount++;
    }

    if (gInterfaceCount == 0) {
        if (permissionDenied) {
            [_listener usbLoggerTextAvailable:@"USB Prober: [ERR] No permission to open /dev/bpf*. Install Wireshark's ChmodBPF package (or run USB Prober as root) to allow packet capture.\n" forLevel:0];
        }
        return NO;
    }

    _isLogging = YES;
    [NSThread detachNewThreadSelector:@selector(captureThread) toTarget:self withObject:nil];
    return YES;
}

- (void)invalidate {
    _isLogging = NO;
}

- (void)setLevel:(int)level {
    _loggingLevel = level;
}

@end

@implementation USBLogger (Private)

- (void)captureThread
{
    NSAutoreleasePool *     pool = [[NSAutoreleasePool alloc] init];
    NSMutableString *       names = [NSMutableString string];
    static bool             calledOnce = false;
    int                     i;

    _pendingControlRequests = [[NSMutableDictionary alloc] init];

    if (calledOnce == false) {
        [_listener usbLoggerTextAvailable:@"Timestamp            Lvl  \tMessage\n" forLevel:0];
        [_listener usbLoggerTextAvailable:@"-------------------  ---\t--------------------------------------\n" forLevel:0];
        calledOnce = true;
    }

    for (i = 0; i < gInterfaceCount; i++)
        [names appendFormat:@"%s%s", (i == 0) ? "" : ", ", gInterfaces[i].name];
    [_listener usbLoggerTextAvailable:[NSString stringWithFormat:@"USB Prober: capturing on %@\n", names] forLevel:0];

    while (_isLogging) {
        NSAutoreleasePool * loopPool = [[NSAutoreleasePool alloc] init];
        fd_set              readFds;
        int                 maxFd = -1;
        struct timeval      timeout = { 0, 250000 };

        FD_ZERO(&readFds);
        for (i = 0; i < gInterfaceCount; i++) {
            int fd = pcap_get_selectable_fd(gInterfaces[i].handle);
            if (fd >= 0) {
                FD_SET(fd, &readFds);
                if (fd > maxFd)
                    maxFd = fd;
            }
        }

        if (select(maxFd + 1, &readFds, NULL, NULL, &timeout) > 0) {
            for (i = 0; i < gInterfaceCount && _isLogging; i++) {
                if (FD_ISSET(pcap_get_selectable_fd(gInterfaces[i].handle), &readFds)) {
                    if (pcap_dispatch(gInterfaces[i].handle, -1, HandlePacket, (u_char *)&gInterfaces[i]) < 0) {
                        [_listener usbLoggerTextAvailable:[NSString stringWithFormat:@"USB Prober: [ERR] %s: %s\n", gInterfaces[i].name, pcap_geterr(gInterfaces[i].handle)] forLevel:0];
                        _isLogging = NO;
                    }
                }
            }
        }
        [loopPool release];
    }

    for (i = 0; i < gInterfaceCount; i++) {
        pcap_close(gInterfaces[i].handle);
        gInterfaces[i].handle = NULL;
        gInterfaces[i].logger = nil;
    }
    gInterfaceCount = 0;

    [_pendingControlRequests release];
    _pendingControlRequests = nil;
    [pool release];
}

- (void)emit:(NSString *)text level:(int)level time:(struct timeval)ts
{
    time_t      seconds = ts.tv_sec;
    struct tm   localTime;
    char        timestr[32];

    localtime_r(&seconds, &localTime);
    strftime(timestr, sizeof(timestr), "%b %d %H:%M:%S", &localTime);
    [_listener usbLoggerTextAvailable:[NSString stringWithFormat:@"%s.%03d  [%d]\t%@\n", timestr, (int)(ts.tv_usec / 1000), level, text] forLevel:level];
}

- (void)handlePacket:(const u_char *)bytes header:(const struct pcap_pkthdr *)header interface:(const char *)ifName
{
    UInt32          captured = header->caplen;
    UInt32          headerLength;
    BOOL            isSubmit;
    UInt32          ioLength;
    IOReturn        status;
    UInt32          isochFrames;
    UInt64          ioID;
    UInt32          locationID;
    UInt8           speed, deviceAddress, endpoint, transferType;
    const u_char *  payload;
    UInt32          payloadLength;
    int             level;
    int             dumpLimit;
    NSNumber *      requestKey;
    NSString *      request = nil;
    NSMutableString *line;

    if (!_isLogging || captured < kDarwinUSBHeaderMinLength)
        return;

    headerLength    = bytes[2];
    isSubmit        = (bytes[3] == kDarwinUSBRequestSubmit);
    ioLength        = OSReadLittleInt32(bytes, 4);
    status          = (IOReturn)OSReadLittleInt32(bytes, 8);
    isochFrames     = OSReadLittleInt32(bytes, 12);
    ioID            = OSReadLittleInt64(bytes, 16);
    locationID      = OSReadLittleInt32(bytes, 24);
    speed           = bytes[28];
    deviceAddress   = bytes[29];
    endpoint        = bytes[30];
    transferType    = bytes[31];

    if (headerLength < kDarwinUSBHeaderMinLength)
        headerLength = kDarwinUSBHeaderMinLength;
    if (headerLength > captured)
        headerLength = captured;
    payload = bytes + headerLength;
    payloadLength = captured - headerLength;

    // Control requests are described by their setup packet on SUBMIT; remember
    // that description so the matching COMPLETE can be labelled with it.
    requestKey = [NSNumber numberWithUnsignedLongLong:ioID];
    if (transferType == 0) {
        if (isSubmit && payloadLength >= 8) {
            request = DescribeSetupPacket(payload);
            payload += 8;
            payloadLength -= 8;
            if ([_pendingControlRequests count] >= kMaxPendingControlRequests)
                [_pendingControlRequests removeAllObjects];
            [_pendingControlRequests setObject:request forKey:requestKey];
        } else if (!isSubmit) {
            request = [[[_pendingControlRequests objectForKey:requestKey] retain] autorelease];
            [_pendingControlRequests removeObjectForKey:requestKey];
        }
    }

    if (!isSubmit && status != kIOReturnSuccess)
        level = kUSBLoggerLevelErrors;
    else if (isSubmit && transferType == 0)
        level = kUSBLoggerLevelSetup;
    else if (!isSubmit)
        level = kUSBLoggerLevelCompletions;
    else
        level = kUSBLoggerLevelSubmits;

    if (level > _loggingLevel)
        return;

    line = [NSMutableString stringWithFormat:@"%s  Loc 0x%08x  Addr %d (%@)  EP 0x%02x %@ %@  %@  %u bytes",
            ifName, locationID, deviceAddress, SpeedName(speed), endpoint, TransferTypeName(transferType),
            (endpoint & 0x80) ? @"IN" : @"OUT", isSubmit ? @"Submit  " : @"Complete", ioLength];
    if (!isSubmit)
        [line appendFormat:@"  %@", StatusName(status)];
    if (transferType == 1)
        [line appendFormat:@"  %u frames", isochFrames];
    if (request != nil)
        [line appendFormat:@"  %@", request];
    [self emit:line level:level time:header->ts];

    // Payload hex dump
    if (_loggingLevel >= kUSBLoggerLevelAllData)
        dumpLimit = payloadLength;
    else if (_loggingLevel >= kUSBLoggerLevelLongData)
        dumpLimit = 512;
    else if (_loggingLevel >= kUSBLoggerLevelShortData)
        dumpLimit = 64;
    else
        dumpLimit = 0;

    if (dumpLimit > 0 && payloadLength > 0) {
        UInt32  dumpLength = MIN(payloadLength, (UInt32)dumpLimit);
        UInt32  offset, i;

        for (offset = 0; offset < dumpLength; offset += 16) {
            NSMutableString *hex = [NSMutableString stringWithFormat:@"    %04x: ", offset];
            NSMutableString *ascii = [NSMutableString string];

            for (i = offset; i < offset + 16; i++) {
                if (i < dumpLength) {
                    [hex appendFormat:@"%02x ", payload[i]];
                    [ascii appendFormat:@"%c", (payload[i] >= 0x20 && payload[i] < 0x7f) ? payload[i] : '.'];
                } else {
                    [hex appendString:@"   "];
                }
            }
            [self emit:[NSString stringWithFormat:@"%@ %@", hex, ascii] level:kUSBLoggerLevelShortData time:header->ts];
        }
        if (dumpLength < payloadLength)
            [self emit:[NSString stringWithFormat:@"    ... %u more bytes", payloadLength - dumpLength] level:kUSBLoggerLevelShortData time:header->ts];
    }
}

@end
