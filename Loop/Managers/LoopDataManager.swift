//
//  LoopDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/12/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore

final class LoopDataManager {
    enum LoopUpdateContext: Int {
        case bolus
        case carbs
        case glucose
        case preferences
        case tempBasal
    }

    static let LoopUpdateContextKey = "com.loudnate.Loop.LoopDataManager.LoopUpdateContext"

    let carbStore: CarbStore

    let doseStore: DoseStore

    let glucoseStore: GlucoseStore

    var nightscoutDataManager: NightscoutDataManager?

    weak var delegate: LoopDataManagerDelegate?

    private let logger: CategoryLogger

    // References to registered notification center observers
    private var notificationObservers: [Any] = []

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    init(
        lastLoopCompleted: Date?,
        basalDeliveryState: PumpManagerStatus.BasalDeliveryState?,
        basalRateSchedule: BasalRateSchedule? = UserDefaults.appGroup?.basalRateSchedule,
        carbRatioSchedule: CarbRatioSchedule? = UserDefaults.appGroup?.carbRatioSchedule,
        insulinModelSettings: InsulinModelSettings? = UserDefaults.appGroup?.insulinModelSettings,
        insulinSensitivitySchedule: InsulinSensitivitySchedule? = UserDefaults.appGroup?.insulinSensitivitySchedule,
        settings: LoopSettings = UserDefaults.appGroup?.loopSettings ?? LoopSettings(),
        overrideHistory: TemporaryScheduleOverrideHistory = UserDefaults.appGroup?.overrideHistory ?? .init(),
        lastPumpEventsReconciliation: Date?
    ) {
        self.logger = DiagnosticLogger.shared.forCategory("LoopDataManager")
        self.lockedLastLoopCompleted = Locked(lastLoopCompleted)
        self.lockedBasalDeliveryState = Locked(basalDeliveryState)
        self.settings = settings
        self.overrideHistory = overrideHistory
        let healthStore = HKHealthStore()
        let cacheStore = PersistenceController.controllerInAppGroupDirectory()

        carbStore = CarbStore(
            healthStore: healthStore,
            cacheStore: cacheStore,
            cacheLength: .hours(24),
            defaultAbsorptionTimes: LoopSettings.defaultCarbAbsorptionTimes,
            carbRatioSchedule: carbRatioSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            overrideHistory: overrideHistory
        )

        doseStore = DoseStore(
            healthStore: healthStore,
            cacheStore: cacheStore,
            insulinModel: insulinModelSettings?.model,
            basalProfile: basalRateSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            overrideHistory: overrideHistory,
            lastPumpEventsReconciliation: lastPumpEventsReconciliation
        )

        glucoseStore = GlucoseStore(healthStore: healthStore, cacheStore: cacheStore, cacheLength: .hours(24))

        retrospectiveCorrection = settings.enabledRetrospectiveCorrectionAlgorithm

        overrideHistory.delegate = self
        cacheStore.delegate = self

        // Observe changes
        notificationObservers = [
            NotificationCenter.default.addObserver(
                forName: CarbStore.carbEntriesDidUpdate,
                object: carbStore,
                queue: nil
            ) { (note) -> Void in
                self.dataAccessQueue.async {
                    self.logger.default("Received notification of carb entries updating")

                    self.carbEffect = nil
                    self.carbsOnBoard = nil
                    self.recentCarbEntries = nil
                    self.notify(forChange: .carbs)
                }
            },
            NotificationCenter.default.addObserver(
                forName: GlucoseStore.glucoseSamplesDidChange,
                object: glucoseStore,
                queue: nil
            ) { (note) in
                self.dataAccessQueue.async {
                    self.logger.default("Received notification of glucose samples changing")

                    self.glucoseMomentumEffect = nil

                    self.notify(forChange: .glucose)
                }
            },
            NotificationCenter.default.addObserver(
                forName: nil,
                object: doseStore,
                queue: OperationQueue.main
            ) { (note) in
                self.dataAccessQueue.async {
                    self.logger.default("Received notification of dosing changing")

                    self.insulinEffect = nil

                    self.notify(forChange: .bolus)
                }
            }
        ]
    }

    /// Loop-related settings
    ///
    /// These are not thread-safe.
    var settings: LoopSettings {
        didSet {
            guard settings != oldValue else {
                return
            }
            if settings.scheduleOverride != oldValue.scheduleOverride {
                overrideHistory.recordOverride(settings.scheduleOverride)

                // Invalidate cached effects affected by the override
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.insulinEffect = nil
            }
            UserDefaults.appGroup?.loopSettings = settings
            notify(forChange: .preferences)
            AnalyticsManager.shared.didChangeLoopSettings(from: oldValue, to: settings)
        }
    }

    let overrideHistory: TemporaryScheduleOverrideHistory

    // MARK: - Calculation state

    fileprivate let dataAccessQueue: DispatchQueue = DispatchQueue(label: "com.loudnate.Naterade.LoopDataManager.dataAccessQueue", qos: .utility)

    fileprivate let loopRetryQueue: DispatchQueue = DispatchQueue(label: "com.loudnate.Naterade.LoopDataManager.loopRetryQueue", qos: .utility)

    private var carbEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil

            // Carb data may be back-dated, so re-calculate the retrospective glucose.
            retrospectiveGlucoseDiscrepancies = nil
        }
    }

    private var insulinEffect: [GlucoseEffect]? {
        didSet {
            insulinEffectIncludingPendingInsulin = nil
            predictedGlucose = nil
            insulinOnBoard = nil
        }
    }

    private var insulinEffectIncludingPendingInsulin: [GlucoseEffect]? {
        didSet {
            predictedGlucoseIncludingPendingInsulin = nil
        }
    }

    private var insulinOnBoard: InsulinValue?

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

    /// When combining retrospective glucose discrepancies, extend the window slightly as a buffer.
    private let retrospectiveCorrectionGroupingIntervalMultiplier = 1.01

    private var retrospectiveGlucoseDiscrepancies: [GlucoseEffect]? {
        didSet {
            retrospectiveGlucoseDiscrepanciesSummed = retrospectiveGlucoseDiscrepancies?.combinedSums(of: settings.retrospectiveCorrectionGroupingInterval * retrospectiveCorrectionGroupingIntervalMultiplier)
        }
    }

    private var retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?


    fileprivate var predictedGlucose: [PredictedGlucoseValue]? {
        didSet {
            recommendedDose = nil
            recommendedManualBolus = nil
            predictedGlucoseIncludingPendingInsulin = nil
        }
    }

    fileprivate var predictedGlucoseIncludingPendingInsulin: [PredictedGlucoseValue]?

    private var recentCarbEntries: [StoredCarbEntry]?

    fileprivate var recommendedDose: (recommendation: AutomaticDoseRecommendation, date: Date)?

    fileprivate var recommendedManualBolus: (recommendation: ManualBolusRecommendation, date: Date)?

    fileprivate var carbsOnBoard: CarbValue?

    var basalDeliveryState: PumpManagerStatus.BasalDeliveryState? {
        get {
            return lockedBasalDeliveryState.value
        }
        set {
            self.logger.debug("Updating basalDeliveryState to \(String(describing: newValue))")
            lockedBasalDeliveryState.value = newValue
        }
    }
    private let lockedBasalDeliveryState: Locked<PumpManagerStatus.BasalDeliveryState?>

    fileprivate var lastRequestedBolus: DoseEntry?
    
    private var lastLoopStarted: Date?

    /// The last date at which a loop completed, from prediction to dose (if dosing is enabled)
    var lastLoopCompleted: Date? {
        get {
            return lockedLastLoopCompleted.value
        }
        set {
            lockedLastLoopCompleted.value = newValue
        }
    }
    private let lockedLastLoopCompleted: Locked<Date?>

    fileprivate var lastLoopError: Error?
    fileprivate var loopInProgress : (date: Date, uuid: String, retry: Int, trigger: String)?

    fileprivate var lastAutomaticBolus : Date? = nil
    fileprivate var lastCarbChange : Date? = nil

    fileprivate var lastLowNotification : (date: Date, carbs: Double, sent: Bool)?

    /// A timeline of average velocity of glucose change counteracting predicted insulin effects
    fileprivate var insulinCounteractionEffects: [GlucoseEffectVelocity] = [] {
        didSet {
            carbEffect = nil
            carbsOnBoard = nil
        }
    }

    // Confined to dataAccessQueue
    private var retrospectiveCorrection: RetrospectiveCorrection

    // MARK: - Background task management

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func startBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PersistenceController save") {
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    private func loopDidComplete(date: Date, duration: TimeInterval, trigger: String, retries: Int, uuid: String) {
        lastLoopCompleted = date
        NotificationManager.clearLoopNotRunningNotifications()
        NotificationManager.scheduleLoopNotRunningNotifications()
        AnalyticsManager.shared.loopDidSucceed(duration, trigger: trigger, retries: retries, uuid: uuid)
        NotificationCenter.default.post(name: .LoopCompleted, object: self)

    }
}

