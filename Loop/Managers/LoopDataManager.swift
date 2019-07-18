//
//  LoopDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/12/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import CarbKit
import GlucoseKit
import HealthKit
import InsulinKit
import LoopKit
import NightscoutUploadKit


final class LoopDataManager {
    enum LoopUpdateContext: Int {
        case bolus
        case carbs
        case glucose
        case preferences
        case tempBasal
    }

    static let LoopUpdateContextKey = "com.loudnate.Loop.LoopDataManager.LoopUpdateContext"
    static let LastLoopCompletedKey = "com.loopkit.Loop.LoopDataManager.LastLoopCompleted"

    fileprivate typealias GlucoseChange = (start: GlucoseValue, end: GlucoseValue)

    let carbStore: CarbStore!

    let doseStore: DoseStore

    let glucoseStore: GlucoseStore!

    unowned let delegate: LoopDataManagerDelegate

    private let logger: CategoryLogger
    
    var minimumBasalRateSchedule : BasalRateSchedule? {
        didSet {
            UserDefaults.appGroup.minimumBasalRateSchedule = minimumBasalRateSchedule
            notify(forChange: .preferences)
        }
    }

    init(
        delegate: LoopDataManagerDelegate,
        lastLoopCompleted: Date?,
        lastTempBasal: DoseEntry?,
        minimumBasalRateSchedule: BasalRateSchedule? = UserDefaults.appGroup.minimumBasalRateSchedule,
        basalRateSchedule: BasalRateSchedule? = UserDefaults.appGroup.basalRateSchedule,
        carbRatioSchedule: CarbRatioSchedule? = UserDefaults.appGroup.carbRatioSchedule,
        insulinModelSettings: InsulinModelSettings? = UserDefaults.appGroup.insulinModelSettings,
        insulinCounteractionEffects: [GlucoseEffectVelocity]? = UserDefaults.appGroup.insulinCounteractionEffects,
        insulinSensitivitySchedule: InsulinSensitivitySchedule? = UserDefaults.appGroup.insulinSensitivitySchedule,
        settings: LoopSettings = UserDefaults.appGroup.loopSettings ?? LoopSettings()
    ) {
        self.delegate = delegate
        self.logger = DiagnosticLogger.shared!.forCategory("LoopDataManager")
        self.insulinCounteractionEffects = insulinCounteractionEffects ?? []
        self.lastLoopCompleted = lastLoopCompleted
        self.lastTempBasal = lastTempBasal
        self.settings = settings
        self.minimumBasalRateSchedule = minimumBasalRateSchedule
        self.pumpDetachedMode = UserDefaults.appGroup.pumpDetachedMode
        
        let healthStore = HKHealthStore()

        carbStore = CarbStore(
            healthStore: healthStore,
            defaultAbsorptionTimes: (
                fast: TimeInterval(minutes: AbsorptionSpeed.fast.minutes),
                medium: TimeInterval(minutes: AbsorptionSpeed.normal.minutes),
                slow: TimeInterval(minutes: AbsorptionSpeed.slow.minutes)
            ),
            carbRatioSchedule: carbRatioSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule
        )
        // disable overrun as it creates dangerous late lows if the
        // carb absorption is finished early (e.g. less input or sports).
        carbStore.absorptionTimeOverrun = settings.absorptionTimeOverrun
        
        doseStore = DoseStore(
            healthStore: healthStore,
            insulinModel: insulinModelSettings?.model,
            basalProfile: basalRateSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule
        )

        glucoseStore = GlucoseStore(healthStore: healthStore)

        // Observe changes
        carbUpdateObserver = NotificationCenter.default.addObserver(
            forName: .CarbEntriesDidUpdate,
            object: nil,
            queue: nil
        ) { (note) -> Void in
            NSLog("carbEntriesDidUpdate")
            self.dataAccessQueue.async {
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.notify(forChange: .carbs)
            }
        }
    }

    // MARK: - Preferences

    /// Loop-related settings
    ///
    /// These are not thread-safe.
    var settings: LoopSettings {
        didSet {
            UserDefaults.appGroup.loopSettings = settings
            notify(forChange: .preferences)
            AnalyticsManager.shared.didChangeLoopSettings(from: oldValue, to: settings)
        }
    }

    /// The daily schedule of basal insulin rates
    var basalRateSchedule: BasalRateSchedule? {
        get {
            return doseStore.basalProfile
        }
        set {
            doseStore.basalProfile = newValue
            UserDefaults.appGroup.basalRateSchedule = newValue
            notify(forChange: .preferences)
        }
    }

    /// The daily schedule of carbs-to-insulin ratios
    /// This is measured in grams/Unit
    var carbRatioSchedule: CarbRatioSchedule? {
        get {
            return carbStore.carbRatioSchedule
        }
        set {
            carbStore.carbRatioSchedule = newValue
            UserDefaults.appGroup.carbRatioSchedule = newValue

            // Invalidate cached effects based on this schedule
            carbEffect = nil
            carbsOnBoard = nil

            notify(forChange: .preferences)
        }
    }

