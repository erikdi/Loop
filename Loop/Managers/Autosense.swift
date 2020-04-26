//
//  Autosense.swift
//  Loop
//
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopCore
import LoopKit
import HealthKit



class AutoAdjust {

    var insulinEffect : [GlucoseEffect]? = nil
    var insulinCounteractionEffects : [GlucoseEffectVelocity]? = nil
    var cobValues : [CarbValue]? = nil
    var carbSamples : [StoredCarbEntry]? = nil
    var carbEffect : [GlucoseEffect]? = nil
    var iobValues : [InsulinValue]? = nil
    var glucoseSamples : [StoredGlucoseSample]? = nil
    let glucoseUnit = HKUnit.milligramsPerDeciliter
    var retrospectiveGlucoseDiscrepancies : [GlucoseValue]? = nil

    var manager : LoopDataManager
    var logger : CategoryLogger

    init(manager: LoopDataManager) {
        self.manager = manager
        self.logger = DiagnosticLogger.shared.forCategory("AutoAdjust")

    }

    func logDebug() {
        logger.debug("insulinEffect")
        for entry in self.insulinEffect ?? [] {
            logger.debug("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: glucoseUnit))")
        }
        logger.debug("insulinCounteractionEffects")
        for entry in self.insulinCounteractionEffects ?? [] {
            let perInterval = entry.endDate.timeIntervalSince(entry.startDate) * entry.quantity.doubleValue(for: GlucoseEffectVelocity.unit)
            logger.debug("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: GlucoseEffectVelocity.unit)), \(perInterval)")
        }
        logger.debug("cobValues")
         for entry in self.cobValues ?? [] {
            logger.debug("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: .gram()))")
         }
        logger.debug("carbEffect")
        for entry in self.carbEffect ?? [] {
            logger.debug("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: glucoseUnit))")
        }
        logger.debug("iobValues")
        for entry in self.iobValues ?? [] {
            logger.debug("* \(entry.startDate), \(entry.endDate), \(entry.value)")
        }
        logger.debug("glucoseSamples")
        for entry in self.glucoseSamples ?? [] {
            logger.debug("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: glucoseUnit))")
        }
        logger.debug("retrospectiveGlucoseDiscrepancies")
        for entry in self.retrospectiveGlucoseDiscrepancies ?? [] {
            logger.debug("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: glucoseUnit))")
        }

    }

    func fetchSync(startDate: Date, endDate: Date) {
        let updateGroup = DispatchGroup()
        updateGroup.enter()
        manager.doseStore.getGlucoseEffects(start: startDate, end: endDate) { (result) -> Void in
            switch result {
            case .failure(let error):
                self.logger.error(error)
            case .success(let effects):
                self.insulinEffect = effects
            }

            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)
        guard insulinEffect != nil else {
            logger.error("insulinEffect cannot be retrieved")
            return
        }

        updateGroup.enter()
        manager.glucoseStore.getCounteractionEffects(start: startDate, end: endDate, to: insulinEffect!) { (velocities) in
            self.insulinCounteractionEffects = velocities

            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)
        guard self.insulinCounteractionEffects != nil else {
            logger.error("insulinCounterActionEffects cannot be retrieved")
            return
        }

        updateGroup.enter()
        manager.carbStore.getCarbsOnBoardValues(start: startDate, end: endDate, effectVelocities: manager.settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects! : nil) { (values) in
            self.cobValues = values
            updateGroup.leave()
        }

        updateGroup.enter()
        manager.carbStore.getGlucoseEffects(
            start: startDate,
            end: endDate,
            effectVelocities: manager.settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects! : nil
        ) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                case .success(let (samples, effects)):
                    self.carbEffect = effects
                    self.carbSamples = samples
                }
                updateGroup.leave()
        }

        updateGroup.enter()
        manager.doseStore.getInsulinOnBoardValues(start: startDate, end: endDate) { (result) in
            switch result {
            case .success(let values):
                self.iobValues = values
            case .failure(let error):
                self.logger.error("Could not fetch insulin on board: \(error)")
            }
            updateGroup.leave()
        }

        updateGroup.enter()
        manager.glucoseStore.getCachedGlucoseSamples(start: startDate, end: endDate) { (values) in
            self.glucoseSamples = values
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)
        if let carbEffect = self.carbEffect, let ice = insulinCounteractionEffects {
            retrospectiveGlucoseDiscrepancies = ice.subtracting(carbEffect, withUniformInterval: manager.carbStore.delta)
        }

    }
}

