/*
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * Copyright (c) 1998-2003 Apple Computer, Inc.  All Rights Reserved.
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


#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <pcap/pcap.h>

// Logging levels (matches the 1-7 "Logging Level" popup)
//
enum
{
    kUSBLoggerLevelErrors       = 1,    // failed transfers only
    kUSBLoggerLevelSetup        = 2,    // + control requests (setup packets)
    kUSBLoggerLevelCompletions  = 3,    // + every completed transfer
    kUSBLoggerLevelSubmits      = 4,    // + every submitted transfer
    kUSBLoggerLevelShortData    = 5,    // + first 64 bytes of each payload
    kUSBLoggerLevelLongData     = 6,    // + first 512 bytes of each payload
    kUSBLoggerLevelAllData      = 7     // + entire payload
};

@protocol USBLoggerListener <NSObject>

- (void)usbLoggerTextAvailable:(NSString *)text forLevel:(int)level;

@end

// Captures USB traffic from the XHCn packet capture interfaces (DLT_USB_DARWIN)
// via libpcap.  This replaces the old KLog.kext based logger.
//
@interface USBLogger : NSObject {
    id              _listener;
    int             _loggingLevel;
    BOOL            _isLogging;
    NSMutableDictionary *   _pendingControlRequests;   // capture thread only
}

// Names of the USB capture interfaces (XHC0, XHC1, ...) present on this machine
+ (NSArray *)captureInterfaces;
// The subset of +captureInterfaces that is not up (needs "ifconfig <if> up" as root)
+ (NSArray *)downCaptureInterfaces;

- initWithListener:(id <USBLoggerListener>)listener level:(int)level;

- (BOOL)beginLogging;
- (void)invalidate;
- (void)setLevel:(int)level;

@end