    /// The length of time insulin has an effect on blood glucose
    var insulinModelSettings: InsulinModelSettings? {
        get {
            guard let model = doseStore.insulinModel else {
                return nil
            }

            return InsulinModelSettings(model: model)
        }
        set {
            doseStore.insulinModel = newValue?.model
            UserDefaults.appGroup.insulinModelSettings = newValue

            self.dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.insulinEffect = nil

                self.notify(forChange: .preferences)
            }

            AnalyticsManager.shared.didChangeInsulinModel()
        }
    }

    /// A timeline of average velocity of glucose change counteracting predicted insulin effects
    fileprivate var insulinCounteractionEffects: [GlucoseEffectVelocity] {
        didSet {
            UserDefaults.appGroup.insulinCounteractionEffects = insulinCounteractionEffects
            carbEffect = nil
            carbsOnBoard = nil
        }
    }

    /// The daily schedule of insulin sensitivity (also known as ISF)
    /// This is measured in <blood glucose>/Unit
    var insulinSensitivitySchedule: InsulinSensitivitySchedule? {
        get {
            return carbStore.insulinSensitivitySchedule
        }
        set {
            carbStore.insulinSensitivitySchedule = newValue
            doseStore.insulinSensitivitySchedule = newValue

            UserDefaults.appGroup.insulinSensitivitySchedule = newValue

            dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.insulinEffect = nil

                self.notify(forChange: .preferences)
            }
        }
    }

    /// The amount of time since a given date that data should be considered valid
    public var recencyInterval = TimeInterval(minutes: 15)

    /// Sets a new time zone for a the schedule-based settings
    ///
    /// - Parameter timeZone: The time zone
    func setScheduleTimeZone(_ timeZone: TimeZone) {
        self.basalRateSchedule?.timeZone = timeZone
        self.minimumBasalRateSchedule?.timeZone = timeZone
        self.carbRatioSchedule?.timeZone = timeZone
        self.insulinSensitivitySchedule?.timeZone = timeZone
        settings.glucoseTargetRangeSchedule?.timeZone = timeZone
    }

    /// All the HealthKit types to be read by stores
    var readTypes: Set<HKSampleType> {
        return glucoseStore.readTypes.union(
               carbStore.readTypes).union(
               doseStore.readTypes)
    }

    /// All the HealthKit types we to be shared by stores
    var shareTypes: Set<HKSampleType> {
        return glucoseStore.shareTypes.union(
               carbStore.shareTypes).union(
               doseStore.shareTypes)
    }

    /// True if any stores require HealthKit authorization
    var authorizationRequired: Bool {
        return glucoseStore.authorizationRequired ||
               carbStore.authorizationRequired ||
               doseStore.authorizationRequired
    }

    /// True if the user has explicitly denied access to any stores' HealthKit types
    var sharingDenied: Bool {
        return glucoseStore.sharingDenied ||
               carbStore.sharingDenied ||
               doseStore.sharingDenied
    }

    func authorize(_ completion: @escaping () -> Void) {
        carbStore.healthStore.requestAuthorization(toShare: shareTypes, read: readTypes) { (success, error) in
            completion()
        }
    }

    // MARK: - Intake

    /// Adds and stores glucose data
    ///
    /// - Parameters:
    ///   - values: The new glucose values to store
    ///   - device: The device that captured the data
    ///   - completion: A closure called once upon completion
    ///   - result: The stored glucose values
    func addGlucose(
        _ values: [(quantity: HKQuantity, date: Date, isDisplayOnly: Bool)],
        from device: HKDevice?,
        completion: ((_ result: Result<[GlucoseValue]>) -> Void)? = nil
    ) {
        glucoseStore.addGlucoseValues(values, device: device) { (success, values, error) in
            if success {
                self.dataAccessQueue.async {
                    self.glucoseMomentumEffect = nil
                    self.lastGlucoseChange = nil
                    self.retrospectiveGlucoseChange = nil
                    self.notify(forChange: .glucose)
                }
            }

            if let error = error {
                completion?(.failure(error))
            } else {
                completion?(.success(values ?? []))
            }
        }
    }

    /// Adds and stores carb data, and recommends a bolus if needed
    ///
    /// - Parameters:
    ///   - carbEntry: The new carb value
    ///   - completion: A closure called once upon completion
    ///   - result: The bolus recommendation
    func addCarbEntryAndRecommendBolus(_ carbEntry: CarbEntry, replacing replacingEntry: CarbEntry? = nil, completion: @escaping (_ result: Result<BolusRecommendation?>) -> Void) {
        NSLog("addCarbEntryAndRecommendBolus: \(carbEntry) \(String(describing: replacingEntry))")

        let addCompletion: (Bool, CarbEntry?, CarbStore.CarbStoreError?) -> Void = { (success, entry, error) in
            self.dataAccessQueue.async {
                if success {
                    // Remove the active pre-meal target override
                    self.settings.glucoseTargetRangeSchedule?.clearOverride(matching: .preMeal)

                    self.carbEffect = nil
                    self.carbsOnBoard = nil
                    defer {
                        NSLog("addCarbEntryAndRecommendBolus notify carbs: \(String(describing: entry))")
                        self.notify(forChange: .carbs)
                    }

                    do {
                        try self.update("addCarbEntryAndRecommendBolus")
                        if let bolus = self.recommendedBolus {
                            NSLog("addCarbEntryAndRecommendBolus bolus recommendation: \(bolus))")
                            completion(.success(bolus.recommendation))
                        } else {
                            // TODO(Erik) Surface the real error here
                            throw LoopError.missingDataError(details: "Cannot recommend Bolus", recovery: "Check your data")
                        }
                    } catch let error {
                        NSLog("addCarbEntryAndRecommendBolus bolus recommendation error: \(error))")
                        completion(.failure(error))
                    }
                } else if let error = error {
                    self.logger.error("addCarbEntryAndRecommendBolus error: \(error)): \(String(describing: entry))")

                    completion(.failure(error))
                } else {
                    self.logger.error("addCarbEntryAndRecommendBolus no success and no error: \(String(describing: entry))")

                    completion(.success(nil))
                }
            }
        }

        lastCarbChange = Date()

        if let replacingEntry = replacingEntry {
            carbStore.replaceCarbEntry(replacingEntry, withEntry: carbEntry, resultHandler: addCompletion)
        } else {
            carbStore.addCarbEntry(carbEntry, resultHandler: addCompletion)
        }
    }

    /// Adds a bolus requested of the pump, but not confirmed.
    ///
    /// - Parameters:
    ///   - units: The bolus amount, in units
    ///   - date: The date the bolus was requested
    func addRequestedBolus(units: Double, at date: Date, completion: (() -> Void)?) {
        dataAccessQueue.async {
            NSLog("Bolus Requested: \(units) \(date)")
            self.recommendedBolus = nil
            self.lastPendingBolus = nil
            self.lastFailedBolus = nil
            self.lastRequestedBolus = (units: units, date: date, reservoir: self.doseStore.lastReservoirValue)
            self.notify(forChange: .bolus)

            completion?()
        }
    }

    /// Adds a bolus enacted by the pump, but not fully delivered.
    ///
    /// - Parameters:
    ///   - units: The bolus amount, in units
    ///   - date: The date the bolus was enacted
    func addConfirmedBolus(units: Double, at date: Date, completion: (() -> Void)?) {
        let event = NewPumpEvent.enactedBolus(units: units, at: date)
        NSLog("Bolus Confirmed: \(units) \(date)")
        self.doseStore.addPendingPumpEvent(event) {
            self.dataAccessQueue.async {
                let requestDate = self.lastRequestedBolus?.date ?? date
                self.lastPendingBolus = (units: units, date: requestDate, reservoir: self.doseStore.lastReservoirValue, event: event)
                self.logger.info("new pending Bolus \(units) U, StartDate: \(String(describing: event.dose?.startDate)), EndDate \(String(describing: event.dose?.endDate))")
                self.lastRequestedBolus = nil
                self.lastFailedBolus = nil
                self.lastAutomaticBolus = date  // keep this as a date, irrespective of automatic or not
                self.recommendedBolus = nil
                self.insulinEffect = nil
                // self.carbUndoPossible = requestDate

                self.notify(forChange: .bolus)
                do {
                    try self.update("addConfirmedBolus")
                } catch let error {
                    self.logger.error("Update after confirmed bolus failed \(error)")
                }
                completion?()
            }
        }
    }

    func addFailedBolus(units: Double, at date: Date, error: Error, completion: (() -> Void)?) {
        dataAccessQueue.async {
            NSLog("Bolus Failed: \(units) \(date) \(error)")
            self.lastFailedBolus = (units: units, date: date, error: error)
            self.lastPendingBolus = nil
            self.recommendedBolus = nil
            self.notify(forChange: .bolus)
            completion?()
        }
    }
    
    /// Adds and stores new pump events
    ///
    /// - Parameters:
    ///   - events: The pump events to add
    ///   - completion: A closure called once upon completion
    ///   - error: An error explaining why the events could not be saved.
    func addPumpEvents(_ events: [NewPumpEvent], completion: @escaping (_ error: DoseStore.DoseStoreError?) -> Void) {
        doseStore.addPumpEvents(events) { (error) in
            self.dataAccessQueue.async {
                if error == nil {
                    self.insulinEffect = nil
                    // Expire any bolus values now represented in the insulin data
                    if let bolusDate = self.lastRequestedBolus?.date, bolusDate.timeIntervalSinceNow < TimeInterval(minutes: -5) {
                        self.lastRequestedBolus = nil
                    }
                }

                completion(error)
            }
        }
    }

    /// Adds and stores a pump reservoir volume
    ///
    /// - Parameters:
    ///   - units: The reservoir volume, in units
    ///   - date: The date of the volume reading
    ///   - completion: A closure called once upon completion
    ///   - result: The current state of the reservoir values:
    ///       - newValue: The new stored value
    ///       - lastValue: The previous new stored value
    ///       - areStoredValuesContinuous: Whether the current recent state of the stored reservoir data is considered continuous and reliable for deriving insulin effects after addition of this new value.
    func addReservoirValue(_ units: Double, at date: Date, completion: @escaping (_ result: Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool)>) -> Void) {
        doseStore.addReservoirValue(units, atDate: date) { (newValue, previousValue, areStoredValuesContinuous, error) in
            if let error = error {
                completion(.failure(error))
            } else if let newValue = newValue {
                self.dataAccessQueue.async {
                    self.insulinEffect = nil
                    // Expire any bolus values now represented in the insulin data
                    if areStoredValuesContinuous, let bolusDate = self.lastRequestedBolus?.date, bolusDate.timeIntervalSinceNow < TimeInterval(minutes: -5) {
                        self.lastRequestedBolus = nil
                    }

                    completion(.success((
                        newValue: newValue,
                        lastValue: previousValue,
                        areStoredValuesContinuous: areStoredValuesContinuous
                    )))
                }
            } else {
                assertionFailure()
            }
        }
    }

    // Actions

    func enactRecommendedTempBasal(_ completion: @escaping (_ error: Error?) -> Void) {
        dataAccessQueue.async {
            self.setRecommendedTempBasal(completion)
        }
    }
    
    /// Runs the "loop"
    ///
    /// Executes an analysis of the current data, and recommends an adjustment to the current
    /// temporary basal rate.
    func loop() {
        StatisticsManager.shared.inc("loop")
        self.dataAccessQueue.async {
            NotificationCenter.default.post(name: .LoopRunning, object: self)

            self.lastLoopError = nil

            do {
                try self.update("loop")

                do {
                    try self.maybeSendFutureLowNotification()
                } catch let error {
                    self.logger.error("maybeSendFutureLowNotificationError: \(error)")
                }
                
                if self.settings.dosingEnabled {
                    self.setRecommendedTempBasal { (error) -> Void in
                        self.lastLoopError = error

                        if error == nil {
                            if self.settings.bolusEnabled {
                                // Have to do a bolus first.
                                self.setAutomatedBolus { (error) -> Void in
                                    if let error = error {
                                        self.logger.error("setAutomatedBolus \(error)")
                                    } else {
                                        self.lastLoopCompleted = Date()
                                    }
                                }
                            } else {
                                // No automatic Bolus, we are done.
                                self.lastLoopCompleted = Date()
                            }
                        }
                        self.notify(forChange: .tempBasal)
                    }
                    
                    // Delay the notification until we know the result of the temp basal
                    return
                } else {
                    self.lastLoopCompleted = Date()
                }
            } catch let error {
                self.lastLoopError = error
            }
            self.notify(forChange: .tempBasal)
        }
    }

    // References to registered notification center observers
    private var carbUpdateObserver: Any?

    deinit {
        if let observer = carbUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// - Throws:
    ///     - LoopError.configurationError
    ///     - LoopError.glucoseTooOld
    ///     - LoopError.missingDataError
    ///     - LoopError.pumpDataTooOld
    fileprivate func update(_ reason: String) throws {
        NSLog("update - \(reason)")
        StatisticsManager.shared.inc("update")
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        let updateGroup = DispatchGroup()

        // Fetch glucose effects as far back as we want to make retroactive analysis
        var latestGlucoseDate: Date?
        var momentumInterval: TimeInterval?
        updateGroup.enter()
        glucoseStore.getCachedGlucoseValues(start: Date(timeIntervalSinceNow: -recencyInterval)) { (values) in
            latestGlucoseDate = values.last?.startDate
            
            // Find the first value which is within the 15 minute momentumInterval (defined in LoopKit/GlucoseStore)
            // This is to prevent the momentum do take extreme values if e.g. a BG Meter and CGM value are at the
            // same time, but vastly different.
            if let last = latestGlucoseDate {
                var first = last
                for value in values {
                    if value.startDate.timeIntervalSinceNow >= TimeInterval(minutes: -15) {
                        first = min(first, value.startDate)
                    }
                }
                momentumInterval = last.timeIntervalSince(first)
                NSLog("momentumInterval \(first) \(last) \(String(describing: momentumInterval))")
            }
            
            updateGroup.leave()
        }
        
        _ = updateGroup.wait(timeout: .distantFuture)

        guard let lastGlucoseDate = latestGlucoseDate else {
            if let recommendation = recommendBolusCarbOnly() {
                recommendedBolus = (recommendation: recommendation, date: Date())
            } else {
                recommendedBolus = nil
            }
            _ = updateGroup.wait(timeout: .distantFuture)
            throw LoopError.missingDataError(details: "Glucose data not available", recovery: "Check your CGM data source")
        }

        let retrospectiveStart = lastGlucoseDate.addingTimeInterval(-glucoseStore.reflectionDataInterval)

        if retrospectiveGlucoseChange == nil {
            updateGroup.enter()
            glucoseStore.getGlucoseChange(start: retrospectiveStart) { (change) in
                self.retrospectiveGlucoseChange = change
                updateGroup.leave()
            }
        }

        if lastGlucoseChange == nil {
            updateGroup.enter()
            let start = insulinCounteractionEffects.last?.endDate ?? lastGlucoseDate.addingTimeInterval(.minutes(-5.1))

            glucoseStore.getGlucoseChange(start: start) { (change) in
                self.lastGlucoseChange = change
                updateGroup.leave()
            }
        }

        if glucoseMomentumEffect == nil {
            if let momentumInterval = momentumInterval, momentumInterval >= TimeInterval(minutes: 4) {
                updateGroup.enter()
                glucoseStore.getRecentMomentumEffect { (effects, error) -> Void in
                    if let error = error, effects.count == 0 {
                        self.logger.error("getRecentMomentumEffect \(error)")
                        self.glucoseMomentumEffect = nil
                    } else {
                        self.glucoseMomentumEffect = effects
                    }

                    updateGroup.leave()
                }
            } else {
                let error = LoopError.missingDataError(details: "Not enough history for momentum calculation, interval only \(String(describing: momentumInterval))", recovery: "Wait")
                NSLog("\(error)")
            }
        }

        if insulinEffect == nil {
            updateGroup.enter()
            doseStore.getGlucoseEffects(start: retrospectiveStart) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error("getGlucoseEffects \(error)")
                    self.insulinEffect = nil
                case .success(let effects):
                    self.insulinEffect = effects
                }

                updateGroup.leave()
            }
        }
        
        if insulinOnBoard == nil {
            updateGroup.enter()
            let now = Date()
            doseStore.getInsulinOnBoardValues(start: retrospectiveStart, end: now) { (result) in
                switch result {
                case .success(let value):
                    if let recentValue = value.closestPriorToDate(now) {
                        self.insulinOnBoard = recentValue
                    } else {
                        self.insulinOnBoard = InsulinValue(startDate: now, value: 0.0)
                    }
                case .failure(let error):
                    NSLog("getInsulinOnBoardValues - error: \(error)")
                    self.logger.error("getInsulinOnBoardValues \(error)")
                    self.insulinOnBoard = nil
                }
                updateGroup.leave()
            }
        }

        _ = updateGroup.wait(timeout: .distantFuture)

        if insulinCounteractionEffects.last == nil ||
            insulinCounteractionEffects.last!.endDate < lastGlucoseDate {
            do {
                try updateObservedInsulinCounteractionEffects()
            } catch let error {
                logger.error(error)
            }
        }

        if carbEffect == nil {
            updateGroup.enter()
            carbStore.getGlucoseEffects(
                start: retrospectiveStart,
                effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil
            ) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error("getGlucoseEffects \(error)")
                    self.carbEffect = nil
                case .success(let effects):
                    self.carbEffect = effects
                }

                updateGroup.leave()
            }
        }

        if carbsOnBoard == nil {
            updateGroup.enter()
            carbStore.carbsOnBoard(at: Date(), effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil) { (result) in
                switch result {
                case .failure:
                    // Failure is expected when there is no carb data
                    self.carbsOnBoard = nil
                case .success(let value):
                    self.carbsOnBoard = value
                }
                updateGroup.leave()
            }
        }

        
        _ = updateGroup.wait(timeout: .distantFuture)

        if retrospectivePredictedGlucose == nil {
            do {
                try updateRetrospectiveGlucoseEffect()
            } catch let error {
                logger.error(error)
            }
        }

        if predictedGlucose == nil {
            do {
                try updatePredictedGlucoseAndRecommendedBasalAndBolus()
            } catch let error {
                logger.error("updatePredicted \(reason) - \(error)")

                throw error
            }
        }
    }

    private func notify(forChange context: LoopUpdateContext) {
        var userInfo: [String: Any] = [
            type(of: self).LoopUpdateContextKey: context.rawValue
        ]

        if let lastLoopCompleted = lastLoopCompleted {
            userInfo[type(of: self).LastLoopCompletedKey] = lastLoopCompleted
        }

        NotificationCenter.default.post(name: .LoopDataUpdated,
            object: self,
            userInfo: userInfo
        )
    }

    /// Computes amount of insulin from boluses that have been issued and not confirmed, and
    /// remaining insulin delivery from temporary basal rate adjustments above scheduled rate
    /// that are still in progress.
    ///
    /// - Returns: The amount of pending insulin, in units
    /// - Throws: LoopError.configurationError
    private func getPendingInsulin() throws -> Double {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let basalRates = basalRateSchedule else {
            throw LoopError.configurationError("Basal Rate Schedule")
        }

        let pendingTempBasalInsulin: Double
        let date = Date()

        if let lastTempBasal = lastTempBasal, lastTempBasal.endDate > date {
            let normalBasalRate = basalRates.value(at: date)
            let remainingTime = lastTempBasal.endDate.timeIntervalSince(date)
            let remainingUnits = (lastTempBasal.unitsPerHour - normalBasalRate) * remainingTime.hours

            pendingTempBasalInsulin = max(0, remainingUnits)
        } else {
            pendingTempBasalInsulin = 0
        }

        let pendingBolusAmount: Double = lastRequestedBolus?.units ?? 0

        // All outstanding potential insulin delivery
        return pendingTempBasalInsulin + pendingBolusAmount
    }

    /// - Throws: LoopError.missingDataError
    fileprivate func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue] {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let model = insulinModelSettings?.model else {
            throw LoopError.configurationError("Check settings")
        }

        guard let glucose = self.glucoseStore.latestGlucose else {
            throw LoopError.missingDataError(details: "Cannot predict glucose due to missing input data", recovery: "Check your CGM data source")
        }

        var momentum: [GlucoseEffect] = []
        var effects: [[GlucoseEffect]] = []

        if inputs.contains(.carbs), let carbEffect = self.carbEffect {
            effects.append(carbEffect)
        }

        if inputs.contains(.insulin), let insulinEffect = self.insulinEffect {
            effects.append(insulinEffect)
        }

        if inputs.contains(.momentum), let momentumEffect = self.glucoseMomentumEffect {
            momentum = momentumEffect
        }
        
        if inputs.contains(.retrospection) {
            effects.append(self.retrospectiveGlucoseEffect)
        }
        
        // DISABLE while in trial
        //updateHighGlucoseBoost()
        //if let effect = highGlucoseEffect {
        //    effects.append(effect)
        //}

        var prediction = LoopMath.predictGlucose(glucose, momentum: momentum, effects: effects)

        // Dosing requires prediction entries at as long as the insulin model duration.
        // If our prediciton is shorter than that, then extend it here.
        let finalDate = glucose.startDate.addingTimeInterval(model.effectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }

        return prediction
    }

    // MARK: - Calculation state

    fileprivate let dataAccessQueue: DispatchQueue = DispatchQueue(label: "com.loudnate.Naterade.LoopDataManager.dataAccessQueue", qos: .utility)

    private var carbEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil

            // Carb data may be back-dated, so re-calculate the retrospective glucose.
            retrospectivePredictedGlucose = nil
        }
    }
    private var insulinEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil
            insulinOnBoard = nil
        }
    }
    
    fileprivate var insulinOnBoard: InsulinValue? {
        didSet {
            predictedGlucose = nil
        }
    }
    
    private var glucoseMomentumEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil
        }
    }
    private var retrospectiveGlucoseEffect: [GlucoseEffect] = [] {
        didSet {
            predictedGlucose = nil
        }
    }

    /// The change in glucose over the reflection time interval (default is 30 min)
    fileprivate var retrospectiveGlucoseChange: GlucoseChange? {
        didSet {
            retrospectivePredictedGlucose = nil
        }
    }
    /// The change in glucose over the last loop interval (5 min)
    fileprivate var lastGlucoseChange: GlucoseChange?

    fileprivate var predictedGlucose: [GlucoseValue]? {
        didSet {
            recommendedTempBasal = nil
            recommendedBolus = nil
        }
    }
    fileprivate var retrospectivePredictedGlucose: [GlucoseValue]? {
        didSet {
            retrospectiveGlucoseEffect = []
        }
    }
    fileprivate var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)?

    fileprivate var recommendedBolus: (recommendation: BolusRecommendation, date: Date)?
    
    fileprivate var carbsOnBoard: CarbValue?

    fileprivate var lastTempBasal: DoseEntry?
    
    fileprivate var lastRequestedBolus: (units: Double, date: Date, reservoir: ReservoirValue?)?
    fileprivate var lastPendingBolus: (units: Double, date: Date, reservoir: ReservoirValue?, event: NewPumpEvent)?
    fileprivate var lastFailedBolus: (units: Double, date: Date, error: Error)?
    
    fileprivate var lastLoopCompleted: Date? {
        didSet {
            NotificationManager.scheduleLoopNotRunningNotifications()

            AnalyticsManager.shared.loopDidSucceed()
        }
    }
    fileprivate var lastLoopError: Error? {
        didSet {
            if let error = lastLoopError {
                AnalyticsManager.shared.loopDidError(error)
            }
        }
    }

    /**
     Retrospective correction math, including proportional and integral action
     See https://github.com/LoopKit/Loop/issues/695 for discussion
     Credit dm61
     */
    struct retrospectiveCorrection {
        
        let discrepancyGain: Double
        let persistentDiscrepancyGain: Double
        let correctionTimeConstant: Double
        let integralGain: Double
        let integralForget: Double
        let proportionalGain: Double
        let carbEffectLimit: Double
        
        static var effectDuration: Double = 50
        static var previousDiscrepancy: Double = 0
        static var integralDiscrepancy: Double = 0
        
        init() {
            discrepancyGain = 1.0 // high-frequency RC gain, equivalent to Loop 1.5 gain = 1
            persistentDiscrepancyGain = 5.0 // low-frequency RC gain for persistent errors, must be >= discrepancyGain
            correctionTimeConstant = 90.0 // correction filter time constant in minutes
            // TODO Erik changed this to 15, now back to 30
            // 20180507 back to 15, 30 was too aggressive
            carbEffectLimit = 15.0 // reset integral RC if carbEffect over past 30 min is greater than carbEffectLimit expressed in mg/dL
            let sampleTime: Double = 5.0 // sample time = 5 min
            integralForget = exp( -sampleTime / correctionTimeConstant ) // must be between 0 and 1
            integralGain = ((1 - integralForget) / integralForget) *
                (persistentDiscrepancyGain - discrepancyGain)
            proportionalGain = discrepancyGain - integralGain
        }
        func updateRetrospectiveCorrection(discrepancy: Double,
                                           positiveLimit: Double,
                                           negativeLimit: Double,
                                           carbEffect: Double) -> Double {
            if (retrospectiveCorrection.previousDiscrepancy * discrepancy < 0 ||
                (discrepancy > 0 && carbEffect > carbEffectLimit)){
                // reset integral action when discrepancy reverses polarity or
                // if discrepancy is positive and carb effect is greater than carbEffectLimit
                retrospectiveCorrection.effectDuration = 60.0
                retrospectiveCorrection.previousDiscrepancy = 0.0
                retrospectiveCorrection.integralDiscrepancy = integralGain * discrepancy
            } else {
                // update integral action via low-pass filter y[n] = forget * y[n-1] + gain * u[n]
                retrospectiveCorrection.integralDiscrepancy =
                    integralForget * retrospectiveCorrection.integralDiscrepancy +
                    integralGain * discrepancy
                // impose safety limits on integral retrospective correction
                retrospectiveCorrection.integralDiscrepancy = min(max(retrospectiveCorrection.integralDiscrepancy, negativeLimit), positiveLimit)
                retrospectiveCorrection.previousDiscrepancy = discrepancy
                // extend duration of retrospective correction effect by 10 min, up to a maxium of 180 min
                retrospectiveCorrection.effectDuration =
                    min(retrospectiveCorrection.effectDuration + 10, 180)
            }
            let overallDiscrepancy = proportionalGain * discrepancy + retrospectiveCorrection.integralDiscrepancy
            return(overallDiscrepancy)
        }
        func updateEffectDuration() -> Double {
            return(retrospectiveCorrection.effectDuration)
        }
        func resetRetrospectiveCorrection() {
            retrospectiveCorrection.effectDuration = 50.0
            retrospectiveCorrection.previousDiscrepancy = 0.0
            retrospectiveCorrection.integralDiscrepancy = 0.0
            return
        }
    }
    
    /**
     Runs the glucose retrospective analysis using the latest effect data.
     Updated to include integral retrospective correction.
 
     *This method should only be called from the `dataAccessQueue`*
     */
    private func updateRetrospectiveGlucoseEffect(effectDuration: TimeInterval = TimeInterval(minutes: 60)) throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard
            let carbEffect = self.carbEffect,
            let insulinEffect = self.insulinEffect
        else {
            self.retrospectivePredictedGlucose = nil
            throw LoopError.missingDataError(details: "Cannot retrospect glucose due to missing input data", recovery: nil)
        }
        
        // integral retrospective correction variables
        var dynamicEffectDuration: TimeInterval = effectDuration
        let RC = retrospectiveCorrection()

        guard let change = retrospectiveGlucoseChange else {
            // reset integral action variables in case of calibration event
            RC.resetRetrospectiveCorrection()
            dynamicEffectDuration = effectDuration
            NSLog("myLoop --- suspected calibration event, no retrospective correction")
            self.retrospectivePredictedGlucose = nil
            return  // Expected case for calibrations
        }

        // Run a retrospective prediction over the duration of the recorded glucose change, using the current carb and insulin effects
        let startDate = change.start.startDate
        let endDate = change.end.endDate
        let retrospectivePrediction = LoopMath.predictGlucose(change.start, effects:
            carbEffect.filterDateRange(startDate, endDate),
            insulinEffect.filterDateRange(startDate, endDate)
        )

        self.retrospectivePredictedGlucose = retrospectivePrediction

        guard let lastGlucose = retrospectivePrediction.last else {
            RC.resetRetrospectiveCorrection()
            NSLog("myLoop --- glucose data missing, reset retrospective correction")
            return }
        let glucoseUnit = HKUnit.milligramsPerDeciliter()
        let velocityUnit = glucoseUnit.unitDivided(by: HKUnit.second())


        // user settings
        guard
            let glucoseTargetRange = settings.glucoseTargetRangeSchedule,
            let insulinSensitivity = insulinSensitivitySchedule,
            let basalRates = basalRateSchedule,
            let suspendThreshold = settings.suspendThreshold?.quantity,
            let currentBG = glucoseStore.latestGlucose?.quantity.doubleValue(for: glucoseUnit)
            else {
                RC.resetRetrospectiveCorrection()
                NSLog("myLoop --- could not get settings, reset retrospective correction")
                return
        }
        let date = Date()
        let currentSensitivity = insulinSensitivity.quantity(at: date).doubleValue(for: glucoseUnit)
        let currentBasalRate = basalRates.value(at: date)
        let currentMinTarget = glucoseTargetRange.minQuantity(at: date).doubleValue(for: glucoseUnit)
        let currentSuspendThreshold = suspendThreshold.doubleValue(for: glucoseUnit)
        
        // safety limit for + integral action: ISF * (2 hours) * (basal rate)
        let integralActionPositiveLimit = currentSensitivity * 2 * currentBasalRate
        // safety limit for - integral action: suspend threshold - target
        let integralActionNegativeLimit = min(-15,-abs(currentMinTarget - currentSuspendThreshold))
        
        // safety limit for current discrepancy
        let discrepancyLimit = integralActionPositiveLimit
        let currentDiscrepancyUnlimited = change.end.quantity.doubleValue(for: glucoseUnit) - lastGlucose.quantity.doubleValue(for: glucoseUnit) // mg/dL
        let currentDiscrepancy = min(max(currentDiscrepancyUnlimited, -discrepancyLimit), discrepancyLimit)
        
        // retrospective carb effect
        let retrospectiveCarbEffect = LoopMath.predictGlucose(change.start, effects:
            carbEffect.filterDateRange(startDate, endDate))
        guard let lastCarbOnlyGlucose = retrospectiveCarbEffect.last else {
            RC.resetRetrospectiveCorrection()
            NSLog("myLoop --- could not get carb effect, reset retrospective correction")
            return
        }
        let currentCarbEffect = -change.start.quantity.doubleValue(for: glucoseUnit) + lastCarbOnlyGlucose.quantity.doubleValue(for: glucoseUnit)
        
        // update overall retrospective correction
        let overallRC = RC.updateRetrospectiveCorrection(
            discrepancy: currentDiscrepancy,
            positiveLimit: integralActionPositiveLimit,
            negativeLimit: integralActionNegativeLimit,
            carbEffect: currentCarbEffect
        )
        
        let effectMinutes = RC.updateEffectDuration()
        dynamicEffectDuration = TimeInterval(minutes: effectMinutes)
        
        // retrospective correction including integral action
        let scaledDiscrepancy = overallRC * 60.0 / effectMinutes // scaled to account for extended effect duration
        
        // Velocity calculation had change.end.endDate.timeIntervalSince(change.0.endDate) in the denominator,
        // which could lead to too high RC gain when retrospection interval is shorter than 30min
        // Changed to safe fixed default retrospection interval of 30*60 = 1800 seconds
        let velocity = HKQuantity(unit: velocityUnit, doubleValue: scaledDiscrepancy / 1800.0)
        let type = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier.bloodGlucose)!
        let glucose = HKQuantitySample(type: type, quantity: change.end.quantity, start: change.end.startDate, end: change.end.endDate)
        self.retrospectiveGlucoseEffect = LoopMath.decayEffect(from: glucose, atRate: velocity, for: dynamicEffectDuration)
        
        // retrospective insulin effect (just for monitoring RC operation)
        let retrospectiveInsulinEffect = LoopMath.predictGlucose(change.start, effects:
            insulinEffect.filterDateRange(startDate, endDate))
        guard let lastInsulinOnlyGlucose = retrospectiveInsulinEffect.last else { return }
        let currentInsulinEffect = -change.start.quantity.doubleValue(for: glucoseUnit) + lastInsulinOnlyGlucose.quantity.doubleValue(for: glucoseUnit)

        // retrospective delta BG (just for monitoring RC operation)
        let currentDeltaBG = change.end.quantity.doubleValue(for: glucoseUnit) -
            change.start.quantity.doubleValue(for: glucoseUnit)// mg/dL
        
        // monitoring of retrospective correction in debugger or Console ("message: myLoop")
        NSLog("myLoop ******************************************")
        NSLog("myLoop ---retrospective correction ([mg/dL] bg unit)---")
        NSLog("myLoop Current BG: %f", currentBG)
        NSLog("myLoop 30-min retrospective delta BG: %f", currentDeltaBG)
        NSLog("myLoop Retrospective insulin effect: %f", currentInsulinEffect)
        NSLog("myLoop Retrospectve carb effect: %f", currentCarbEffect)
        NSLog("myLoop Current discrepancy: %f", currentDiscrepancy)
        NSLog("myLoop Overall retrospective correction: %f", overallRC)
        NSLog("myLoop Correction effect duration [min]: %f", effectMinutes)
        if abs(lastIRCLog.timeIntervalSinceNow) >= TimeInterval(minutes: 30) {
            addInternalNote("IRC: \(currentDeltaBG), \(currentInsulinEffect), \(currentCarbEffect), \(currentDiscrepancy), \(overallRC), \(effectMinutes)")
            lastIRCLog = Date()
        }
    }
    private var lastIRCLog = Date.distantPast

    /// Measure the effects counteracting insulin observed in the CGM glucose.
    ///
    /// If you assume insulin is "right", this allows for some validation of carb algorithm settings.
    ///
    /// - Throws: LoopError.missingDataError if effect data isn't available
    private func updateObservedInsulinCounteractionEffects() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard
            let insulinEffect = self.insulinEffect
        else {
            throw LoopError.missingDataError(details: "Cannot calculate insulin counteraction due to missing input data", recovery: nil)
        }

        guard let change = lastGlucoseChange else {
            return  // Expected case for calibrations
        }

        // Predict glucose change using only insulin effects over the last loop interval
        let startDate = change.start.startDate
        let endDate = change.end.endDate.addingTimeInterval(TimeInterval(minutes: 5))
        let prediction = LoopMath.predictGlucose(change.start, effects:
            insulinEffect.filterDateRange(startDate, endDate)
        )

        // Ensure we're not repeating effects
        if let lastEffect = insulinCounteractionEffects.last {
            guard startDate >= lastEffect.endDate else {
                return
            }
        }

        // Compare that retrospective, insulin-driven prediction to the actual glucose change to
        // calculate the effect of all insulin counteraction
        guard let lastGlucose = prediction.last else { return }
        let glucoseUnit = HKUnit.milligramsPerDeciliter()
        let velocityUnit = glucoseUnit.unitDivided(by: HKUnit.second())
        let discrepancy = change.end.quantity.doubleValue(for: glucoseUnit) - lastGlucose.quantity.doubleValue(for: glucoseUnit) // mg/dL

        let averageVelocity = HKQuantity(unit: velocityUnit, doubleValue: discrepancy / change.end.endDate.timeIntervalSince(change.start.endDate))
        let effect = GlucoseEffectVelocity(startDate: startDate, endDate: change.end.startDate, quantity: averageVelocity)

        insulinCounteractionEffects.append(effect)
        // For now, only keep the last 24 hours of values
        insulinCounteractionEffects = insulinCounteractionEffects.filterDateRange(Date(timeIntervalSinceNow: .hours(-24)), nil)
    }

    /// Runs the glucose prediction on the latest effect data.
    ///
    /// - Throws:
    ///     - LoopError.configurationError
    ///     - LoopError.glucoseTooOld
    ///     - LoopError.missingDataError
    ///     - LoopError.pumpDataTooOld
    private func updatePredictedGlucoseAndRecommendedBasalAndBolus() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        // NSLog("updatePredictedGlucoseAndRecommendedBasal")
        guard let glucose = glucoseStore.latestGlucose else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(details: "Glucose", recovery: "Check your CGM data source")
        }

        guard let pumpStatusDate = doseStore.lastReservoirValue?.startDate else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(details: "Reservoir", recovery: "Check that your pump is in range")
        }

        let startDate = Date()

        guard startDate.timeIntervalSince(glucose.startDate) <= recencyInterval else {
            self.predictedGlucose = nil
            throw LoopError.glucoseTooOld(date: glucose.startDate)
        }

        guard startDate.timeIntervalSince(pumpStatusDate) <= recencyInterval else {
            self.predictedGlucose = nil
            throw LoopError.pumpDataTooOld(date: pumpStatusDate)
        }

        guard /*glucoseMomentumEffect != nil, */carbEffect != nil, insulinEffect != nil else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(details: "Glucose effects", recovery: nil)
        }

        let predictedGlucose = try predictGlucose(using: settings.enabledEffects)
        self.predictedGlucose = predictedGlucose

        guard let
            maxBasal = settings.maximumBasalRatePerHour,
            let maximumInsulinOnBoard = settings.maximumInsulinOnBoard,
            let glucoseTargetRange = settings.glucoseTargetRangeSchedule,
            let insulinSensitivity = insulinSensitivitySchedule,
            let minBasalRates = minimumBasalRateSchedule,
            let basalRates = basalRateSchedule,
            let maxBolus = settings.maximumBolus,
            let model = insulinModelSettings?.model
        else {
            throw LoopError.configurationError("Check settings")
        }
        
        guard let insulinOnBoard = insulinOnBoard
            else {
                throw LoopError.missingDataError(details: "Insulin on Board not available (updatePredictedGlucoseAndRecommendedBasal)", recovery: "Pump data up to date?")
        }
        