// MARK: Background task management
extension LoopDataManager: PersistenceControllerDelegate {
    func persistenceControllerWillSave(_ controller: PersistenceController) {
        startBackgroundTask()
    }

    func persistenceControllerDidSave(_ controller: PersistenceController, error: PersistenceController.PersistenceControllerError?) {
        endBackgroundTask()
    }
}


// MARK: Override history tracking
extension LoopDataManager: TemporaryScheduleOverrideHistoryDelegate {
    func temporaryScheduleOverrideHistoryDidUpdate(_ history: TemporaryScheduleOverrideHistory) {
        UserDefaults.appGroup?.overrideHistory = history
    }
}

// MARK: - Preferences
extension LoopDataManager {

    /// The daily schedule of basal insulin rates
    var basalRateSchedule: BasalRateSchedule? {
        get {
            return doseStore.basalProfile
        }
        set {
            doseStore.basalProfile = newValue
            UserDefaults.appGroup?.basalRateSchedule = newValue
            notify(forChange: .preferences)

            if let newValue = newValue, let oldValue = doseStore.basalProfile, newValue.items != oldValue.items {
                AnalyticsManager.shared.didChangeBasalRateSchedule()
            }
        }
    }

    /// The basal rate schedule, applying recent overrides relative to the current moment in time.
    var basalRateScheduleApplyingOverrideHistory: BasalRateSchedule? {
        return doseStore.basalProfileApplyingOverrideHistory
    }

    /// The daily schedule of carbs-to-insulin ratios
    /// This is measured in grams/Unit
    var carbRatioSchedule: CarbRatioSchedule? {
        get {
            return carbStore.carbRatioSchedule
        }
        set {
            carbStore.carbRatioSchedule = newValue
            UserDefaults.appGroup?.carbRatioSchedule = newValue

            // Invalidate cached effects based on this schedule
            carbEffect = nil
            carbsOnBoard = nil

            notify(forChange: .preferences)
        }
    }

    /// The carb ratio schedule, applying recent overrides relative to the current moment in time.
    var carbRatioScheduleApplyingOverrideHistory: CarbRatioSchedule? {
        return carbStore.carbRatioScheduleApplyingOverrideHistory
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
            UserDefaults.appGroup?.insulinModelSettings = newValue

            self.dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.insulinEffect = nil

                self.notify(forChange: .preferences)
            }

            AnalyticsManager.shared.didChangeInsulinModel()
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

            UserDefaults.appGroup?.insulinSensitivitySchedule = newValue

            dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.insulinEffect = nil

                self.notify(forChange: .preferences)
            }
        }
    }

    /// The insulin sensitivity schedule, applying recent overrides relative to the current moment in time.
    var insulinSensitivityScheduleApplyingOverrideHistory: InsulinSensitivitySchedule? {
        return carbStore.insulinSensitivityScheduleApplyingOverrideHistory
    }

    /// Sets a new time zone for a the schedule-based settings
    ///
    /// - Parameter timeZone: The time zone
    func setScheduleTimeZone(_ timeZone: TimeZone) {
        if timeZone != basalRateSchedule?.timeZone {
            AnalyticsManager.shared.punpTimeZoneDidChange()
            basalRateSchedule?.timeZone = timeZone
        }

        if timeZone != carbRatioSchedule?.timeZone {
            AnalyticsManager.shared.punpTimeZoneDidChange()
            carbRatioSchedule?.timeZone = timeZone
        }

        if timeZone != insulinSensitivitySchedule?.timeZone {
            AnalyticsManager.shared.punpTimeZoneDidChange()
            insulinSensitivitySchedule?.timeZone = timeZone
        }

        if timeZone != settings.glucoseTargetRangeSchedule?.timeZone {
            settings.glucoseTargetRangeSchedule?.timeZone = timeZone
        }
    }

    /// All the HealthKit types to be read by stores
    private var readTypes: Set<HKSampleType> {
        return Set([
            glucoseStore.sampleType,
            carbStore.sampleType,
            doseStore.sampleType,
            HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier.sleepAnalysis)!
        ].compactMap { $0 })
    }
    
    /// All the HealthKit types to be shared by stores
    private var shareTypes: Set<HKSampleType> {
        return Set([
            glucoseStore.sampleType,
            carbStore.sampleType,
            doseStore.sampleType,
        ].compactMap { $0 })
    }

    var sleepDataAuthorizationRequired: Bool {
        return carbStore.healthStore.authorizationStatus(for: HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier.sleepAnalysis)!) == .notDetermined
    }
    
    var sleepDataSharingDenied: Bool {
        return carbStore.healthStore.authorizationStatus(for: HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier.sleepAnalysis)!) == .sharingDenied
    }

    /// True if any stores require HealthKit authorization
    var authorizationRequired: Bool {
        return glucoseStore.authorizationRequired ||
               carbStore.authorizationRequired ||
               doseStore.authorizationRequired ||
               sleepDataAuthorizationRequired
    }

    /// True if the user has explicitly denied access to any stores' HealthKit types
    private var sharingDenied: Bool {
        return glucoseStore.sharingDenied ||
               carbStore.sharingDenied ||
               doseStore.sharingDenied ||
               sleepDataSharingDenied
    }

    func authorize(_ completion: @escaping () -> Void) {
        // Authorize all types at once for simplicity
        carbStore.healthStore.requestAuthorization(toShare: shareTypes, read: readTypes) { (success, error) in
            if success {
                // Call the individual authorization methods to trigger query creation
                self.carbStore.authorize({ _ in })
                self.doseStore.insulinDeliveryStore.authorize({ _ in })
                self.glucoseStore.authorize({ _ in })
            }

            completion()
        }
    }
}