extension AutoAdjust {
    func autoSense() {
            if abs(manager.settings.lastAutosense.timeIntervalSinceNow) < manager.settings.autosenseInterval {
                NSLog("Autosense - last invocation too close \(manager.settings.lastAutosense)")
                return
            }
        let startDate = Date(timeIntervalSinceNow: -manager.settings.autosenseLookbackInterval)
        let endDate = Date()
        logger.default("Autosense running on data from \(startDate) until \(endDate)")
        fetchSync(startDate: startDate, endDate: endDate)
        logDebug()
        guard let glucoseSamples = self.glucoseSamples, glucoseSamples.count > 0 else {
            logger.error("No glucose Samples")
            return
        }
        // Threshold outside which the algorithm is supposed to act
        let highThreshold = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 180)
        let lowThreshold = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 60)
        // Safety Bounds of autosense
        let lowestFactor = 0.2
        let highestFactor = 2.0
        // Scaling factors if high/low condition is detected
        let scaleBack = 0.8
        let lowImpact = 0.8
        let highImpact = 1.2
        // Amount of time low/high in the lookback interval to trigger
        let triggerLowRatio = 0.1
        let triggerHighRatio = 0.1

        let oldAutosenseFactor = manager.settings.autosenseFactor

        var autosenseFactor = 1.0
        var cumulativeTimeLow : TimeInterval = 0
        var cumulativeTimeHigh : TimeInterval = 0
        var averageBG = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100)
        var currentBG = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100)

        var analyzedInterval : TimeInterval = 0
        var dataPoints = 0

        var lastSample = glucoseSamples.first?.startDate

        var sumBG = 0.0
        for value in glucoseSamples {
            let interval = value.startDate.timeIntervalSince(lastSample!) // this can only be entered if at least one value exists
            // NSLog("Autosense interval \(interval)")
            if value.quantity > highThreshold {
                cumulativeTimeHigh = cumulativeTimeHigh + interval
            }
            if value.quantity < lowThreshold {
                cumulativeTimeLow = cumulativeTimeLow + interval
            }
            lastSample = value.startDate
            sumBG = sumBG + value.quantity.doubleValue(for: .milligramsPerDeciliter)
            dataPoints += 1
        }

        analyzedInterval = glucoseSamples.last!.startDate.timeIntervalSince(glucoseSamples.first!.startDate)
        averageBG = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: sumBG / Double(dataPoints))
        currentBG = glucoseSamples.last!.quantity

        guard analyzedInterval > (manager.settings.autosenseLookbackInterval / 2), dataPoints > 12 else {
            logger.error("Autosense, too little data to analyze found, data points \(dataPoints), interval \(analyzedInterval) ")
            return
        }
        let lowRatio = cumulativeTimeLow / analyzedInterval
        let highRatio = cumulativeTimeHigh / analyzedInterval
        var boostDesc = ""
        if lowRatio > triggerLowRatio {
            // autosenseFactor = manager.settings.autosenseFactor * lowImpact
            autosenseFactor = 1.0 - lowRatio
        } else if highRatio > triggerHighRatio {
            // autosenseFactor = manager.settings.autosenseFactor * highImpact
            autosenseFactor = 1.0 + highRatio * 0.5
            if currentBG > highThreshold {
                // Recency bias
                // 400 mg/dl @ 180 mg/dl Threshold -> +50% --> 220 mg/dl = 0.5
                let boost = (currentBG.doubleValue(for: .milligramsPerDeciliter) - highThreshold.doubleValue(for: .milligramsPerDeciliter)) / 220 * 0.5
                boostDesc.append("currentBG boost \(boost) ")
                autosenseFactor = autosenseFactor + boost
            }
            if averageBG > highThreshold {
                // High trailing effect.
                // 280 mg/dl @ 180 mg/dl Threshold -> +50%
                let boost = (averageBG.doubleValue(for: .milligramsPerDeciliter) - highThreshold.doubleValue(for: .milligramsPerDeciliter)) / 100 * 0.5
                boostDesc.append("avgBG boost \(boost) ")
                autosenseFactor = autosenseFactor + boost
            }

        } else {
            // slowly reduce the factor back to 1.0
            autosenseFactor = 1.0 + (oldAutosenseFactor - 1.0) * scaleBack
        }

        autosenseFactor = Swift.max(Swift.min(autosenseFactor, highestFactor), lowestFactor)
        let roundedAutosenseFactor = round(autosenseFactor * 10) / 10

        logger.error(
            "Autosense analyzedInterval \(analyzedInterval) " +
            "#\(dataPoints) " +
            "high \(cumulativeTimeHigh) / \(highRatio), low \(cumulativeTimeLow) / \(lowRatio), " +
            "average \(averageBG), current \(currentBG), " +
            "old: \(oldAutosenseFactor), new: \(autosenseFactor), rounded \(roundedAutosenseFactor), " +
            "boost: |\(boostDesc)|"
        )
        let newOverride = TemporaryScheduleOverride(
            context: .custom,
            settings: TemporaryScheduleOverrideSettings(unit: .milligramsPerDeciliter, targetRange: nil, insulinNeedsScaleFactor: roundedAutosenseFactor),
            startDate: Date(),
            duration: .finite(manager.settings.autosenseInterval * 2),
            enactTrigger: .autosense,
            syncIdentifier: UUID())
        manager.settings.lastAutosense = Date()
        manager.settings.autosenseFactor = autosenseFactor
        if let oldOverride = manager.settings.scheduleOverride, oldOverride.enactTrigger != .autosense {
            return
        }
        if roundedAutosenseFactor == 1.0 {
            if let override = manager.settings.scheduleOverride, override.enactTrigger == .autosense {
                manager.settings.scheduleOverride = nil
            }
            return
        }

        if manager.settings.autosenseEnabled {
            let suspended = manager.settings.autosenseSuspended ?? Date.distantPast
            if abs(suspended.timeIntervalSinceNow) > manager.settings.autosenseSuspendInterval {
                manager.settings.scheduleOverride = newOverride
            }
        }
    }

}