//        guard cgmCalibrated else {
//            throw LoopError.missingDataError(details: "CGM", recovery: "CGM Recently calibrated")
//        }

        let tempBasal = predictedGlucose.recommendedTempBasal(
                to: glucoseTargetRange,
                suspendThreshold: settings.suspendThreshold?.quantity,
                sensitivity: insulinSensitivity,
                model: model,
                minBasalRates: minBasalRates,
                basalRates: basalRates,
                maxBasalRate: maxBasal,
                insulinOnBoard: insulinOnBoard.value,
                maxInsulinOnBoard: maximumInsulinOnBoard,
                lastTempBasal: lastTempBasal,
                lowerOnly: settings.bolusEnabled,
                minimumProgrammableIncrementPerUnit: settings.insulinIncrementPerUnit
            )
        
        // Don't recommend changes if a bolus was just set
        if let temp = tempBasal, lastRequestedBolus == nil/*, (temp.duration == 0 || temp.duration >= TimeInterval(minutes: 5))*/  {
            recommendedTempBasal = (recommendation: temp, date: Date())
        } else {
            NSLog("updatePredictedGlucoseAndRecommendedBasal - Bolus or !tempBasal")
        }

        do {
            let pendingInsulin = try self.getPendingInsulin()

            let recommendation = predictedGlucose.recommendedBolus(
                to: glucoseTargetRange,
                suspendThreshold: settings.suspendThreshold?.quantity,
                sensitivity: insulinSensitivity,
                model: model,
                pendingInsulin: pendingInsulin,
                maxBolus: maxBolus,
                insulinOnBoard: insulinOnBoard.value,
                maxInsulinOnBoard: maximumInsulinOnBoard,
                minimumProgrammableIncrementPerUnit: settings.insulinIncrementPerUnit
            )
            recommendedBolus = (recommendation: recommendation, date: startDate)
            //recommendedBolus = (recommendation: try recommendBolus(), date: Date())
        } catch let error {
            // TODO(Erik): Surface error
            _ = error
            NSLog("updatePredictedGlucoseAndRecommendedBasal - Bolus error: \(error)")
            recommendedBolus = nil
        }

        if let remaining = pumpDetachedRemaining() {
            NSLog("updatePredictedGlucoseAndRecommendedBasal - Pump Detached!")
            recommendedTempBasal = (recommendation: TempBasalRecommendation(unitsPerHour: 0.025, duration: remaining), date: Date())
            recommendedBolus = nil
        }

        guard lastRequestedBolus == nil
            else {
            NSLog("updatePredictedGlucoseAndRecommendedBasal - Bolus ongoing")

            // Don't recommend changes if a bolus was just requested.
            // Sending additional pump commands is not going to be
            // successful in any case.
            recommendedBolus = nil
            recommendedTempBasal = nil
            return
        }

    }

    /// *This method should only be called from the `dataAccessQueue`*
    private func setRecommendedTempBasal(_ completion: @escaping (_ error: Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let recommendedTempBasal = self.recommendedTempBasal else {
            completion(nil)
            return
        }

        guard abs(recommendedTempBasal.date.timeIntervalSinceNow) < TimeInterval(minutes: 5) else {
            completion(LoopError.recommendationExpired(date: recommendedTempBasal.date))
            return
        }

        delegate.loopDataManager(self, didRecommendBasalChange: recommendedTempBasal) { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success(let basal):
                    self.lastTempBasal = basal
                    self.recommendedTempBasal = nil

                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            }
        }
    }
    
    /// *This method should only be called from the `dataAccessQueue`*
    private var lastAutomaticBolus : Date? = nil
    private var lastCarbChange : Date? = nil
    
    private func roundInsulinUnits(_ units: Double) -> Double {
        return round(units * settings.insulinIncrementPerUnit)/settings.insulinIncrementPerUnit
    }
    
    private func setAutomatedBolus(_ completion: @escaping (_ error: Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        
        
        guard let recommendedBolus = self.recommendedBolus else {
            completion(nil)
            NSLog("setAutomatedBolus - recommendation not available")
            return
        }
        
        let safeAmount = roundInsulinUnits(recommendedBolus.recommendation.amount * settings.automatedBolusRatio)
        if safeAmount < settings.automatedBolusThreshold {
            completion(nil)
            NSLog("setAutomatedBolus - recommendation below threshold")
            return
        }
        
        guard abs(recommendedBolus.date.timeIntervalSinceNow) < TimeInterval(minutes: 5) else {
            completion(LoopError.recommendationExpired(date: recommendedBolus.date))
            addInternalNote("setAutomatedBolus - recommendation too old")
            return
        }
        
        if let lastAutomaticBolus = self.lastAutomaticBolus, abs(lastAutomaticBolus.timeIntervalSinceNow) < settings.automaticBolusInterval {
            NSLog("setAutomatedBolus - last automatic bolus too close")
            StatisticsManager.shared.inc("AutomatedBolus TooClose")
            completion(nil)
            return
        }
        
        if let carbChange = lastCarbChange {
            guard abs(carbChange.timeIntervalSinceNow) > TimeInterval(minutes: 2) else {
                addInternalNote("setAutomatedBolus - last carbchange too close")
                completion(nil)
                return
            }
        }
        // TODO lastPendingBolus is never cleared, thus we need to check for the date here.
        if lastRequestedBolus != nil {
            addInternalNote("setAutomatedBolus - lastRequestedBolus still in progress \(String(describing: lastRequestedBolus))")
            completion(nil)
            return
        }
        if let lastPendingBolus = lastPendingBolus, let dose = lastPendingBolus.event.dose, dose.endDate.timeIntervalSinceNow > TimeInterval(minutes: 0) {
            addInternalNote("setAutomatedBolus - lastPendingBolus still in progress \(String(describing: lastPendingBolus))")
            completion(nil)
            return
        }
        // copy bolus with "safe" ratio
        let automatedBolus = (recommendation: BolusRecommendation(amount: safeAmount , pendingInsulin:  recommendedBolus.recommendation.pendingInsulin, notice: recommendedBolus.recommendation.notice ), date: recommendedBolus.date)
        addInternalNote("AutomatedBolus: \(automatedBolus), l")
        self.recommendedBolus = nil
        lastAutomaticBolus = Date()
        
        delegate.loopDataManager(self, didRecommendBolus: automatedBolus) { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success(let bolus):
                    // TODO(Erik) Do we need to do something with the bolus here?
                    // self.lastTempBasal = basal
                    self.addInternalNote("AutomatedBolus - success: \(bolus.units) U")
                    self.recommendedBolus = nil
                    
                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            }
        }
    }
    
    // TREATMENT STATE
    
    fileprivate func getTreatmentInformation() -> TreatmentInformation? {
        let now = Date()
        var treatment : TreatmentInformation?
        
        var allowed : Bool = false
        var message = ""
        if let reservoir = doseStore.lastReservoirValue {
            if reservoir.startDate.timeIntervalSinceNow >= TimeInterval(minutes: -15) {
                allowed = true
            } else {
                message = "Pump data too old"
            }
        } else {
            message = "Pump data not available"
        }
        // TODO(Erik): sent, failed, maybefailed are missing
        if let lastRequestedBolus = lastRequestedBolus {
            // Bolus in Progress
            treatment = TreatmentInformation(state: .sent,
                                             units: lastRequestedBolus.units,
                                             carbs: 0.0,
                                             date: now,
                                             sent: lastRequestedBolus.date,
                                             allowed: false,
                                             message: "",
                                             reservoir: nil)
            
        } else if let lastPendingBolus = lastPendingBolus, let dose = lastPendingBolus.event.dose, dose.endDate.timeIntervalSinceNow > TimeInterval(0)  {
            if let start = lastPendingBolus.reservoir, let current = doseStore.lastReservoirValue {
               let drop = roundInsulinUnits(start.unitVolume - current.unitVolume)
               let units = roundInsulinUnits(lastPendingBolus.units)
               message = "\(drop)/\(units) U"
            }
            treatment = TreatmentInformation(state: .pending,  // TODO(Erik): Pending and wait for real conf.
                units: lastPendingBolus.units,
                carbs: 0.0,
                date: lastPendingBolus.date,
                sent: nil,
                allowed: false,
                message: message,
                reservoir: nil)
            
            
        } else if let lastPendingBolus = lastPendingBolus, lastPendingBolus.date.timeIntervalSinceNow > TimeInterval(minutes: -15)  {
            treatment = TreatmentInformation(state: .success,  // TODO(Erik): Pending and wait for real conf.
                                             units: lastPendingBolus.units,
                                             carbs: 0.0,
                                             date: lastPendingBolus.date,
                                             sent: nil,
                                             allowed: allowed,
                                             message: message,
                                             reservoir: nil)
            
        } else if let lastFailedBolus = lastFailedBolus, lastFailedBolus.date.timeIntervalSinceNow > TimeInterval(minutes: -15)  {
            treatment = TreatmentInformation(state: .failed,
                                             units: lastFailedBolus.units,
                                             carbs: 0.0,
                                             date: lastFailedBolus.date,
                                             sent: nil,
                                             allowed: allowed,
                                             message: lastFailedBolus.error.localizedDescription,
                                             reservoir: nil)
            
        } else if let recommended = recommendedBolus, recommended.recommendation.amount >= settings.minimumRecommendedBolus {
            treatment = TreatmentInformation(state: .recommended,
                                             units: recommended.recommendation.amount,
                                             carbs: 0.0,
                                             date: recommended.date,
                                             sent: nil,
                                             allowed: allowed,
                                             message: message,
                                             reservoir: nil)
        } else if let low = lastLowNotification, low.date.timeIntervalSinceNow > TimeInterval(minutes: -15) {
            treatment = TreatmentInformation(state: .recommended,
                                             units: 0.0,
                                             carbs: low.carbs,
                                             date: low.date,
                                             sent: nil,
                                             allowed: allowed,
                                             message: message,
                                             reservoir: nil)
            
//        } else if let recommended = recommendedBolus, recommended.recommendation.netAmount < 0,
//            let carbRatio = carbRatioSchedule?.value(at: recommended.date) {
//            
//            let carbs = round(abs(recommended.recommendation.netAmount) * carbRatio / 5) * 5
//            treatment = TreatmentInformation(state: .recommended,
//                                             units: 0.0,
//                                             carbs: carbs,
//                                             date: recommended.date,
//                                             sent: nil,
//                                             allowed: allowed,
//                                             message: message,
//                                             reservoir: nil)
            
        } else if !allowed {
            treatment = TreatmentInformation(state: .prohibited,
                                             units: 0.0,
                                             carbs: 0.0,
                                             date: now,
                                             sent: nil,
                                             allowed: allowed,
                                             message: message,
                                             reservoir: nil)
        } else {
            treatment = TreatmentInformation(state: .none, units: 0, carbs: 0.0, date: now,
                          sent: Date(), allowed: allowed,
                          message: message,
                          reservoir: nil)
        }
        return treatment
    }
    
    // PUMP DETACH MODE
    fileprivate var pumpDetachedMode : Date? {
        didSet {
            UserDefaults.appGroup.pumpDetachedMode = pumpDetachedMode
            
            notify(forChange: .preferences)
        }
    }
    
    public func enablePumpDetachedMode() {
        dataAccessQueue.async {
            self.pumpDetachedMode = Date().addingTimeInterval(TimeInterval(minutes: 120)) // far future
            // self.deviceDataManager.nightscoutDataManager.uploadNote(note: "Enabled Pump Detached Mode")
        }
    }
    
    public func disablePumpDetachedMode() {
        dataAccessQueue.async {
            self.pumpDetachedMode = nil
            // self.deviceDataManager.nightscoutDataManager.uploadNote(note: "Disabled Pump Detached Mode")
        }
    }
    
    private func pumpDetachedRemaining() -> TimeInterval? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        if let pumpDetachedMode = pumpDetachedMode {
            let remaining = pumpDetachedMode.timeIntervalSinceNow
            if remaining > TimeInterval(0) {
                return remaining
            } else {
                self.pumpDetachedMode = nil
            }
        }
        return nil
    }
    
    // FOOD PICKS
    private var manualGlucoseEntered = false  // TODO switch to false
    
    public func removeCarbEntry(carbEntry: CarbEntry, _ completion: @escaping (_ error: Error?) -> Void) {

        self.logger.error("removeCarbEntry - original \(carbEntry)")
        carbStore.deleteCarbEntry(carbEntry) { (success, error) in
            self.dataAccessQueue.async {
                self.carbEffect = nil
                self.carbsOnBoard = nil
                defer {
                    self.notify(forChange: .carbs)
                }
            }
            DispatchQueue.main.async {
                // TODO: CarbStore doesn't automatically post this for deletes
                NotificationCenter.default.post(name: .CarbEntriesDidUpdate, object: self)
            }
            if success {
                completion(nil)
            } else if let err = error {
                NSLog("removeCarbEntry deleteCarbEntry error: \(err)")
                completion(error)
            }
        }
    }
    
    // CARB ONLY BOLUS SUGGESTION
    
    func recommendBolusCarbOnly() -> BolusRecommendation? {
        // lastBolus is a bit bad here as automatedBolus can overwrite this for unsuccessful
        // bolus' as well.
        guard let carbRatioRange = carbRatioSchedule else {
            return nil
        }
        let halfAnHourAgo = Date().addingTimeInterval(TimeInterval(minutes:-30))
        let lastBolus = lastAutomaticBolus ?? halfAnHourAgo
        let since = max(lastBolus, halfAnHourAgo)
        var carbs = 0.0
        let updateGroup = DispatchGroup()
        updateGroup.enter()
        // since last bolus, but not more than 30 minutes
        carbStore.getCachedCarbEntries(start: since) { (values) in
        
            for value in values {
                carbs = carbs + value.quantity.doubleValue(for: HKUnit.gram())
                
            }
        
            updateGroup.leave()
        }
        updateGroup.wait()
        let carbRatio = carbRatioRange.quantity(at: Date()).doubleValue(for: HKUnit.gram())
        let recommendation = round(carbs / carbRatio * 10) / 10
        do {
            let pendingInsulin = try self.getPendingInsulin()

            let safeRecommendation = Swift.min(settings.maximumBolus ?? 0, recommendation)
            if recommendation > 0 {
                self.addInternalNote("recommendBolusCarbOnly - Ratio \(carbRatio) - Carbs \(carbs) - Since \(since) - recommendation \(recommendation) U, limited to \(safeRecommendation) U.")
            }
            return BolusRecommendation(amount: safeRecommendation, pendingInsulin: pendingInsulin,
                                       notice: .carbOnly(carbs: carbs, originalAmount: (safeRecommendation < recommendation) ? recommendation : nil))
        } catch {
            return nil
        }
        
    }
    
    // VALID GLUCOSE HELPERS
    public func getValidGlucose() -> GlucoseValue? {
        if let
            glucose = self.glucoseStore?.latestGlucose {
            let startDate = Date()
            
            if startDate.timeIntervalSince(glucose.startDate) <= recencyInterval {
                return glucose
            }
        }
        return nil
    }
    
    private func getValidPredictedGlucose() -> [GlucoseValue]? {
        // If Loop is running
        if let predicted_glucose = self.predictedGlucose,
            let predictedInterval = predicted_glucose.first?.startDate.timeIntervalSinceNow,
            abs(predictedInterval) <= recencyInterval {
            if predicted_glucose.count == 0 {
                return nil
            }
            return predicted_glucose
        }
        return nil
    }
    
    /// Disable any active workout glucose targets