// MARK: - Intake
extension LoopDataManager {
    /// Adds and stores glucose data
    ///
    /// - Parameters:
    ///   - samples: The new glucose samples to store
    ///   - completion: A closure called once upon completion
    ///   - result: The stored glucose values
    func addGlucose(
        _ samples: [NewGlucoseSample],
        completion: ((_ result: Result<[GlucoseValue]>) -> Void)? = nil
    ) {
        glucoseStore.addGlucose(samples) { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success(let samples):
                    if let endDate = samples.sorted(by: { $0.startDate < $1.startDate }).first?.startDate {
                        // Prune back any counteraction effects for recomputation
                        self.insulinCounteractionEffects = self.insulinCounteractionEffects.filter { $0.endDate < endDate }
                    }

                    completion?(.success(samples))
                case .failure(let error):
                    completion?(.failure(error))
                }
            }
        }
    }


    /// Adds and stores carb data, and recommends a bolus if needed
    ///
    /// - Parameters:
    ///   - carbEntry: The new carb value
    ///   - completion: A closure called once upon completion
    ///   - result: The bolus recommendation
    func addCarbEntryAndRecommendBolus(_ carbEntry: NewCarbEntry, replacing replacingEntry: StoredCarbEntry? = nil, completion: @escaping (_ result: Result<ManualBolusRecommendation?>) -> Void) {
        let addCompletion: (CarbStoreResult<StoredCarbEntry>) -> Void = { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success:
                    // Remove the active pre-meal target override
                    self.settings.clearOverride(matching: .preMeal)

                    self.carbEffect = nil
                    self.carbsOnBoard = nil

                    do {
                        try self.update()

                        completion(.success(self.recommendedManualBolus?.recommendation))
                    } catch let error {
                        if let manualBolus = self.recommendedManualBolus {
                            completion(.success(manualBolus.recommendation))
                        } else {
                            completion(.failure(error))
                        }
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
        lastCarbChange = Date()

        if let replacingEntry = replacingEntry {
            carbStore.replaceCarbEntry(replacingEntry, withEntry: carbEntry, completion: addCompletion)
        } else {
            carbStore.addCarbEntry(carbEntry, completion: addCompletion)
        }
    }

    public func removeCarbEntry(carbEntry: StoredCarbEntry, _ completion: @escaping (_ error: Error?) -> Void) {
        self.logger.default("removeCarbEntry - original \(carbEntry)")
        lastCarbChange = Date()
        carbStore.deleteCarbEntry(carbEntry) { result in
            self.dataAccessQueue.async {
                self.carbEffect = nil
                self.carbsOnBoard = nil

                switch result {
                case .success:
                    completion(nil)
                case .failure(let error):
                    self.logger.error("removeCarbEntry deleteCarbEntry error: \(error)")
                    completion(error)
                }
            }
        }
    }

    /// Adds a bolus requested of the pump, but not confirmed.
    ///
    /// - Parameters:
    ///   - dose: The DoseEntry representing the requested bolus
    func addRequestedBolus(_ dose: DoseEntry, completion: (() -> Void)?) {
        dataAccessQueue.async {
            self.logger.debug("addRequestedBolus")
            self.lastRequestedBolus = dose
            self.notify(forChange: .bolus)

            completion?()
        }
    }

    /// Notifies the manager that the bolus is confirmed, but not fully delivered.
    ///
    /// - Parameters:
    ///   - dose: The DoseEntry representing the confirmed bolus.
    func bolusConfirmed(_ dose: DoseEntry, completion: (() -> Void)?) {
        self.dataAccessQueue.async {
            self.logger.debug("bolusConfirmed")
            self.lastRequestedBolus = nil
            self.recommendedManualBolus = nil
            self.recommendedDose = nil
            self.lastAutomaticBolus = Date()
            self.insulinEffect = nil
            self.notify(forChange: .bolus)

            completion?()
        }
    }

    /// Notifies the manager that the bolus failed.
    ///
    /// - Parameters:
    ///   - dose: The DoseEntry representing the confirmed bolus.
    func bolusRequestFailed(_ error: Error, completion: (() -> Void)?) {
        self.dataAccessQueue.async {
            self.logger.debug("bolusRequestFailed")
            self.lastRequestedBolus = nil
            self.insulinEffect = nil
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
    func addPumpEvents(_ events: [NewPumpEvent], lastReconciliation: Date?, completion: @escaping (_ error: DoseStore.DoseStoreError?) -> Void) {
        doseStore.addPumpEvents(events, lastReconciliation: lastReconciliation) { (error) in
            self.dataAccessQueue.async {
                if error == nil {
                    self.insulinEffect = nil
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
        doseStore.addReservoirValue(units, at: date) { (newValue, previousValue, areStoredValuesContinuous, error) in
            if let error = error {
                completion(.failure(error))
            } else if let newValue = newValue {
                self.dataAccessQueue.async {
                    self.insulinEffect = nil

                    if let newDoseStartDate = previousValue?.startDate {
                        // Prune back any counteraction effects for recomputation, after the effect delay
                        self.insulinCounteractionEffects = self.insulinCounteractionEffects.filterDateRange(nil, newDoseStartDate.addingTimeInterval(.minutes(10)))
                    }

                    completion(.success((
                        newValue: newValue,
                        lastValue: previousValue,
                        areStoredValuesContinuous: areStoredValuesContinuous
                    )))
                }
            } else if let _ = previousValue {
                self.logger.error("doseStore.addReservoirValue, duplicate dose.")
                let error = DoseStore.DoseStoreError.persistenceError(description: "addReservoirValue duplicate", recoverySuggestion: "Wait and Retry")
                completion(.failure(error))
            } else {
                self.logger.error("doseStore.addReservoirValue, unknown condition.")
                let error = DoseStore.DoseStoreError.persistenceError(description: "addReservoirValue unknown condition", recoverySuggestion: "Wait and Retry")
                completion(.failure(error))
            }
        }
    }

    // Actions

    func enactRecommendedDose(_ completion: @escaping (_ error: Error?) -> Void) {
        self.logger.default("enactRecommendedDose")
        dataAccessQueue.async {
            self.enactDose(completion)
        }
    }

    /// Runs the "loop"
    ///
    /// Executes an analysis of the current data, and recommends an adjustment to the current
    /// temporary basal rate.
    func loop(trigger: String, retries: Int = 0, uuid: String? = nil) {
        let uuidString: String = uuid ?? UUID().uuidString
        self.dataAccessQueue.async {
            if let progress = self.loopInProgress, progress.uuid != uuidString {
                // TODO make this default only
                self.logger.error("Loop already in progress - \(progress.uuid) - Trigger \(trigger) - Try \(retries)")
                return
            }
            let date = self.loopInProgress?.date ?? Date()
            self.loopInProgress = (date: date, uuid: uuidString, retry: retries, trigger: trigger)
            self.logger.default("Loop running - \(uuidString) - Trigger \(trigger) - Try \(retries)")
            NotificationCenter.default.post(name: .LoopRunning, object: self)

            self.lastLoopError = nil
            let startDate = Date()

            do {
                try self.update()

                if self.settings.dosingEnabled && self.isAutomaticDosingAllowed() {
                    self.enactDose { (error) -> Void in
                        self.lastLoopError = error
                        if let error = error {
                            AnalyticsManager.shared.loopDidError(error, trigger: trigger, retries: retries, uuid: uuidString)
                            if retries < 5 {
                                let delay = 20 * (retries + 1)
                                self.loopRetryQueue.asyncAfter(deadline: .now() + DispatchTimeInterval.seconds(delay)) {
                                    self.loop(trigger: trigger, retries: retries + 1, uuid: uuidString)
                                }
                            } else {
                                self.loopInProgress = nil
                            }
                        } else {
                            self.loopDidComplete(date: Date(), duration: -startDate.timeIntervalSinceNow, trigger: trigger, retries: retries, uuid: uuidString)
                            self.loopInProgress = nil
                        }
                        self.logger.default("Loop ended - \(uuidString)")
                        self.notify(forChange: .tempBasal)
                    }

                    // Delay the notification until we know the result of the temp basal
                    return
                } else {
                    self.loopDidComplete(date: Date(), duration: -startDate.timeIntervalSinceNow, trigger: trigger, retries: retries, uuid: uuidString)
                }
            } catch let error {
                self.lastLoopError = error
                AnalyticsManager.shared.loopDidError(error, trigger: trigger, retries: retries, uuid: uuidString)
                self.logger.default("Loop error  - \(uuidString) - \(error)")
            }

            self.loopInProgress = nil
            self.logger.default("Loop ended - \(uuidString)")
            self.notify(forChange: .tempBasal)
        }
    }

    private func isAutomaticDosingAllowed() -> Bool {
        // No recommendation is safe
        guard let recommended = self.recommendedDose else {
            return true
        }
        // Basal should always be safe
        if recommended.recommendation.bolusUnits == 0 {
            return true
        }
        // Wait for mistakes in carb entry to clear.
        if let carbChange = lastCarbChange {
            guard abs(carbChange.timeIntervalSinceNow) > settings.automaticBolusCarbDistance else {
                self.logger.default("isAutomaticDosingAllowed - last carbchange too close")
                return false
            }
        }
        // Avoid too small doses
        if recommended.recommendation.bolusUnits < settings.automatedBolusThreshold {
            self.logger.default("isAutomaticDosingAllowed - recommendation too small.")
            return false
        }
        // Avoid too close bolus'.
        if let lastAutomaticBolus = self.lastAutomaticBolus, abs(lastAutomaticBolus.timeIntervalSinceNow) < settings.automaticBolusInterval {
            self.logger.default("isAutomaticDosingAllowed - last automatic bolus too close")
            // StatisticsManager.shared.inc("AutomatedBolus TooClose")
            return false
        }
        return true
    }

    /// - Throws:
    ///     - LoopError.configurationError
    ///     - LoopError.glucoseTooOld
    ///     - LoopError.missingDataError
    ///     - LoopError.pumpDataTooOld
    fileprivate func update() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        let updateGroup = DispatchGroup()

        // Fetch glucose effects as far back as we want to make retroactive analysis
        var latestGlucoseDate: Date?
        updateGroup.enter()
        glucoseStore.getCachedGlucoseSamples(start: Date(timeIntervalSinceNow: -settings.inputDataRecencyInterval)) { (values) in
            latestGlucoseDate = values.last?.startDate
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)

        guard let lastGlucoseDate = latestGlucoseDate else {
            if let recommendation = recommendBolusCarbOnly() {
                recommendedManualBolus = (recommendation: recommendation, date: Date())
            }
            throw LoopError.missingDataError(.glucose)
        }

        let retrospectiveStart = lastGlucoseDate.addingTimeInterval(-retrospectiveCorrection.retrospectionInterval)

        let earliestEffectDate = Date(timeIntervalSinceNow: .hours(-24))
        let nextEffectDate = insulinCounteractionEffects.last?.endDate ?? earliestEffectDate

        if glucoseMomentumEffect == nil {
            updateGroup.enter()
            glucoseStore.getRecentMomentumEffect { (effects) -> Void in
                self.glucoseMomentumEffect = effects
                updateGroup.leave()
            }
        }

        if insulinEffect == nil {
            self.logger.debug("Recomputing insulin effects")
            updateGroup.enter()
            doseStore.getGlucoseEffects(start: nextEffectDate) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                    self.insulinEffect = nil
                case .success(let effects):
                    self.insulinEffect = effects
                }

                updateGroup.leave()
            }
        }

        if insulinEffectIncludingPendingInsulin == nil {
            updateGroup.enter()
            doseStore.getGlucoseEffects(start: nextEffectDate, basalDosingEnd: nil) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error("Could not fetch insulin effects: \(error)")
                    self.insulinEffectIncludingPendingInsulin = nil
                case .success(let effects):
                    self.insulinEffectIncludingPendingInsulin = effects
                }

                updateGroup.leave()
            }
        }

        if insulinOnBoard == nil {
            updateGroup.enter()
            let fetchStart = Date(timeIntervalSinceNow: .hours(-1))
            let now = Date()
            let zeroValue = InsulinValue(startDate: now, value: 0.0)
            doseStore.getInsulinOnBoardValues(start: fetchStart, end: now) { (result) in
                switch result {
                case .success(let values):
                    let value = values.closestPrior(to: now)
                    self.insulinOnBoard = value ?? zeroValue
                case .failure(let error):
                    self.logger.error("Could not fetch insulin on board: \(error)")
                    self.insulinOnBoard = nil
                }

                updateGroup.leave()
            }
        }

        _ = updateGroup.wait(timeout: .distantFuture)

        if nextEffectDate < lastGlucoseDate, let insulinEffect = insulinEffect {
            updateGroup.enter()
            self.logger.debug("Fetching counteraction effects after \(nextEffectDate)")
            glucoseStore.getCounteractionEffects(start: nextEffectDate, to: insulinEffect) { (velocities) in
                self.insulinCounteractionEffects.append(contentsOf: velocities)
                self.insulinCounteractionEffects = self.insulinCounteractionEffects.filterDateRange(earliestEffectDate, nil)

                updateGroup.leave()
            }

            _ = updateGroup.wait(timeout: .distantFuture)
        }

        if carbEffect == nil {
            updateGroup.enter()
            carbStore.getGlucoseEffects(
                start: retrospectiveStart,
                effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil
            ) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                    self.carbEffect = nil
                    self.recentCarbEntries = nil
                case .success(let (samples, effects)):
                    self.carbEffect = effects
                    self.recentCarbEntries = samples
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

        if retrospectiveGlucoseDiscrepancies == nil {
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
                logger.error(error)

                throw error
            }
        }
    }

    private func notify(forChange context: LoopUpdateContext) {
        NotificationCenter.default.post(name: .LoopDataUpdated,
            object: self,
            userInfo: [
                type(of: self).LoopUpdateContextKey: context.rawValue
            ]
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

        guard let basalRates = basalRateScheduleApplyingOverrideHistory else {
            throw LoopError.configurationError(.basalRateSchedule)
        }

        let pendingTempBasalInsulin: Double
        let date = Date()

        if let basalDeliveryState = basalDeliveryState, case .tempBasal(let lastTempBasal) = basalDeliveryState, lastTempBasal.endDate > date {
            let normalBasalRate = basalRates.value(at: date)
            let remainingTime = lastTempBasal.endDate.timeIntervalSince(date)
            let remainingUnits = (lastTempBasal.unitsPerHour - normalBasalRate) * remainingTime.hours

            pendingTempBasalInsulin = max(0, remainingUnits)
        } else {
            pendingTempBasalInsulin = 0
        }

        let pendingBolusAmount: Double = lastRequestedBolus?.programmedUnits ?? 0

        // All outstanding potential insulin delivery
        return pendingTempBasalInsulin + pendingBolusAmount
    }

    /// - Throws:
    ///     - LoopError.missingDataError
    ///     - LoopError.configurationError
    ///     - LoopError.glucoseTooOld
    ///     - LoopError.pumpDataTooOld
    fileprivate func predictGlucose(
        using inputs: PredictionInputEffect,
        potentialBolus: DoseEntry? = nil,
        potentialCarbEntry: NewCarbEntry? = nil,
        replacingCarbEntry replacedCarbEntry: StoredCarbEntry? = nil,
        includingPendingInsulin: Bool = false
    ) throws -> [PredictedGlucoseValue] {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let model = insulinModelSettings?.model else {
            throw LoopError.configurationError(.insulinModel)
        }

        guard let glucose = self.glucoseStore.latestGlucose else {
            throw LoopError.missingDataError(.glucose)
        }

        let pumpStatusDate = doseStore.lastAddedPumpData
        let lastGlucoseDate = glucose.startDate
        let now = Date()

        guard now.timeIntervalSince(lastGlucoseDate) <= settings.inputDataRecencyInterval else {
            throw LoopError.glucoseTooOld(date: glucose.startDate)
        }

        guard now.timeIntervalSince(pumpStatusDate) <= settings.inputDataRecencyInterval else {
            throw LoopError.pumpDataTooOld(date: pumpStatusDate)
        }

        var momentum: [GlucoseEffect] = []
        var retrospectiveGlucoseEffect = self.retrospectiveGlucoseEffect
        var effects: [[GlucoseEffect]] = []

        if inputs.contains(.carbs), let carbEffect = self.carbEffect {
            if let potentialCarbEntry = potentialCarbEntry, var recentEntries = recentCarbEntries {
                if let replacedCarbEntry = replacedCarbEntry, let index = recentEntries.firstIndex(of: replacedCarbEntry) {
                    recentEntries.remove(at: index)
                }

                let retrospectiveStart = lastGlucoseDate.addingTimeInterval(-retrospectiveCorrection.retrospectionInterval)

                if potentialCarbEntry.startDate > lastGlucoseDate, replacedCarbEntry == nil {
                    // The potential carb effect is independent and can be summed with the existing effect
                    effects.append(carbEffect)
                    let potentialCarbEffect = try carbStore.glucoseEffects(
                        of: [potentialCarbEntry],
                        startingAt: retrospectiveStart,
                        effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil
                    )

                    effects.append(potentialCarbEffect)
                } else {
                    // If the entry is in the past or an entry is replaced, DCA and RC effects must be recomputed
                    var entries = recentEntries.map { NewCarbEntry(quantity: $0.quantity, startDate: $0.startDate, foodType: nil, absorptionTime: $0.absorptionTime) }
                    entries.append(potentialCarbEntry)
                    entries.sort(by: { $0.startDate > $1.startDate })

                    let potentialCarbEffect = try carbStore.glucoseEffects(
                        of: entries,
                        startingAt: retrospectiveStart,
                        effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil
                    )

                    effects.append(potentialCarbEffect)

                    retrospectiveGlucoseEffect = computeRetrospectiveGlucoseEffect(startingAt: glucose, carbEffects: potentialCarbEffect)
                }
            } else {
                effects.append(carbEffect)
            }
        }

        if inputs.contains(.insulin), let insulinEffect = includingPendingInsulin ? self.insulinEffectIncludingPendingInsulin : self.insulinEffect {
            effects.append(insulinEffect)

            if let potentialBolus = potentialBolus {
                guard let sensitivity = insulinSensitivityScheduleApplyingOverrideHistory else {
                    throw LoopError.configurationError(.generalSettings)
                }

                let earliestEffectDate = Date(timeIntervalSinceNow: .hours(-24))
                let nextEffectDate = insulinCounteractionEffects.last?.endDate ?? earliestEffectDate
                let bolusEffect = [potentialBolus]
                    .glucoseEffects(insulinModel: model, insulinSensitivity: sensitivity)
                    .filterDateRange(nextEffectDate, nil)
                effects.append(bolusEffect)
            }
        }

        if inputs.contains(.momentum), let momentumEffect = self.glucoseMomentumEffect {
            momentum = momentumEffect
        }

        if inputs.contains(.retrospection) {
            effects.append(retrospectiveGlucoseEffect)
        }

        var prediction = LoopMath.predictGlucose(startingAt: glucose, momentum: momentum, effects: effects)

        // Dosing requires prediction entries at least as long as the insulin model duration.
        // If our prediction is shorter than that, then extend it here.
        let finalDate = glucose.startDate.addingTimeInterval(model.effectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }

        return prediction
    }

    /// - Throws: LoopError.missingDataError
    fileprivate func recommendBolus<Sample: GlucoseValue>(forPrediction predictedGlucose: [Sample]) throws -> ManualBolusRecommendation? {
        guard let glucose = glucoseStore.latestGlucose else {
            if let recommendation = recommendBolusCarbOnly() {
                return recommendation
            }
            throw LoopError.missingDataError(.glucose)
        }

        let pumpStatusDate = doseStore.lastAddedPumpData
        let lastGlucoseDate = glucose.startDate
        let now = Date()

        guard now.timeIntervalSince(lastGlucoseDate) <= settings.inputDataRecencyInterval else {
            if let recommendation = recommendBolusCarbOnly() {
                return recommendation
            }
            throw LoopError.glucoseTooOld(date: glucose.startDate)
        }

        guard now.timeIntervalSince(pumpStatusDate) <= settings.inputDataRecencyInterval else {
            throw LoopError.pumpDataTooOld(date: pumpStatusDate)
        }

        guard glucoseMomentumEffect != nil else {
            throw LoopError.missingDataError(.momentumEffect)
        }

        guard carbEffect != nil else {
            throw LoopError.missingDataError(.carbEffect)
        }

        guard insulinEffect != nil else {
            throw LoopError.missingDataError(.insulinEffect)
        }

        guard let iob = insulinOnBoard else {
            throw LoopError.missingDataError(.insulinOnBoard)
        }

        guard
            let glucoseTargetRange = settings.glucoseTargetRangeScheduleApplyingOverrideIfActive,
            let insulinSensitivity = insulinSensitivityScheduleApplyingOverrideHistory,
            let carbRatioSchedule = carbRatioScheduleApplyingOverrideHistory,
            let maxBolus = settings.maximumBolus,
            let maxIOB = settings.maximumInsulinOnBoard,
            let model = insulinModelSettings?.model
        else {
            throw LoopError.configurationError(.generalSettings)
        }

        guard lastRequestedBolus == nil
        else {
            // Don't recommend changes if a bolus was just requested.
            // Sending additional pump commands is not going to be
            // successful in any case.
            return nil
        }

        let volumeRounder = { (_ units: Double) in
            return self.delegate?.loopDataManager(self, roundBolusVolume: units) ?? units
        }

        let (safeMaxBolus, _) = safeMaxBasalBolus(maxBolus, 0, maxIOB, iob)

        return predictedGlucose.recommendedManualBolus(
            to: glucoseTargetRange,
            suspendThreshold: settings.suspendThreshold?.quantity,
            sensitivity: insulinSensitivity,
            carbRatio: carbRatioSchedule,
            model: model,
            pendingInsulin: 0, // Pending insulin is already reflected in the prediction
            maxBolus: safeMaxBolus,
            volumeRounder: volumeRounder
        )
    }

    fileprivate func computeCarbsOnBoard(potentialCarbEntry: NewCarbEntry?, replacing replacedCarbEntry: StoredCarbEntry?) -> CarbValue? {
        var recentEntries = recentCarbEntries ?? []
        if let replacedCarbEntry = replacedCarbEntry, let index = recentEntries.firstIndex(of: replacedCarbEntry) {
            recentEntries.remove(at: index)
        }

        var entries = recentEntries.map { NewCarbEntry(quantity: $0.quantity, startDate: $0.startDate, foodType: nil, absorptionTime: $0.absorptionTime) }
        if let potentialCarbEntry = potentialCarbEntry {
            entries.append(potentialCarbEntry)
            entries.sort(by: { $0.startDate > $1.startDate })
        }

        return try? carbStore.carbsOnBoard(
            from: entries,
            at: Date(),
            effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil
        )
    }

    /// Generates a correction effect based on how large the discrepancy is between the current glucose and its model predicted value.
    ///
    /// - Throws: LoopError.missingDataError
    private func updateRetrospectiveGlucoseEffect() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        // Get carb effects, otherwise clear effect and throw error
        guard let carbEffects = self.carbEffect else {
            retrospectiveGlucoseDiscrepancies = nil
            retrospectiveGlucoseEffect = []
            throw LoopError.missingDataError(.carbEffect)
        }

        // Get most recent glucose, otherwise clear effect and throw error
        guard let glucose = self.glucoseStore.latestGlucose else {
            retrospectiveGlucoseEffect = []
            throw LoopError.missingDataError(.glucose)
        }

        // Get timeline of glucose discrepancies
        retrospectiveGlucoseDiscrepancies = insulinCounteractionEffects.subtracting(carbEffects, withUniformInterval: carbStore.delta)

        // Calculate retrospective correction
        retrospectiveGlucoseEffect = retrospectiveCorrection.computeEffect(
            startingAt: glucose,
            retrospectiveGlucoseDiscrepanciesSummed: retrospectiveGlucoseDiscrepanciesSummed,
            recencyInterval: settings.inputDataRecencyInterval,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            basalRateSchedule: basalRateSchedule,
            glucoseCorrectionRangeSchedule: settings.glucoseTargetRangeSchedule,
            retrospectiveCorrectionGroupingInterval: settings.retrospectiveCorrectionGroupingInterval
        )
    }

    private func computeRetrospectiveGlucoseEffect(startingAt glucose: GlucoseValue, carbEffects: [GlucoseEffect]) -> [GlucoseEffect] {
        let retrospectiveGlucoseDiscrepancies = insulinCounteractionEffects.subtracting(carbEffects, withUniformInterval: carbStore.delta)
        let retrospectiveGlucoseDiscrepanciesSummed = retrospectiveGlucoseDiscrepancies.combinedSums(of: settings.retrospectiveCorrectionGroupingInterval * retrospectiveCorrectionGroupingIntervalMultiplier)
        return retrospectiveCorrection.computeEffect(
            startingAt: glucose,
            retrospectiveGlucoseDiscrepanciesSummed: retrospectiveGlucoseDiscrepanciesSummed,
            recencyInterval: settings.inputDataRecencyInterval,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            basalRateSchedule: basalRateSchedule,
            glucoseCorrectionRangeSchedule: settings.glucoseTargetRangeSchedule,
            retrospectiveCorrectionGroupingInterval: settings.retrospectiveCorrectionGroupingInterval
        )
    }

    private func safeMaxBasalBolus(_ maxBolus: Double, _ maxBasal: Double, _ maxIOB: Double, _ iob: InsulinValue) -> (Double, Double) {
        // Based on the IOB and the maximum setting, limit the maxBolus and maxBasal
        // It should take the decay of the Insulin over the next hour into account
        // for the maxBasal rate. We assume though that maxIOB will be a lot higher
        // than maxBasal, in practice this shouldn't matter.
        let maxNewInsulin = max(maxIOB - iob.value, 0)
        let safeMaxBolus = min(maxBolus, maxNewInsulin)
        let safeMaxBasal = min(maxBasal, maxNewInsulin)
        self.logger.default("IOB \(iob.value), maxIOB \(maxIOB), safeMaxBolus: \(safeMaxBolus), safeMaxBasal: \(safeMaxBasal)")
        return (safeMaxBolus, safeMaxBasal)
    }

    private func recommendBolusCarbOnly() -> ManualBolusRecommendation? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        // lastBolus is a bit bad here as automatedBolus can overwrite this for unsuccessful
        // bolus' as well.
        guard let carbRatioRange = carbRatioSchedule else {
            return nil
        }
        var multiplier = 1.0
        if let override = settings.scheduleOverride, override.isActive() {
            multiplier = override.settings.basalRateMultiplier ?? 1.0
        }

        let halfAnHourAgo = Date().addingTimeInterval(TimeInterval(minutes:-30))
        let lastBolus = lastAutomaticBolus ?? halfAnHourAgo
        let since = max(lastBolus, halfAnHourAgo)
        var carbs = 0.0
        let updateGroup = DispatchGroup()
        updateGroup.enter()
        // since last bolus, but not more than 30 minutes
        carbStore.getCarbEntries(start: since) { (result) in
            switch result {

            case .success(let values):
                for value in values {
                    carbs = carbs + value.quantity.doubleValue(for: HKUnit.gram())
                }
            case .failure(let error):
                self.logger.error("recommendBolusCarbOnly failure: \(error)")
            }

            updateGroup.leave()
        }
        updateGroup.wait()
        let carbRatio = carbRatioRange.quantity(at: Date()).doubleValue(for: HKUnit.gram())
        let recommendation = floor(multiplier * carbs / carbRatio * 10) / 10
        do {
            let pendingInsulin = try self.getPendingInsulin()

            let safeRecommendation = Swift.min(settings.maximumBolus ?? 0, recommendation)
            if recommendation > 0 {
                self.addInternalNote("recommendBolusCarbOnly - Ratio \(carbRatio)/\(multiplier) - Carbs \(carbs) - Since \(since) - recommendation \(recommendation) U, limited to \(safeRecommendation) U.")
            }
            if safeRecommendation > 0 {
                return ManualBolusRecommendation(
                    amount: safeRecommendation, pendingInsulin: pendingInsulin,
                    notice: .carbOnly(carbs: carbs, originalAmount: (safeRecommendation < recommendation) ? recommendation : nil))
            } else {
                return nil
            }
        } catch {
            return nil
        }

    }

    // VALID GLUCOSE HELPERS
    public func getValidGlucose() -> GlucoseValue? {
        let recencyInterval = TimeInterval(minutes: 15)

        if let
            glucose = self.glucoseStore.latestGlucose {
            let startDate = Date()

            if startDate.timeIntervalSince(glucose.startDate) <= recencyInterval {
                return glucose
            }
        }
        return nil
    }
    
    public func addInternalNote(_ text: String) {
        logger.info(text)
        nightscoutDataManager?.uploadNote(date: Date(), note: text)
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

        self.logger.debug("Recomputing prediction and recommendations.")

        guard let glucose = glucoseStore.latestGlucose else {
            self.predictedGlucose = nil
            if let recommendation = recommendBolusCarbOnly() {
                recommendedManualBolus = (recommendation: recommendation, date: Date())
            }
            throw LoopError.missingDataError(.glucose)
        }

        let pumpStatusDate = doseStore.lastAddedPumpData
        
        let startDate = Date()

        guard startDate.timeIntervalSince(glucose.startDate) <= settings.inputDataRecencyInterval else {
            self.predictedGlucose = nil
            throw LoopError.glucoseTooOld(date: glucose.startDate)
        }

        guard startDate.timeIntervalSince(pumpStatusDate) <= settings.inputDataRecencyInterval else {
            self.predictedGlucose = nil
            throw LoopError.pumpDataTooOld(date: pumpStatusDate)
        }

        guard glucoseMomentumEffect != nil else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.momentumEffect)
        }

        guard carbEffect != nil else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.carbEffect)
        }

        guard insulinEffect != nil, insulinEffectIncludingPendingInsulin != nil else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.insulinEffect)
        }

        guard let iob = insulinOnBoard else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.insulinOnBoard)
        }

        let predictedGlucose = try predictGlucose(using: settings.enabledEffects)
        self.predictedGlucose = predictedGlucose
        let predictedGlucoseIncludingPendingInsulin = try predictGlucose(using: settings.enabledEffects, includingPendingInsulin: true)
        self.predictedGlucoseIncludingPendingInsulin = predictedGlucoseIncludingPendingInsulin

        guard
            let maxBasal = settings.maximumBasalRatePerHour,
            let glucoseTargetRange = settings.glucoseTargetRangeScheduleApplyingOverrideIfActive,
            let insulinSensitivity = insulinSensitivityScheduleApplyingOverrideHistory,
            let carbRatioSchedule = carbRatioScheduleApplyingOverrideHistory,
            let basalRates = basalRateScheduleApplyingOverrideHistory,
            let maxBolus = settings.maximumBolus,
            let maxIOB = settings.maximumInsulinOnBoard,
            let model = insulinModelSettings?.model
        else {
            throw LoopError.configurationError(.generalSettings)
        }
        
        guard lastRequestedBolus == nil
        else {
            // Don't recommend changes if a bolus was just requested.
            // Sending additional pump commands is not going to be
            // successful in any case.
            self.logger.debug("Not generating recommendations because bolus request is in progress.")
            return
        }

        let rateRounder = { (_ rate: Double) in
            return self.delegate?.loopDataManager(self, roundBasalRate: rate) ?? rate
        }
        

        let lastTempBasal: DoseEntry?

        if case .some(.tempBasal(let dose)) = basalDeliveryState {
            lastTempBasal = dose
        } else {
            lastTempBasal = nil
        }
        
        let dosingRecommendation: AutomaticDoseRecommendation?

        let (safeMaxBolus, safeMaxBasal) = safeMaxBasalBolus(maxBolus, maxBasal, maxIOB, iob)

        switch settings.dosingStrategy {
        case .automaticBolus:
            let volumeRounder = { (_ units: Double) in
                return self.delegate?.loopDataManager(self, roundBolusVolume: units) ?? units
            }
            
            dosingRecommendation = predictedGlucose.recommendedAutomaticDose(
                to: glucoseTargetRange,
                at: predictedGlucose[0].startDate,
                suspendThreshold: settings.suspendThreshold?.quantity,
                sensitivity: insulinSensitivity,
                model: model,
                basalRates: basalRates,
                maxAutomaticBolus: safeMaxBolus * settings.bolusPartialApplicationFactor,
                partialApplicationFactor: settings.bolusPartialApplicationFactor,
                lastTempBasal: lastTempBasal,
                volumeRounder: volumeRounder,
                rateRounder: rateRounder,
                isBasalRateScheduleOverrideActive: settings.scheduleOverride?.isBasalRateScheduleOverriden(at: startDate) == true
            )
            self.logger.debug("Automatic Bolus recommendation \(String(describing: dosingRecommendation))")
        case .tempBasalOnly:
            let temp = predictedGlucose.recommendedTempBasal(
                to: glucoseTargetRange,
                at: predictedGlucose[0].startDate,
                suspendThreshold: settings.suspendThreshold?.quantity,
                sensitivity: insulinSensitivity,
                model: model,
                basalRates: basalRates,
                maxBasalRate: safeMaxBasal,
                lastTempBasal: lastTempBasal,
                rateRounder: rateRounder,
                isBasalRateScheduleOverrideActive: settings.scheduleOverride?.isBasalRateScheduleOverriden(at: startDate) == true
            )
            dosingRecommendation = AutomaticDoseRecommendation(basalAdjustment: temp, bolusUnits: 0)
            self.logger.debug("Automatic Temp Basal recommendation \(String(describing: dosingRecommendation))")
        }
        if iob.value <= maxIOB {
            if let dosingRecommendation = dosingRecommendation {
                self.logger.default("Current basal state: \(String(describing: basalDeliveryState))")
                self.logger.default("Recommending dose: \(dosingRecommendation) at \(startDate)")
                recommendedDose = (recommendation: dosingRecommendation, date: startDate)
            } else {
                recommendedDose = nil
            }
        } else {
            self.logger.default("Maximum InsulinOnBoard exceeded, recommending zero temp.")
            recommendedDose = (recommendation: AutomaticDoseRecommendation(
                basalAdjustment: TempBasalRecommendation(unitsPerHour: 0.0, duration: TimeInterval(hours: 1)),
                bolusUnits: 0.0), date: startDate)
        }

        let volumeRounder = { (_ units: Double) in
            return self.delegate?.loopDataManager(self, roundBolusVolume: units) ?? units
        }

        let recommendation = predictedGlucoseIncludingPendingInsulin.recommendedManualBolus(
            to: glucoseTargetRange,
            at: predictedGlucose[0].startDate,
            suspendThreshold: settings.suspendThreshold?.quantity,
            sensitivity: insulinSensitivity,
            carbRatio: carbRatioSchedule,
            model: model,
            pendingInsulin: 0, // Pending insulin is already reflected in the prediction
            maxBolus: safeMaxBolus,
            volumeRounder: volumeRounder
        )
        recommendedManualBolus = (recommendation: recommendation, date: startDate)
        maybeSendFutureLowNotification()
        self.logger.debug("Recommending manual bolus: \(String(describing: recommendedManualBolus))")
    }

    private func maybeSendFutureLowNotification() {
        guard let manualBolus = recommendedManualBolus else {
            return
        }
        // TODO: check current glucose before sounding alarm
        if manualBolus.recommendation.carbs > 0 {
            if let lastLow = lastLowNotification {
                if lastLow.date.timeIntervalSinceNow > TimeInterval(minutes: -5) {
                    // recently sent
                } else {
                    NotificationManager.sendGlucoseFutureLowNotifications(at: manualBolus.date, carbs: manualBolus.recommendation.carbs)
                    self.logger.debug("sendGlucoseFutureLowNotifications: \(manualBolus)")
                    nightscoutDataManager?.uploadAnnouncement(date: Date(), note: "Future low glucose, eat \(manualBolus.recommendation.carbs) g of carbs.")
                    lastLowNotification = (date: manualBolus.date, carbs: manualBolus.recommendation.carbs, sent: true)
                }
            } else {
                lastLowNotification = (date: manualBolus.date, carbs: manualBolus.recommendation.carbs, sent: false)
            }
        } else if lastLowNotification != nil {
            NotificationManager.clearGlucoseFutureLowNotifications()
            lastLowNotification = nil
        }
    }

    /// *This method should only be called from the `dataAccessQueue`*
    private func enactDose(_ completion: @escaping (_ error: Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let recommendedDose = self.recommendedDose else {
            completion(nil)
            return
        }

        guard abs(recommendedDose.date.timeIntervalSinceNow) < TimeInterval(minutes: 5) else {
            completion(LoopError.recommendationExpired(date: recommendedDose.date))
            return
        }
        
        if case .suspended = basalDeliveryState {
            completion(LoopError.pumpSuspended)
            return
        }
        if recommendedDose.recommendation.bolusUnits > 0 {
            logger.info("Automatic Dose: \(recommendedDose.recommendation.bolusUnits) U")
        } else if let basal = recommendedDose.recommendation.basalAdjustment {
            logger.info("Automatic Dose: \(basal.unitsPerHour) U/h for \(basal.duration) s")
        }
        delegate?.loopDataManager(self, didRecommend: recommendedDose) { (error) in
            self.dataAccessQueue.async {
                completion(error)
            }
        }
    }

}


