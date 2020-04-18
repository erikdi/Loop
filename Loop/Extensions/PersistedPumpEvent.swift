//
//  PersistedPumpEvent.swift
//  Loop
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import LoopKit
import MinimedKit
import NightscoutUploadKit


extension PersistedPumpEvent {
    func treatment(enteredBy source: String) -> NightscoutTreatment? {

        if let raw = raw {
            let model = PumpModel.model523
            switch PumpEventType(rawValue: raw[0]) {
            case .bgReceived:
                if let bgReceived = BGReceivedPumpEvent(
                    availableData: raw,
                    pumpModel: model
                    ) {
                    return BGCheckNightscoutTreatment(
                        timestamp: bgReceived.timestamp.date ?? date,
                        enteredBy: source,
                        glucose: bgReceived.amount,
                        glucoseType: .Meter,
                        units: .MGDL)
                }
            case .prime:
                if let prime = PrimePumpEvent(
                    availableData: raw,
                    pumpModel: model
                    ) {
                    let programmedAmount = prime.dictionaryRepresentation["programmedAmount"] ?? 0
                    let amount = prime.dictionaryRepresentation["amount"] ?? 0
                    let primeType = prime.dictionaryRepresentation["primeType"] ?? ""
                    return NightscoutTreatment(
                        timestamp: prime.timestamp.date ?? date,
                        enteredBy: source,
                        notes:  "Automatically added; Amount \(amount) Units, Programmed Amount \(programmedAmount) Units, Type \(primeType)",
                        eventType: "Site Change")
                }
            case .rewind:
                if let rewind = RewindPumpEvent(
                    availableData: raw,
                    pumpModel: model
                    ) {
                    return NightscoutTreatment(
                        timestamp: rewind.timestamp.date ?? date,
                        enteredBy: source,
                        notes: "Automatically added",
                        eventType: "Insulin Change")
                }
            case .alarmPump:
                if let alarm = PumpAlarmPumpEvent(
                    availableData: raw,
                    pumpModel: model
                    ) {
                    let note = "Pump Alarm \(alarm.alarmType)"
                    return NightscoutTreatment(
                        timestamp: alarm.timestamp.date ?? date,
                        enteredBy: source,
                        notes: note,
                        eventType: "Announcement")
                }
            case .battery:
                if let battery = BatteryPumpEvent(availableData: raw,
                pumpModel: model
                ) {
                    return NightscoutTreatment(
                        timestamp: battery.timestamp.date ?? date,
                        enteredBy: source,
                        notes:  "Automatically added",
                        eventType: "Pump Battery Change")
                }
            default:
                NSLog("Skipping event \(raw[0]).")

            }
        }
        // Doses can be inferred from other types of events, e.g. a No Delivery Alarm type indicates a suspend in delivery.
        // At the moment, Nightscout only supports straightforward events
        guard let type = type, let dose = dose, dose.type.pumpEventType == type else {
            return nil
        }

        switch dose.type {
        case .basal:
            return nil
        case .bolus:
            let duration = dose.endDate.timeIntervalSince(dose.startDate)

            return BolusNightscoutTreatment(
                timestamp: dose.startDate,
                enteredBy: source,
                bolusType: .Normal,
                amount: dose.deliveredUnits ?? dose.programmedUnits,
                programmed: dose.programmedUnits,  // Persisted pump events are always completed
                unabsorbed: 0,  // The pump's reported IOB isn't relevant, nor stored
                duration: duration,
                carbs: 0,
                ratio: 0,
                id: dose.syncIdentifier
            )
        case .resume:
            return PumpResumeTreatment(timestamp: dose.startDate, enteredBy: source)
        case .suspend:
            return PumpSuspendTreatment(timestamp: dose.startDate, enteredBy: source)
        case .tempBasal:
            return TempBasalNightscoutTreatment(
                timestamp: dose.startDate,
                enteredBy: source,
                temp: .Absolute,  // DoseEntry only supports .absolute types
                rate: dose.unitsPerHour,
                absolute: dose.unitsPerHour,
                duration: dose.endDate.timeIntervalSince(dose.startDate),
                amount: dose.deliveredUnits,
                id: dose.syncIdentifier
            )
        }
    }
}