//    private var cgmCalibrated = true
//    func updateCgmCalibrationState(_ calibrated: Bool) {
//        cgmCalibrated = calibrated
//    }
//
    
    private var lastLowNotification : (at: Date, date: Date, value: Double, carbs: Double)?
    private let lowWarningMinutesLookAhead : Double = 30
    private func maybeSendFutureLowNotification() throws {
        // TODO sendGlucoseFutureLowNotifications if appropriate
        guard let
            glucoseTargetRange = settings.glucoseTargetRangeSchedule,
            let carbRatioRange = carbRatioSchedule,
            let insulinSensitivity = insulinSensitivitySchedule,
            let predictedGlucose = predictedGlucose,
            let lowWarningThreshold = settings.suspendThreshold?.quantity.doubleValue(for: glucoseTargetRange.unit),
            predictedGlucose.count > 0
            else {
                throw LoopError.missingDataError(details: "maybeSendFutureLowNotification Loop configuration data not set", recovery: nil)
        }
        
        
        let currentDate = Date()
        let unit = glucoseTargetRange.unit
        //let overall_min = glucose.value(
        let min = lowWarningThreshold
        // let min = glucoseTargetRange.value(at: currentDate).minValue
        var minDate : Date? = nil
        var lowDate : Date? = nil
        var minValue : Double = min
        var lastValue : Double?
        for p in predictedGlucose {
            let future = p.startDate
            let value = p.quantity.doubleValue(for: unit)
            //let target = glucoseTargetRange.value(at: future).minValue
            if future.timeIntervalSince(currentDate) > TimeInterval(minutes: lowWarningMinutesLookAhead) {
                break
            }
            
            if value < minValue {
                if lowDate == nil {
                    lowDate = future
                }
                minDate = future
                
                minValue = round(value)
            }
            
            lastValue = value
        }
        
        
        
        let currentGlucose = predictedGlucose.first!.quantity.doubleValue(for: unit)
        if currentGlucose > 250 {
            if self.lastLowNotification != nil {
                //self.addInternalNote("sendGlucoseFutureLowNotifications clear because currentGlucose > 250 \(currentGlucose)")
                NotificationManager.clearGlucoseFutureLowNotifications()
                self.lastLowNotification = nil
            }
            return
        } else if currentGlucose < min {
            // handled by DexCom.
            return
        }
        
        if let lastValue = lastValue, lastValue > min {
            // no warning if we eventually get over it.
            if self.lastLowNotification != nil {
                //self.addInternalNote("sendGlucoseFutureLowNotifications clear because lastValue > min \(lastValue) \(min)")
                NotificationManager.clearGlucoseFutureLowNotifications()
                
                self.lastLowNotification = nil
            }
            return
        }
        
        if let lowDate = lowDate, let minDate = minDate  {
            let target = glucoseTargetRange.value(at: minDate).minValue
            let insulinSensitivity = insulinSensitivity.quantity(at: minDate).doubleValue(for: glucoseTargetRange.unit)
            let carbRatio = carbRatioRange.quantity(at: minDate).doubleValue(for: HKUnit.gram())
            let maxDelta = target - minValue
            let carbs = maxDelta / insulinSensitivity * carbRatio
            
            // Always round up to next 10 carbs.
            let roundedCarbs = round((carbs + 5) / 10) * 10
            let minutes = Int(lowDate.timeIntervalSince(currentDate) / 60)
            if minutes > 0 {
                
                if let lastLow = lastLowNotification, lowDate > lastLow.date, minValue > lastLow.value {
                    // too close or going up again.
//                    addInternalNote("sendGlucoseFutureLowNotifications too close")
                } else if let lastLow = lastLowNotification, lastLow.at.timeIntervalSinceNow > TimeInterval(minutes: -5) {
                    // only sent a notification once every 5 minutes.
                } else {
                    addInternalNote("sendGlucoseFutureLowNotifications: Low in \(minutes) minutes, target: \(target), threshold: \(min), minimal glucose: \(minValue), carbs: \(roundedCarbs), last: \(String(describing: lastLowNotification))")

//                    addInternalNote( "sendGlucoseFutureLowNotifications sent")
                    NotificationManager.sendGlucoseFutureLowNotifications(currentDate: currentDate, lowDate: lowDate, target: round(min), glucose: minValue, carbs: roundedCarbs)
                    lastLowNotification = (currentDate, lowDate, minValue, roundedCarbs)
                }
            }
        } else {
            if self.lastLowNotification != nil {
                //addInternalNote("sendGlucoseFutureLowNotifications clear because no lowDate or minDate")
                NotificationManager.clearGlucoseFutureLowNotifications()
                
                self.lastLowNotification = nil
            }
        }
    }
    
    var highGlucoseEffect : [GlucoseEffect]?
    /// An an effects for lower insulin action for high glucose values.
    ///
    ///
    /// - Throws: LoopError.missingDataError if effect data isn't available
    private func updateHighGlucoseBoost() {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        
        guard let change = lastGlucoseChange else {
            highGlucoseEffect = nil
            return  // Expected case for calibrations
        }
        
        // Predict high glucose insensitivity
        // let startDate = change.end.startDate
        let duration = TimeInterval(minutes: 30)

        let glucoseUnit = HKUnit.milligramsPerDeciliter()
        let currentGlucose = change.end.quantity.doubleValue(for: glucoseUnit)

        let velocityUnit = glucoseUnit.unitDivided(by: HKUnit.second())
        let boostStart = 220.0
        let boostScale = 0.5
        let boost = (currentGlucose - boostStart) * boostScale
        
        let averageVelocity = HKQuantity(unit: velocityUnit, doubleValue: boost / duration)
        //let velocity = GlucoseEffectVelocity(startDate: startDate, endDate: startDate.addingTimeInterval(duration), quantity: averageVelocity)
        let type = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier.bloodGlucose)!
        let glucose = HKQuantitySample(type: type, quantity: change.end.quantity, start: change.end.startDate, end: change.end.endDate)
        let effect = LoopMath.decayEffect(from: glucose, atRate: averageVelocity, for: duration)
        print("updateHighGlucoseBoost", currentGlucose, boost, effect)
        highGlucoseEffect = effect
    }
    
}