/// Describes a view into the loop state
protocol LoopState {
    /// The last-calculated carbs on board
    var carbsOnBoard: CarbValue? { get }

    /// An error in the current state of the loop, or one that happened during the last attempt to loop.
    var error: Error? { get }

    /// A timeline of average velocity of glucose change counteracting predicted insulin effects
    var insulinCounteractionEffects: [GlucoseEffectVelocity] { get }

    /// The calculated timeline of predicted glucose values
    var predictedGlucose: [PredictedGlucoseValue]? { get }

    var validGlucose: GlucoseValue? { get }

    /// The calculated timeline of predicted glucose values, including the effects of pending insulin
    var predictedGlucoseIncludingPendingInsulin: [PredictedGlucoseValue]? { get }

    /// The recommended temp basal based on predicted glucose
    var recommendedAutomaticDose: (recommendation: AutomaticDoseRecommendation, date: Date)? { get }

    var recommendedBolus: (recommendation: ManualBolusRecommendation, date: Date)? { get }

    var insulinOnBoard: InsulinValue? { get }

    /// The difference in predicted vs actual glucose over a recent period
    var retrospectiveGlucoseDiscrepancies: [GlucoseChange]? { get }

    /// The total corrective glucose effect from retrospective correction
    var totalRetrospectiveCorrection: HKQuantity? { get }

