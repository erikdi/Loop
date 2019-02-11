//
//  NightscoutUploader.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import CarbKit
import CoreData
import InsulinKit
import MinimedKit
import NightscoutUploadKit


extension NightscoutUploader: CarbStoreSyncDelegate {
    static let logger = DiagnosticLogger.shared!.forCategory("NightscoutUploader")
    
    
    public func carbStore(_ carbStore: CarbStore, hasEntriesNeedingUpload entries: [CarbEntry], completion: @escaping ([String]) -> Void) {
        let nsCarbEntries = entries.map({ MealBolusNightscoutTreatment(carbEntry: $0)})

        upload(nsCarbEntries) { (result) in
            switch result {
            case .success(let ids):
                // Pass new ids back
                completion(ids)
            case .failure(let error):
                NightscoutUploader.logger.error(error)
                completion([])
            }
        }
    }

    public func carbStore(_ carbStore: CarbStore, hasModifiedEntries entries: [CarbEntry], completion: @escaping (_ uploadedObjects: [String]) -> Void) {

        let nsCarbEntries = entries.map({ MealBolusNightscoutTreatment(carbEntry: $0)})

        modifyTreatments(nsCarbEntries) { (error) in
            if let error = error {
                NightscoutUploader.logger.error(error)
                completion([])
            } else {
                completion(entries.map { $0.externalID ?? "" } )
            }
        }
    }

    public func carbStore(_ carbStore: CarbStore, hasDeletedEntries ids: [String], completion: @escaping ([String]) -> Void) {

        deleteTreatmentsById(ids) { (error) in
            if let error = error {
                NightscoutUploader.logger.error(error)
            } else {
                completion(ids)
            }
        }
    }
}


extension NightscoutUploader {
    func upload(_ events: [PersistedPumpEvent], from pumpModel: PumpModel, completion: @escaping (NightscoutUploadKit.Either<[NSManagedObjectID], Error>) -> Void) {
        var objectIDs = [NSManagedObjectID]()
        var timestampedPumpEvents = [TimestampedHistoryEvent]()

        var fakeEvents = [NightscoutTreatment]()
        let author = "loop://\(UIDevice.current.name)"
        
        for event in events {
            objectIDs.append(event.objectID)

            if let raw = event.raw, raw.count > 0, let type = MinimedKit.PumpEventType(rawValue: raw[0])?.eventType, let pumpEvent = type.init(availableData: raw, pumpModel: pumpModel) {
                timestampedPumpEvents.append(TimestampedHistoryEvent(pumpEvent: pumpEvent, date: event.date))
                
                // Handle Events not handled in NightscoutPumpEvents
                switch pumpEvent {
                case let rewind as RewindPumpEvent:
                    _ = rewind
                    let entry = NightscoutTreatment(timestamp: event.date, enteredBy: author, notes:  "Automatically added", eventType: "Insulin Change")
                    fakeEvents.append(entry)
                case let prime as PrimePumpEvent:
                    let amount = prime.dictionaryRepresentation["amount"]
                    let entry = NightscoutTreatment(timestamp: event.date, enteredBy: author, notes:  "Automatically added; Amount \(amount ?? 0) Units", eventType: "Site Change")
                    fakeEvents.append(entry)
                case let alarm as PumpAlarmPumpEvent:
                    let note = "Pump Alarm \(alarm.alarmType)"
                    let entry = NightscoutTreatment(timestamp: event.date, enteredBy: author, notes: note, eventType: "Announcement")
                    fakeEvents.append(entry)
                default:
                    break
                }
            }
        }

        let nsEvents = NightscoutPumpEvents.translate(timestampedPumpEvents, eventSource: author, includeCarbs: false)

        self.upload(nsEvents + fakeEvents) { (result) in
            switch result {
            case .success( _):
                completion(.success(objectIDs))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}