/// Describes a view into the loop state
protocol LoopState {
    /// The last-calculated carbs on board
    var carbsOnBoard: CarbValue? { get }

    var insulinOnBoard: InsulinValue? { get }
    
    /// An error in the current state of the loop, or one that happened during the last attempt to loop.
    var error: Error? { get }

    /// A timeline of average velocity of glucose change counteracting predicted insulin effects
    var insulinCounteractionEffects: [GlucoseEffectVelocity] { get }

    /// The last date at which a loop completed, from prediction to dose (if dosing is enabled)
    var lastLoopCompleted: Date? { get }

    /// The last set temp basal
    var lastTempBasal: DoseEntry? { get }

    var lastRequestedBolus: (units: Double, date: Date, reservoir: ReservoirValue?)? { get }
    
    var pumpDetachedMode: Date? { get }
    
    var treatmentInformation: TreatmentInformation? { get }
    
    var validGlucose: GlucoseValue? { get }
    
    /// The calculated timeline of predicted glucose values
    var predictedGlucose: [GlucoseValue]? { get }

    /// The recommended temp basal based on predicted glucose
    var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)? { get }

    var recommendedBolus: (recommendation: BolusRecommendation, date: Date)? { get }
    
    /// The retrospective prediction over a recent period of glucose samples
    var retrospectivePredictedGlucose: [GlucoseValue]? { get }

    /// Calculates a new prediction from the current data using the specified effect inputs
    ///
    /// This method is intended for visualization purposes only, not dosing calculation. No validation of input data is done.
    ///
    /// - Parameter inputs: The effect inputs to include
    /// - Returns: An timeline of predicted glucose values
    /// - Throws: LoopError.missingDataError if prediction cannot be computed
    func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue]
}