    /// Calculates a new prediction from the current data using the specified effect inputs
    ///
    /// This method is intended for visualization purposes only, not dosing calculation. No validation of input data is done.
    ///
    /// - Parameter inputs: The effect inputs to include
    /// - Parameter potentialBolus: A bolus under consideration for which to include effects in the prediction
    /// - Parameter potentialCarbEntry: A carb entry under consideration for which to include effects in the prediction
    /// - Parameter replacedCarbEntry: An existing carb entry replaced by `potentialCarbEntry`
    /// - Parameter includingPendingInsulin: If `true`, the returned prediction will include the effects of scheduled but not yet delivered insulin
    /// - Returns: An timeline of predicted glucose values
    /// - Throws: LoopError.missingDataError if prediction cannot be computed
    func predictGlucose(using inputs: PredictionInputEffect, potentialBolus: DoseEntry?, potentialCarbEntry: NewCarbEntry?, replacingCarbEntry replacedCarbEntry: StoredCarbEntry?, includingPendingInsulin: Bool) throws -> [PredictedGlucoseValue]

    /// Computes the recommended bolus for correcting a glucose prediction
    /// - Parameter predictedGlucose: A timeline of predicted glucose values
    /// - Returns: A bolus recommendation, or `nil` if not applicable
    /// - Throws: LoopError.missingDataError if recommendation cannot be computed
    func recommendBolus<Sample: GlucoseValue>(forPrediction predictedGlucose: [Sample]) throws -> ManualBolusRecommendation?

