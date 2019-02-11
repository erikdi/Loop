//
//  DoseStore.swift
//  Loop
//
//  Created by Nate Racklyeft on 7/31/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import InsulinKit
import MinimedKit
import NightscoutUploadKit

public enum FakeEventTypes: UInt8 {
    case note = 0xfe  // Must not exist in MinimedKit.PumpEventType!
    case siteChange = 0xfd
    case insulinChange = 0xfc
    case bgReceived = 0xfb
    case debug = 0xfa
    case batteryChange = 0xf9
    case sensorStart = 0xf8
    case sensorStop = 0xf7
    case sensorChange = 0xf6
}

final class PendingTreatmentsQueueManager: IdentifiableClass {
    
    static var shared = PendingTreatmentsQueueManager()
    
    public let queue: DispatchQueue = DispatchQueue(label: "com.loopkit.loop.UserDefaults.pendingTreatmentsQueue", qos: .utility)
    public var pending : [NightscoutTreatment] = []
    
    public var generation = String(UUID().uuidString.prefix(4))
    
    private let lock = DispatchSemaphore(value: 1)
    private var value = 0
    private var failed = 0
    
    public func incrementAndGet() -> Int {
        
        lock.wait()
        defer { lock.signal() }
        value += 1
        return value
    }
    
    public func recordFailure() {
        lock.wait()
        defer { lock.signal() }
        failed += 1
    }
    
    public func failures() -> Int {
        lock.wait()
        defer { lock.signal() }
        return failed
    }
}

// Bridges support for MinimedKit data types
extension LoopDataManager {
    /**
     Adds and persists new pump events.
     */
    func addPumpEvents(_ pumpEvents: [TimestampedHistoryEvent], from model: MinimedKit.PumpModel, completion: @escaping (_ error: DoseStore.DoseStoreError?) -> Void) {
        var events: [NewPumpEvent] = []
        var lastTempBasalAmount: DoseEntry?
        // Always assume the sequence may have started rewound. LoopKit will ignore unmatched resume events.
        var isRewound = true
        var title: String

        for event in pumpEvents {
            var dose: DoseEntry?
            var eventType: InsulinKit.PumpEventType?

            switch event.pumpEvent {
            case let bolus as BolusNormalPumpEvent:
                // For entries in-progress, use the programmed amount
                let units = event.isMutable() ? bolus.programmed : bolus.amount

                dose = DoseEntry(type: .bolus, startDate: event.date, endDate: event.date.addingTimeInterval(bolus.duration), value: units, unit: .units)
            case is SuspendPumpEvent:
                dose = DoseEntry(suspendDate: event.date)
            case is ResumePumpEvent:
                dose = DoseEntry(resumeDate: event.date)
            case let temp as TempBasalPumpEvent:
                if case .Absolute = temp.rateType {
                    lastTempBasalAmount = DoseEntry(type: .tempBasal, startDate: event.date, value: temp.rate, unit: .unitsPerHour)
                }
            case let temp as TempBasalDurationPumpEvent:
                if let amount = lastTempBasalAmount, amount.startDate == event.date {
                    dose = DoseEntry(
                        type: .tempBasal,
                        startDate: event.date,
                        endDate: event.date.addingTimeInterval(TimeInterval(minutes: Double(temp.duration))),
                        value: amount.unitsPerHour,
                        unit: .unitsPerHour
                    )
                }
            case let basal as BasalProfileStartPumpEvent:
                dose = DoseEntry(
                    type: .basal,
                    startDate: event.date,
                    // Use the maximum-possible duration for a basal entry; its true duration will be reconciled against other entries.
                    endDate: event.date.addingTimeInterval(.hours(24)),
                    value: basal.scheduleEntry.rate,
                    unit: .unitsPerHour
                )
            case is RewindPumpEvent:
                eventType = .rewind

                /* 
                 No insulin is delivered between the beginning of a rewind until the suggested fixed prime is delivered or cancelled.
 
                 If the fixed prime is cancelled, it is never recorded in history. It is possible to cancel a fixed prime and perform one manually some time later, but basal delivery will have resumed during that period.
                 
                 We take the conservative approach and assume delivery is paused only between the Rewind and the first Prime event.
                 */
                dose = DoseEntry(suspendDate: event.date)
                isRewound = true
            case is PrimePumpEvent:
                eventType = .prime

                if isRewound {
                    isRewound = false
                    dose = DoseEntry(resumeDate: event.date)
                }
            case let alarm as PumpAlarmPumpEvent:
                eventType = .alarm

                if case .noDelivery = alarm.alarmType {
                    dose = DoseEntry(suspendDate: event.date)
                }
                break
            case let alarm as ClearAlarmPumpEvent:
                eventType = .alarmClear

                if case .noDelivery = alarm.alarmType {
                    dose = DoseEntry(resumeDate: event.date)
                }
                break
            default:
                break
            }

            title = String(describing: event.pumpEvent)
            events.append(NewPumpEvent(date: event.date, dose: dose, isMutable: event.isMutable(), raw: event.pumpEvent.rawData, title: title, type: eventType))
        }

        addPumpEvents(events, completion: completion)
    }
    