extension LoopDataManager {
    private struct LoopStateView: LoopState {
        private let loopDataManager: LoopDataManager
        private let updateError: Error?

        init(loopDataManager: LoopDataManager, updateError: Error?) {
            self.loopDataManager = loopDataManager
            self.updateError = updateError
        }

        var carbsOnBoard: CarbValue? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.carbsOnBoard
        }
        
        var insulinOnBoard: InsulinValue? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.insulinOnBoard
        }

        var error: Error? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return updateError ?? loopDataManager.lastLoopError
        }

        var insulinCounteractionEffects: [GlucoseEffectVelocity] {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.insulinCounteractionEffects
        }

        var lastLoopCompleted: Date? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.lastLoopCompleted
        }

        var lastTempBasal: DoseEntry? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.lastTempBasal
        }
        
        var lastRequestedBolus: (units: Double, date: Date, reservoir: ReservoirValue?)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.lastRequestedBolus
        }
        
        var pumpDetachedMode: Date? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.pumpDetachedMode
        }
        
        var treatmentInformation: TreatmentInformation? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.getTreatmentInformation()
        }
        
        var validGlucose: GlucoseValue? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.getValidGlucose()
        }
        
        var predictedGlucose: [GlucoseValue]? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.predictedGlucose
        }

        var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.recommendedTempBasal
        }
        
        var recommendedBolus: (recommendation: BolusRecommendation, date: Date)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.recommendedBolus
        }

        var retrospectivePredictedGlucose: [GlucoseValue]? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.retrospectivePredictedGlucose
        }

        func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue] {
            return try loopDataManager.predictGlucose(using: inputs)
        }
    }

    /// Executes a closure with access to the current state of the loop.
    ///
    /// This operation is performed asynchronously and the closure will be executed on an arbitrary background queue.
    ///
    /// - Parameter handler: A closure called when the state is ready
    /// - Parameter manager: The loop manager
    /// - Parameter state: The current state of the manager. This is invalid to access outside of the closure.
    func getLoopState(_ handler: @escaping (_ manager: LoopDataManager, _ state: LoopState) -> Void) {
        StatisticsManager.shared.inc("getLoopState")
        dataAccessQueue.async {
            var updateError: Error?

            do {
                try self.update("getLoopState")
            } catch let error {
                updateError = error
            }

            handler(self, LoopStateView(loopDataManager: self, updateError: updateError))
        }
    }
}


