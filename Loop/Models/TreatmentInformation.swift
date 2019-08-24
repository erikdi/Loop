//
//  Loop
//
//  Created by Erik on 9/1/17.
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import Foundation
import CarbKit
import HealthKit
import InsulinKit
import LoopKit
import MinimedKit
import HealthKit
import GlucoseKit
import RileyLinkKit


struct TreatmentInformation {
    enum BolusState : String {
        case none  // none given
        case prohibited // not allowed
        case recommended // recommendation
        // command sent to pump
        case sent
        // initial states
        case pending
        case maybefailed
        // result
        case failed
        case success
        case timeout
    }
    var state : BolusState = .none
    var units : Double = 0.0
    var carbs : Double = 0.0
    var date : Date
    var sent : Date?
    // if a new bolus is allowed
    var allowed : Bool = false
    var message : String = ""
    
    var reservoir: ReservoirValue? = nil
    var attempts: Int? = 0

    func equal(_ other: TreatmentInformation) -> Bool {
        return state == other.state && date == other.date && units == other.units && message == other.message && allowed == other.allowed
    }
    
    func inProgress() -> Bool {
        return state == .pending || state == .maybefailed || state == .sent
    }
    
    func description() -> String {
        switch state {
        case .none: return ""
        case .prohibited: return "Prohibited"
        case .recommended: return "Recommended"
            
        case .sent: return "Pending"
        case .pending: return "Delivering"

        case .maybefailed: return "Maybe failed"

        case .failed: return "Failed"
        case .success: return "Successful"
        case .timeout: return "Timed out"
        }
    }
    
    func kind() -> String {
        if state == .recommended && carbs > 0 {
            return "Carbs"
        }
        return "Bolus"
    }
    
    func explanation(bolusEnabled: Bool = true) -> String {
        var val = ""
        switch state {
        case .none:
            val = ""
        case .prohibited:
            val = "Data old, pump in reach?"
        case .recommended:
            if units > 0 {
                let _ = bolusEnabled
                /*if bolusEnabled {
                    val = "Will be automatically given."
                } else {*/
                // In the carb only case this determination is not correct.
                // Rather be safe and tell the user to tap, but have their back
                // if they don't.
                    val = "Tap to deliver now."
                //}
            } else if carbs > 0 {
                let i = Int(carbs)
                val = "Eat \(i) g fast acting carbs like juice, glucose tabs, etc."
            }
        case .sent:
            val = "Sending command to pump."
        case .pending:
            val = "(can turn phone off)."
        case .maybefailed:
            val = "Check pump!"
            
        case .failed:
            val = "Pump in reach?"
        case .success:
            val = "Success!"
        case .timeout:
            val = "Timeout - Check pump!"
            
        }
        if message != "" {
            val = "\(val) - \(message)"
        }
        if let a = attempts, a > 1 {
            val = "\(val) [#\(a)]"
        }
        return val
    }
}
