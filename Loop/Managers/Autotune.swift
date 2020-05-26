//
//  Autotune.swift
//  Loop
//
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import Foundation

class AutoTune : AutoAdjust {
    func run() {
        if abs(manager.settings.lastAutotune.timeIntervalSinceNow) < manager.settings.autotuneInterval {
            NSLog("Autotune - last invocation too close \(manager.settings.lastAutotune)")
            return
        }
        let startDate = Date(timeIntervalSinceNow: -manager.settings.autotuneLookbackInterval)
        let endDate = Date()
        logger.default("Autotune - running on data from \(startDate) until \(endDate)")
        logger.error("Autotune - not implemented")
        //manager.settings.lastAutotune = Date()
    }
}