extension LoopDataManager {
    /// Generates a diagnostic report about the current state
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateDiagnosticReport(_ completion: @escaping (_ report: String) -> Void) {
        getLoopState { (manager, state) in

            var entries = [
                "## LoopDataManager",
                "settings: \(String(reflecting: manager.settings))",
                "insulinCounteractionEffects: \(String(reflecting: manager.insulinCounteractionEffects))",
                "insulinOnBoard: \(String(describing: state.insulinOnBoard))",
                "predictedGlucose: \(state.predictedGlucose ?? [])",
                "retrospectivePredictedGlucose: \(state.retrospectivePredictedGlucose ?? [])",
                "recommendedTempBasal: \(String(describing: state.recommendedTempBasal))",
                "recommendedBolus: \(String(describing: state.recommendedBolus))",
                "lastdBolus: \(String(describing: state.lastRequestedBolus))",
                "pumpDetachedMode: \(String(describing: state.pumpDetachedMode))",
                "treatmentInformation: \(String(describing: state.treatmentInformation))",
                "validGlucose: \(String(describing: state.validGlucose))",
                "lastGlucoseChange: \(String(describing: manager.lastGlucoseChange))",
                "retrospectiveGlucoseChange: \(String(describing: manager.retrospectiveGlucoseChange))",
                "lastLoopCompleted: \(String(describing: state.lastLoopCompleted))",
                "lastTempBasal: \(String(describing: state.lastTempBasal))",
                "carbsOnBoard: \(String(describing: state.carbsOnBoard))",
                "error: \(String(describing: state.error))"
            ]
            

                self.glucoseStore.generateDiagnosticReport { (report) in
                    entries.append(report)
                    entries.append("")

                    self.carbStore.generateDiagnosticReport { (report) in
                        entries.append(report)
                        entries.append("")

                        self.doseStore.generateDiagnosticReport { (report) in
                            entries.append(report)
                            entries.append("")

                            completion(entries.joined(separator: "\n"))
                        }
                    }
                }
            
        }
    }
}


