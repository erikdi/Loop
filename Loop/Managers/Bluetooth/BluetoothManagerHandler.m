/*
 This file is part of BeeTee Project. It is subject to the license terms in the LICENSE file found in the top-level directory of this distribution and at https://github.com/michaeldorner/BeeTee/blob/master/LICENSE. No part of BeeTee Project, including this file, may be copied, modified, propagated, or distributed except according to the terms contained in the LICENSE file.
 
 The MIT License (MIT)
 
 Copyright (c) 2016 Michael Dorner
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */

#import "BluetoothManagerHandler.h"
#import "BluetoothManager.h"

static BluetoothManager *_bluetoothManager = nil;
static BluetoothManagerHandler *_handler = nil;

@implementation BluetoothManagerHandler
    
    
+ (BluetoothManagerHandler*) sharedInstance {
    
    //static dispatch_once_t onceToken;
    //dispatch_once(&onceToken, ^{
    if (!_handler) {
        NSBundle *b = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/BluetoothManager.framework"];
        if (![b load]) {
            NSLog(@"Error"); // maybe throw an exception
        } else {
            @try {
               _bluetoothManager = [NSClassFromString(@"BluetoothManager") valueForKey:@"sharedInstance"];
               _handler = [[BluetoothManagerHandler alloc] init];
            }
            @catch(NSException *e ) {
                NSLog(@"Gosh!!! Error initializing BluetoothManager!! %@ %@ %@", [e name], [e reason], [e callStackSymbols]);
            }
        }
    }
    //});
    return _handler;
}
    
    
    - (bool) powered {
        return [_bluetoothManager powered];
    }
    
    
    - (void) setPower: (bool)powerStatus {
        [_bluetoothManager setPowered:powerStatus];
    }
    
    
    - (void) startScan {
        [_bluetoothManager setDeviceScanningEnabled: true];
        [_bluetoothManager scanForServices: 0xFFFFFFFF];
    }
    
    
    - (void) stopScan {
        [_bluetoothManager setDeviceScanningEnabled: false];
    }
    
    
    - (bool)isScanning {
        return [_bluetoothManager deviceScanningEnabled];
    }
    
    
    - (bool)enabled {
        return [_bluetoothManager enabled];
    }
    
    - (void)disable {
        [_bluetoothManager setEnabled:false];
    }
    
    - (void)enable {
        [_bluetoothManager setEnabled:true];
    }
    
    @end