    /// Computes the carbs on board, taking into account an unstored carb entry
    /// - Parameters:
    ///   - potentialCarbEntry: An unstored carb entry under consideration
    ///   - replacedCarbEntry: An existing carb entry replaced by `potentialCarbEntry`
    func computeCarbsOnBoard(potentialCarbEntry: NewCarbEntry?, replacing replacedCarbEntry: StoredCarbEntry?) -> CarbValue?
}

extension LoopState {
    /// Calculates a new prediction from the current data using the specified effect inputs
    ///
    /// This method is intended for visualization purposes only, not dosing calculation. No validation of input data is done.
    ///
    /// - Parameter inputs: The effect inputs to include
    /// - Parameter includingPendingInsulin: If `true`, the returned prediction will include the effects of scheduled but not yet delivered insulin
    /// - Returns: An timeline of predicted glucose values
    /// - Throws: LoopError.missingDataError if prediction cannot be computed
    func predictGlucose(using inputs: PredictionInputEffect, includingPendingInsulin: Bool = false) throws -> [GlucoseValue] {
        try predictGlucose(using: inputs, potentialBolus: nil, potentialCarbEntry: nil, replacingCarbEntry: nil, includingPendingInsulin: includingPendingInsulin)
    }
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

        var error: Error? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return updateError ?? loopDataManager.lastLoopError
        }

        var insulinCounteractionEffects: [GlucoseEffectVelocity] {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.insulinCounteractionEffects
        }

        var predictedGlucose: [PredictedGlucoseValue]? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.predictedGlucose
        }

        var validGlucose: GlucoseValue? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.getValidGlucose()
        }

        var predictedGlucoseIncludingPendingInsulin: [PredictedGlucoseValue]? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.predictedGlucoseIncludingPendingInsulin
        }

        var recommendedAutomaticDose: (recommendation: AutomaticDoseRecommendation, date: Date)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            guard loopDataManager.lastRequestedBolus == nil else {
                return nil
            }
            return loopDataManager.recommendedDose
        }
        
        var recommendedBolus: (recommendation: ManualBolusRecommendation, date: Date)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            guard loopDataManager.lastRequestedBolus == nil else {
                return nil
            }
            return loopDataManager.recommendedManualBolus
        }

        var retrospectiveGlucoseDiscrepancies: [GlucoseChange]? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.retrospectiveGlucoseDiscrepanciesSummed
        }

        var totalRetrospectiveCorrection: HKQuantity? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.retrospectiveCorrection.totalGlucoseCorrectionEffect
        }

        func predictGlucose(using inputs: PredictionInputEffect, potentialBolus: DoseEntry?, potentialCarbEntry: NewCarbEntry?, replacingCarbEntry replacedCarbEntry: StoredCarbEntry?, includingPendingInsulin: Bool) throws -> [PredictedGlucoseValue] {
            return try loopDataManager.predictGlucose(using: inputs, potentialBolus: potentialBolus, potentialCarbEntry: potentialCarbEntry, replacingCarbEntry: replacedCarbEntry, includingPendingInsulin: includingPendingInsulin)
        }

        func recommendBolus<Sample: GlucoseValue>(forPrediction predictedGlucose: [Sample]) throws -> ManualBolusRecommendation? {
            return try loopDataManager.recommendBolus(forPrediction: predictedGlucose)
        }

        func computeCarbsOnBoard(potentialCarbEntry: NewCarbEntry?, replacing replacedCarbEntry: StoredCarbEntry?) -> CarbValue? {
            return loopDataManager.computeCarbsOnBoard(potentialCarbEntry: potentialCarbEntry, replacing: replacedCarbEntry)
        }

        var insulinOnBoard: InsulinValue? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.insulinOnBoard
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
        dataAccessQueue.async {
            var updateError: Error?

            do {
                self.logger.debug("getLoopState: update()")
                try self.update()
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

            var entries: [String] = [
                "## LoopDataManager",
                "settings: \(String(reflecting: manager.settings))",

                "insulinCounteractionEffects: [",
                "* GlucoseEffectVelocity(start, end, mg/dL/min)",
                manager.insulinCounteractionEffects.reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: GlucoseEffectVelocity.unit))\n")
                }),
                "]",

                "insulinEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.insulinEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "carbEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.carbEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "predictedGlucose: [",
                "* PredictedGlucoseValue(start, mg/dL)",
                (state.predictedGlucose ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "retrospectiveGlucoseDiscrepancies: [",
                "* GlucoseEffect(start, mg/dL)",
                (state.retrospectiveGlucoseDiscrepancies ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "retrospectiveGlucoseDiscrepanciesSummed: [",
                "* GlucoseChange(start, end, mg/dL)",
                (manager.retrospectiveGlucoseDiscrepanciesSummed ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "glucoseMomentumEffect: \(manager.glucoseMomentumEffect ?? [])",
                "retrospectiveGlucoseEffect: \(manager.retrospectiveGlucoseEffect)",
                "recommendedTempBasal: \(String(describing: state.recommendedAutomaticDose))",
                "recommendedBolus: \(String(describing: state.recommendedBolus))",
                "lastBolus: \(String(describing: manager.lastRequestedBolus))",
                "lastLoopCompleted: \(String(describing: manager.lastLoopCompleted))",
                "basalDeliveryState: \(String(describing: manager.basalDeliveryState))",
                "carbsOnBoard: \(String(describing: state.carbsOnBoard))",
                "error: \(String(describing: state.error))",
                "",
                "cacheStore: \(String(reflecting: self.glucoseStore.cacheStore))",
                "",
                String(reflecting: self.retrospectiveCorrection),
                "",
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
    static let LoopDataUpdated = Notification.Name(rawValue: "com.loopkit.Loop.LoopDataUpdated")
    static let LoopRunning = Notification.Name(rawValue: "com.loopkit.Loop.LoopRunning")
    static let LoopCompleted = Notification.Name(rawValue: "com.loopkit.Loop.LoopCompleted")
}

protocol LoopDataManagerDelegate: class {

    /// Informs the delegate that an immediate basal change is recommended
    ///
    /// - Parameters:
    ///   - manager: The manager
    ///   - basal: The new recommended basal
    ///   - completion: A closure called once on completion
    ///   - error: Set if an error occurred while issuing dosing commands
    func loopDataManager(_ manager: LoopDataManager, didRecommend automaticDose: (recommendation: AutomaticDoseRecommendation, date: Date), completion: @escaping (_ error: Error?) -> Void) -> Void

    /// Asks the delegate to round a recommended basal rate to a supported rate
    ///
    /// - Parameters:
    ///   - rate: The recommended rate in U/hr
    /// - Returns: a supported rate of delivery in Units/hr. The rate returned should not be larger than the passed in rate.
    func loopDataManager(_ manager: LoopDataManager, roundBasalRate unitsPerHour: Double) -> Double

    /// Asks the delegate to round a recommended bolus volume to a supported volume
    ///
    /// - Parameters:
    ///   - units: The recommended bolus in U
    /// - Returns: a supported bolus volume in U. The volume returned should be the nearest deliverable volume.
    func loopDataManager(_ manager: LoopDataManager, roundBolusVolume units: Double) -> Double
}

private extension TemporaryScheduleOverride {
    func isBasalRateScheduleOverriden(at date: Date) -> Bool {
        guard isActive(at: date), let basalRateMultiplier = settings.basalRateMultiplier else {
            return false
        }
        return abs(basalRateMultiplier - 1.0) >= .ulpOfOne
    }
}