extension Notification.Name {
    static let LoopDataUpdated = Notification.Name(rawValue:  "com.loudnate.Naterade.notification.LoopDataUpdated")

    static let LoopRunning = Notification.Name(rawValue: "com.loudnate.Naterade.notification.LoopRunning")
}


protocol LoopDataManagerDelegate: class {

    /// Informs the delegate that an immediate basal change is recommended
    ///
    /// - Parameters:
    ///   - manager: The manager
    ///   - basal: The new recommended basal
    ///   - completion: A closure called once on completion
    ///   - result: The enacted basal
    func loopDataManager(_ manager: LoopDataManager, didRecommendBasalChange basal: (recommendation: TempBasalRecommendation, date: Date), completion: @escaping (_ result: Result<DoseEntry>) -> Void) -> Void
    
    /// Informs the delegate that an immediate bolus is recommended
    ///
    /// - Parameters:
    ///   - manager: The manager
    ///   - basal: The new recommended bolus
    ///   - completion: A closure called once on completion
    ///   - result: The enacted bolus
    func loopDataManager(_ manager: LoopDataManager, didRecommendBolus bolus: (recommendation: BolusRecommendation, date: Date), completion: @escaping (_ result: Result<DoseEntry>) -> Void) -> Void
    
    func loopDataManager(_ manager: LoopDataManager, uploadTreatments treatments: [NightscoutTreatment], completion: @escaping  (Result<[String]>) -> Void) -> Void
}
