//
//  UserDefaults+Loop.swift
//  Loop
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit


extension UserDefaults {
    private enum Key: String {
        case pumpManagerState = "com.loopkit.Loop.PumpManagerState"
        case sensorSessionStartDate = "com.loopkit.Loop.sensorSessionStartDate"
    }

    var pumpManagerRawValue: [String: Any]? {
        get {
            return dictionary(forKey: Key.pumpManagerState.rawValue)
        }
        set {
            set(newValue, forKey: Key.pumpManagerState.rawValue)
        }
    }

    var cgmManager: CGMManager? {
        get {
            guard let rawValue = cgmManagerState else {
                return nil
            }

            return CGMManagerFromRawValue(rawValue)
        }
        set {
            cgmManagerState = newValue?.rawValue
        }
    }

    var sensorSessionStartDate: Date? {
        get {
            let value = double(forKey: Key.sensorSessionStartDate.rawValue)
            if value > 0 {
                return Date(timeIntervalSinceReferenceDate: value)
            } else {
                return nil
            }
        }
        set {
            if newValue == nil {
                removeObject(forKey: Key.sensorSessionStartDate.rawValue)
            } else {
                set(newValue?.timeIntervalSinceReferenceDate, forKey: Key.sensorSessionStartDate.rawValue)
            }
        }
    }
}