    // Modifications to handle more logging events from App in Nightscout
    //
    private func addFakeEvent(_ eventType: FakeEventTypes, _ note: String, _ eventDate: Date? = nil) {
        let date = eventDate ?? Date()
        
        let author = "loop://\(UIDevice.current.name)"
        let id = PendingTreatmentsQueueManager.shared.generation
        let n = PendingTreatmentsQueueManager.shared.incrementAndGet()
        let fail = PendingTreatmentsQueueManager.shared.failures()
        let uid = "#\(id):\(n) (\(fail))"
        
        var treatment : NightscoutTreatment?
            switch(eventType) {
            case .debug:
                let cal = Calendar.current
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
                let microSeconds = lrint(Double(comps.nanosecond!)/1000)
                // This hack is here to prevent de-duplication of events on insert
                // in Nightscout.  Everything else is logged much less per second, this might
                // be logged more than once.
                let formatted = String(format: "Debug.%06ld", microSeconds)
                treatment = NightscoutTreatment(timestamp: date, enteredBy: author, notes:  "\(note) \(uid)", eventType: formatted)
            case .note:
                treatment = NoteNightscoutTreatment(timestamp: date, enteredBy: author, notes: "\(note) \(uid)")
            case .insulinChange:
                treatment = NightscoutTreatment(timestamp: date, enteredBy: author, notes:  "Automatically added: \(note) \(uid)", eventType: "Insulin Change")
            case .siteChange:
                treatment = NightscoutTreatment(timestamp: date, enteredBy: author, notes:  "Automatically added: \(note) \(uid)", eventType: "Site Change")
            case .batteryChange:
                treatment = NightscoutTreatment(timestamp: date, enteredBy: author, notes:  "Automatically added: \(note) \(uid)", eventType: "Pump Battery Change")
            case .sensorStart:
                treatment = NightscoutTreatment(timestamp: date, enteredBy: author, notes:  "Automatically added: \(note) \(uid)", eventType: "Sensor Start")
            case .sensorChange:
                treatment = NightscoutTreatment(timestamp: date, enteredBy: author, notes:  "Automatically added: \(note) \(uid)", eventType: "Sensor Change")
            case .sensorStop:
                treatment = NightscoutTreatment(timestamp: date, enteredBy: author, notes:  "Automatically added: \(note) \(uid)", eventType: "Sensor Stop")
            case .bgReceived:
                let parts = note.split(separator: " ", maxSplits: 1)
                let amount = Int(parts[0]) ?? 0
                let comment = String(parts[1])
                treatment = BGCheckNightscoutTreatment(
                    timestamp: date,
                    enteredBy: author,
                    glucose: amount,
                    glucoseType: .Meter,
                    units: .MGDL,
                    notes: "\(comment) \(uid)"
                )
                
            }
        guard let finalTreatment = treatment else {
            return
        }
        PendingTreatmentsQueueManager.shared.queue.async {
            PendingTreatmentsQueueManager.shared.pending.append(finalTreatment)
            // UserDefaults.standard.pendingTreatments.append(event)
            self.uploadTreatments()
        }
    }
    
    private func uploadTreatments() {
        dispatchPrecondition(condition: .onQueue(PendingTreatmentsQueueManager.shared.queue))
        let pendingTreatments = PendingTreatmentsQueueManager.shared.pending
        PendingTreatmentsQueueManager.shared.pending = []
        // NSLog("UPLOADING", pendingTreatments.count)
        let uploadGroup = DispatchGroup()
        
        uploadGroup.enter()
        let uploadTreatments = pendingTreatments
        self.delegate.loopDataManager(self, uploadTreatments: uploadTreatments) { (result) in
            switch(result) {
            case .success:
                // for (treatment, id) in zip(uploadTreatments, ids) {
                    // NSLog("UPLOADING SUCCESS", id, treatment.dictionaryRepresentation)
                // }
                _ = 1
            case .failure(let error):
                switch(error) {
                case LoopError.configurationError:
                    NSLog("UPLOADING ERROR Nightscout not configured")
                default:
                    for treatment in uploadTreatments {
                        // NSLog("UPLOADING ERROR", error, treatment.dictionaryRepresentation)
                        PendingTreatmentsQueueManager.shared.pending.append(treatment)
                        PendingTreatmentsQueueManager.shared.recordFailure()
                    }
                }
            }
            uploadGroup.leave()
        }
        
        uploadGroup.wait()
    }
    
    public func addNote(_ text: String) {
        NSLog("addNote: \(text)")
        addFakeEvent(.note, text)
    }
    
    public func addInternalNote(_ text: String) {
        NSLog("addInternalNote: \(text)")
        addFakeEvent(.debug, "INTERNAL \(text)")
    }
    
    // Do not use directly, use logger instead
    public func addDebugNote(_ text: String) {
        NSLog("addDebugNote: \(text)")
        addFakeEvent(.debug, "DEBUG \(text)")
    }

    public func addInsulinChange(_ text: String) {
        addFakeEvent(.insulinChange, text)
    }
    
    public func addSiteChange(_ text: String) {
        addFakeEvent(.siteChange, text)
    }

    public func addBGReceived(bloodGlucose: Int, comment: String = "") {
        addFakeEvent(.bgReceived, "\(bloodGlucose) \(comment)")
    }
    
    public func addBatteryChange(_ text: String) {
        addFakeEvent(.batteryChange, text)
    }

    public func addSensorStart(_ date: Date, _ note: String) {
        addFakeEvent(.sensorStart, note, date)
    }
}
