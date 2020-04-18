//
//  BolusRecommendation.swift
//  Loop
//
//  Created by Pete Schwamb on 1/2/17.
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import HealthKit


enum BolusRecommendationNotice {
    case glucoseBelowSuspendThreshold(minGlucose: GlucoseValue)
    case currentGlucoseBelowTarget(glucose: GlucoseValue)
    case predictedGlucoseBelowTarget(minGlucose: GlucoseValue)
    case carbOnly(carbs: Double, originalAmount: Double?)
}


extension BolusRecommendationNotice {
    public func description(using unit: HKUnit) -> String {
        switch self {
        case .glucoseBelowSuspendThreshold(minGlucose: let minGlucose):
            let glucoseFormatter = NumberFormatter.glucoseFormatter(for: unit)
            let bgStr = glucoseFormatter.string(from: minGlucose.quantity, unit: unit)!
            return String(format: NSLocalizedString("Predicted glucose of %1$@ is below your suspend threshold setting.", comment: "Notice message when recommending bolus when BG is below the suspend threshold. (1: glucose value)"), bgStr)
        case .currentGlucoseBelowTarget(glucose: let glucose):
            let glucoseFormatter = NumberFormatter.glucoseFormatter(for: unit)
            let bgStr = glucoseFormatter.string(from: glucose.quantity, unit: unit)!
            return String(format: NSLocalizedString("Current glucose of %1$@ is below correction range.", comment: "Message when offering bolus recommendation even though bg is below range. (1: glucose value)"), bgStr)
        case .predictedGlucoseBelowTarget(minGlucose: let minGlucose):
            let timeFormatter = DateFormatter()
            timeFormatter.dateStyle = .none
            timeFormatter.timeStyle = .short
            let time = timeFormatter.string(from: minGlucose.startDate)

            let glucoseFormatter = NumberFormatter.glucoseFormatter(for: unit)
            let minBGStr = glucoseFormatter.string(from: minGlucose.quantity, unit: unit)!
            return String(format: NSLocalizedString("Predicted glucose at %1$@ is %2$@.", comment: "Message when offering bolus recommendation even though bg is below range and minBG is in future. (1: glucose time)(2: glucose number)"), time, minBGStr)
        case .carbOnly(carbs: let carbs, originalAmount: let originalAmount):
            let carbsRounded = round(carbs)
            if let amount = originalAmount  {
                return String(format: NSLocalizedString("No glucose, recommendation based on \(carbsRounded) g of carbs since last bolus. Exceeds maximum Bolus, was \(amount) Units!", comment: "Notice message when recommending bolus when no glucose is available. (1: carb amount in gram. 2: original amount of Insulin.)"))
            } else {
                return String(format: NSLocalizedString("No glucose, recommendation based on \(carbsRounded) g of carbs since last bolus.", comment: "Notice message when recommending bolus when no glucose is available. (1: carb amount in gram)"))
            }
        }
    }
}

extension BolusRecommendationNotice: Equatable {
    static func ==(lhs: BolusRecommendationNotice, rhs: BolusRecommendationNotice) -> Bool {
        switch (lhs, rhs) {
        case (.glucoseBelowSuspendThreshold, .glucoseBelowSuspendThreshold):
            return true

        case (.currentGlucoseBelowTarget, .currentGlucoseBelowTarget):
            return true

        case (let .predictedGlucoseBelowTarget(minGlucose1), let .predictedGlucoseBelowTarget(minGlucose2)):
            // GlucoseValue is not equatable
            return
                minGlucose1.startDate == minGlucose2.startDate &&
                minGlucose1.endDate == minGlucose2.endDate &&
                minGlucose1.quantity == minGlucose2.quantity
        default:
            return false
        }
    }
}


struct ManualBolusRecommendation {
    let amount: Double
    let carbs: Double
    let pendingInsulin: Double
    var notice: BolusRecommendationNotice?

    init(amount: Double, pendingInsulin: Double, notice: BolusRecommendationNotice? = nil, carbs: Double = 0.0) {
        self.amount = amount
        self.carbs = carbs
        self.pendingInsulin = pendingInsulin
        self.notice = notice
    }
}


extension ManualBolusRecommendation: Comparable {
    static func ==(lhs: ManualBolusRecommendation, rhs: ManualBolusRecommendation) -> Bool {
        return lhs.amount == rhs.amount && lhs.carbs == rhs.carbs
    }

    static func <(lhs: ManualBolusRecommendation, rhs: ManualBolusRecommendation) -> Bool {
        return lhs.amount < rhs.amount || lhs.carbs < rhs.carbs
    }
}

