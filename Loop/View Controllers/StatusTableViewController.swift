//
//  StatusTableViewController.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 9/6/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI
import LoopUI
import SwiftCharts
import os.log


/// Describes the state within the bolus setting flow
///
/// - recommended: A bolus recommendation was discovered and the bolus view controller is presenting/presented
/// - enacting: A bolus was requested by the user and is pending with the device manager
private enum BolusState {
    case recommended
    case enacting
}


private extension RefreshContext {
    static let all: Set<RefreshContext> = [.status, .glucose, .insulin, .carbs, .targets]
}


final class StatusTableViewController: ChartsTableViewController, MealTableViewCellDelegate {

    private let log = OSLog(category: "StatusTableViewController")

    override func viewDidLoad() {
        super.viewDidLoad()

        charts.glucoseDisplayRange = (
            min: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100),
            max: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 175)
        )

        let notificationCenter = NotificationCenter.default

        notificationObservers += [
            notificationCenter.addObserver(forName: .LoopDataUpdated, object: deviceManager.loopManager, queue: nil) { [weak self] note in
                let rawContext = note.userInfo?[LoopDataManager.LoopUpdateContextKey] as! LoopDataManager.LoopUpdateContext.RawValue
                let context = LoopDataManager.LoopUpdateContext(rawValue: rawContext)
                DispatchQueue.main.async {
                    switch context {
                    case .none, .bolus?:
                        self?.refreshContext.formUnion([.status, .insulin])
                    case .preferences?:
                        self?.refreshContext.formUnion([.status, .targets])
                    case .carbs?:
                        self?.refreshContext.update(with: .carbs)
                    case .glucose?:
                        self?.refreshContext.formUnion([.glucose, .carbs])
                    case .tempBasal?:
                        self?.refreshContext.update(with: .insulin)
                    }

                    self?.hudView?.loopCompletionHUD.loopInProgress = false
                    self?.log.debug("[reloadData] from notification with context %{public}@", String(describing: context))
                    self?.reloadData(animated: true)
                }
            },
            notificationCenter.addObserver(forName: .LoopRunning, object: deviceManager.loopManager, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.hudView?.loopCompletionHUD.loopInProgress = true
                }
            }
        ]

        if let gestureRecognizer = charts.gestureRecognizer {
            tableView.addGestureRecognizer(gestureRecognizer)
        }

        tableView.estimatedRowHeight = 70

        // Estimate an initial value
        landscapeMode = UIScreen.main.bounds.size.width > UIScreen.main.bounds.size.height

        // Toolbar
        toolbarItems![0].accessibilityLabel = NSLocalizedString("Add Meal", comment: "The label of the carb entry button")
        toolbarItems![0].tintColor = UIColor.COBTintColor
       // toolbarItems![0].action = #selector(showQuickCarbEntry(_:))
        
        toolbarItems![2] = createNoteButtonItem()
        
        toolbarItems![4].accessibilityLabel = NSLocalizedString("Bolus", comment: "The label of the bolus entry button")
        toolbarItems![4].tintColor = UIColor.doseTintColor
        toolbarItems![8].accessibilityLabel = NSLocalizedString("Settings", comment: "The label of the settings button")
        toolbarItems![8].tintColor = UIColor.secondaryLabelColor
        
        let longTapGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(toggleExpertMode(_:)))
        longTapGestureRecognizer.minimumPressDuration = 0.3
        
        self.navigationController?.toolbar.addGestureRecognizer(longTapGestureRecognizer)
        
        toolbarItems![8].isEnabled = expertMode
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()

        if !visible {
            refreshContext.formUnion(RefreshContext.all)
        }
    }

    private var appearedOnce = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !appearedOnce {
            appearedOnce = true

            if deviceManager.loopManager.authorizationRequired {
                deviceManager.loopManager.authorize {
                    DispatchQueue.main.async {
                        self.log.debug("[reloadData] after HealthKit authorization")
                        self.reloadData()
                    }
                }
            }
        }

        AnalyticsManager.shared.didDisplayStatusScreen()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        if presentedViewController == nil {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        refreshContext.update(with: .size(size))

        super.viewWillTransition(to: size, with: coordinator)
    }

    // MARK: - State

    override var active: Bool {
        get {
            return super.active
        }
        set {
            super.active = newValue
            hudView?.loopCompletionHUD.assertTimer(active)
        }
    }

    private var bolusState: BolusState? {
        didSet {
            switch bolusState {
            case .enacting?:
                updateHUDandStatusRows(statusRowMode: .enactingBolus, newSize: nil, animated: true)
            default:
                updateHUDandStatusRows(statusRowMode: .hidden, newSize: nil, animated: true)
            }

            refreshContext.update(with: .status)
        }
    }

    // Toggles the display mode based on the screen aspect ratio. Should not be updated outside of reloadData().
    private var landscapeMode = false

    private var lastLoopError: Error?

    private var reloading = false

    private var refreshContext = RefreshContext.all

    private var shouldShowHUD: Bool {
        return !landscapeMode
    }

    private var shouldShowStatus: Bool {
        return !landscapeMode && statusRowMode.hasRow
    }

    private func updateMealInformation(_ updateGroup: DispatchGroup, _ carbStore: CarbStore?) {
        //dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        if let carbStore = carbStore {
            let endDate = Date()
            let mealDate = endDate.addingTimeInterval(TimeInterval(minutes: -45))
            
            let undoPossibleDate = endDate.addingTimeInterval(TimeInterval(minutes: -15))
            updateGroup.enter()
            //carbStore.getCarbEntries(start: mealDate) { (result) in
            //    switch(result) {
            //    case .success(let values):
            carbStore.getCachedCarbSamples(start: mealDate) { (values) in

                var mealStart = endDate
                var mealEnd = mealDate
                var carbs : Double = 0
                var allPicks = FoodPicks()
                for value in values {
                    // NSLog("  updateMealInformation - v - \(value)")
                    mealStart = min(mealStart, value.startDate)
                    mealEnd = max(value.startDate, mealStart)
                    let picks = value.foodPicks()
                    for pick in picks.picks {
                        allPicks.append(pick)
                    }
                    // NSLog("  updateMealInformation - p - \(picks)")
                    if let lastpick = picks.last {
                        mealEnd = max(lastpick.date, mealEnd)
                    }
                    carbs = carbs + picks.carbs
                    
                }
                // NSLog("  updateMealInformation - carbs - \(carbs)")
                //var undoPossible = false
                //if let undoPossibleDate = undoPossibleDate {
                let undoPossible = undoPossibleDate <= mealEnd
                //}
                self.mealInformation = (date: endDate, lastCarbEntry: values.last,
                                        picks: allPicks,
                                        start: mealStart, end: mealEnd, carbs: carbs, undoPossible: undoPossible)
                
                NSLog("updateMealInformation - \(self.mealInformation as Any)")
                //case .failure(let error):
                //    NSLog("updateMealInformation - error - ", error as Any)
                //}
                updateGroup.leave()
            }
        }
        //mealInformationNeedsUpdate = false
    }

    override func glucoseUnitDidChange() {
        refreshContext = RefreshContext.all
    }

    private func updateChartDateRange() {
        let settings = deviceManager.loopManager.settings

        // How far back should we show data? Use the screen size as a guide.
        let availableWidth = (refreshContext.newSize ?? self.tableView.bounds.size).width - self.charts.fixedHorizontalMargin

        let totalHours = floor(Double(availableWidth / settings.minimumChartWidthPerHour))
        let futureHours = ceil((deviceManager.loopManager.insulinModelSettings?.model.effectDuration ?? .hours(4)).hours)
        let historyHours = max(settings.statusChartMinimumHistoryDisplay.hours, totalHours - futureHours)

        let date = Date(timeIntervalSinceNow: -TimeInterval(hours: historyHours))
        let chartStartDate = Calendar.current.nextDate(after: date, matching: DateComponents(minute: 0), matchingPolicy: .strict, direction: .backward) ?? date
        if charts.startDate != chartStartDate {
            refreshContext.formUnion(RefreshContext.all)
        }
        charts.startDate = chartStartDate
        charts.maxEndDate = chartStartDate.addingTimeInterval(.hours(totalHours))
        charts.updateEndDate(charts.maxEndDate)
    }

    override func reloadData(animated: Bool = false) {
        // This should be kept up to date immediately
        hudView?.loopCompletionHUD.lastLoopCompleted = deviceManager.loopManager.lastLoopCompleted

        guard !reloading && !deviceManager.loopManager.authorizationRequired else {
            return
        }

        updateChartDateRange()
        redrawCharts()

        guard active && visible && !refreshContext.isEmpty else {
            return
        }

        log.debug("Reloading data with context: %@", String(describing: refreshContext))

        let currentContext = refreshContext
        var retryContext: Set<RefreshContext> = []
        self.refreshContext = []
        reloading = true

        let reloadGroup = DispatchGroup()
        var lastReservoirValue: ReservoirValue?
        var newRecommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)?
        var glucoseValues: [StoredGlucoseSample]?
        var predictedGlucoseValues: [GlucoseValue]?
        var iobValues: [InsulinValue]?
        var doseEntries: [DoseEntry]?
        var totalDelivery: Double?
        var cobValues: [CarbValue]?
        let bolusState = self.bolusState
        let startDate = charts.startDate

        // TODO: Don't always assume currentContext.contains(.status)
        reloadGroup.enter()
        self.deviceManager.loopManager.getLoopState { (manager, state) -> Void in
            predictedGlucoseValues = state.predictedGlucose ?? []

            // Retry this refresh again if predicted glucose isn't available
            if state.predictedGlucose == nil {
                retryContext.update(with: .status)
            }

            /// Update the status HUDs immediately
            let netBasal: NetBasal?
            let lastLoopCompleted = manager.lastLoopCompleted
            let lastLoopError = state.error

            // Net basal rate HUD
            let date = state.lastTempBasal?.startDate ?? Date()
            if let scheduledBasal = manager.basalRateSchedule?.between(start: date, end: date).first {
                netBasal = NetBasal(
                    lastTempBasal: state.lastTempBasal,
                    maxBasal: manager.settings.maximumBasalRatePerHour,
                    scheduledBasal: scheduledBasal
                )
            } else {
                netBasal = nil
            }

            self.pumpDetachedMode = state.pumpDetachedMode
            self.treatmentInformation = state.treatmentInformation


            self.validGlucose = state.validGlucose
            if let _ = self.validGlucose {
                self.needManualGlucose = nil
            } else {
                self.needManualGlucose = Date()
            }

            DispatchQueue.main.async {
                self.hudView?.loopCompletionHUD.dosingEnabled = manager.settings.dosingEnabled
                self.lastLoopError = lastLoopError

                if let netBasal = netBasal {
                    self.hudView?.basalRateHUD.setNetBasalRate(netBasal.rate, percent: netBasal.percent, at: netBasal.start)
                }

                if let ti = self.treatmentInformation {
                    self.toolbarItems![4].isEnabled = ti.allowed
                } else {
                    self.toolbarItems![4].isEnabled = false // fail closed
                }
            }

            // Display a recommended basal change only if we haven't completed recently, or we're in open-loop mode
            if lastLoopCompleted == nil ||
                lastLoopCompleted! < Date(timeIntervalSinceNow: .minutes(-6)) ||
                !manager.settings.dosingEnabled
            {
                newRecommendedTempBasal = state.recommendedTempBasal
            }

            if currentContext.contains(.carbs) {
                reloadGroup.enter()
                manager.carbStore.getCarbsOnBoardValues(start: startDate, effectVelocities: manager.settings.dynamicCarbAbsorptionEnabled ? state.insulinCounteractionEffects : nil) { (values) in
                    cobValues = values
                    reloadGroup.leave()
                }
                self.updateMealInformation(reloadGroup, manager.carbStore)
            }

            reloadGroup.leave()
        }

        if currentContext.contains(.glucose) {
            reloadGroup.enter()
            self.deviceManager.loopManager.glucoseStore.getCachedGlucoseSamples(start: startDate) { (values) -> Void in
                glucoseValues = values
                reloadGroup.leave()
            }
        }

        if currentContext.contains(.insulin) {
            reloadGroup.enter()
            deviceManager.loopManager.doseStore.getInsulinOnBoardValues(start: startDate) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.deviceManager.logger.addError(error, fromSource: "DoseStore")
                    retryContext.update(with: .insulin)
                    iobValues = []
                case .success(let values):
                    iobValues = values
                }
                reloadGroup.leave()
            }

            reloadGroup.enter()
            deviceManager.loopManager.doseStore.getNormalizedDoseEntries(start: startDate) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.deviceManager.logger.addError(error, fromSource: "DoseStore")
                    retryContext.update(with: .insulin)
                    doseEntries = []
                case .success(let doses):
                    doseEntries = doses
                }
                reloadGroup.leave()
            }

            reloadGroup.enter()
            deviceManager.loopManager.doseStore.getTotalUnitsDelivered(since: Calendar.current.startOfDay(for: Date())) { (result) in
                switch result {
                case .failure:
                    retryContext.update(with: .insulin)
                    totalDelivery = nil
                case .success(let total):
                    totalDelivery = total.value
                }

                reloadGroup.leave()
            }

            reloadGroup.enter()
            deviceManager.loopManager.doseStore.getReservoirValues(since: Date(timeIntervalSinceNow: .minutes(-30)), limit: 1) { (result) in
                switch result {
                case .success(let values):
                    lastReservoirValue = values.first
                case .failure:
                    retryContext.update(with: .insulin)
                }

                reloadGroup.leave()
            }
        }

        workoutMode = deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.overrideEnabledForContext(.workout)
        preMealMode = deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.overrideEnabledForContext(.preMeal)

        reloadGroup.notify(queue: .main) {
            /// Update the chart data

            // Glucose
            if let glucoseValues = glucoseValues {
                self.charts.setGlucoseValues(glucoseValues)
            }
            if let predictedGlucoseValues = predictedGlucoseValues {
                self.charts.setPredictedGlucoseValues(predictedGlucoseValues)
            }
            if let lastPoint = self.charts.predictedGlucosePoints.last?.y {
                self.eventualGlucoseDescription = String(describing: lastPoint)
            } else {
                self.eventualGlucoseDescription = nil
            }
            if currentContext.contains(.targets) {
                self.charts.targetGlucoseSchedule = self.deviceManager.loopManager.settings.glucoseTargetRangeSchedule
            }

            // Active Insulin
            if let iobValues = iobValues {
                self.charts.setIOBValues(iobValues)
            }
            if let index = self.charts.iobPoints.closestIndexPriorToDate(Date()) {
                self.currentIOBDescription = String(describing: self.charts.iobPoints[index].y)
            } else {
                self.currentIOBDescription = nil
            }

            // Insulin Delivery
            if let doseEntries = doseEntries {
                self.charts.setDoseEntries(doseEntries)
            }
            if let totalDelivery = totalDelivery {
                self.totalDelivery = totalDelivery
            }

            // Active Carbohydrates
            if let cobValues = cobValues {
                self.charts.setCOBValues(cobValues)
            }
            if let index = self.charts.cobPoints.closestIndexPriorToDate(Date()) {
                self.currentCOBDescription = String(describing: self.charts.cobPoints[index].y)
            } else {
                self.currentCOBDescription = nil
            }

            self.tableView.beginUpdates()
            if let hudView = self.hudView {
                // Glucose HUD
                if let glucose = self.deviceManager.loopManager.glucoseStore.latestGlucose {
                    hudView.glucoseHUD.setGlucoseQuantity(glucose.quantity.doubleValue(for: self.charts.glucoseUnit),
                        at: glucose.startDate,
                        unit: self.charts.glucoseUnit,
                        sensor: self.deviceManager.sensorInfo
                    )
                }

                // Reservoir HUD
                if let reservoir = lastReservoirValue {
                    if let capacity = self.deviceManager.pumpState?.pumpModel?.reservoirCapacity {
                        hudView.reservoirVolumeHUD.reservoirLevel = min(1, max(0, Double(reservoir.unitVolume / Double(capacity))))
                    }

                    hudView.reservoirVolumeHUD.setReservoirVolume(volume: reservoir.unitVolume, at: reservoir.startDate)
                }

                // Battery HUD
                hudView.batteryHUD.batteryLevel = self.deviceManager.pumpBatteryChargeRemaining
            }

            // Show/hide the table view rows
            let statusRowMode: StatusRowMode?

            switch bolusState {
            case .recommended?, .enacting?:
                statusRowMode = nil
            case .none:
                if let (recommendation: tempBasal, date: date) = newRecommendedTempBasal {
                    // TODO(Erik) DDisplay this if we're in closed mode and the loop recently failed
                    if self.deviceManager.loopManager.settings.dosingEnabled {
                        statusRowMode = .hidden
                    } else {
                        statusRowMode = .recommendedTempBasal(tempBasal: tempBasal, at: date, enacting: false)
                    }
                } else {
                    statusRowMode = .hidden
                }
            }

            self.updateHUDandStatusRows(statusRowMode: statusRowMode, newSize: currentContext.newSize, animated: animated)
            self.redrawCharts()

            self.tableView.endUpdates()

            self.reloading = false
            let reloadNow = !self.refreshContext.isEmpty
            self.refreshContext.formUnion(retryContext)

            // Trigger a reload if new context exists.
            if reloadNow {
                self.log.debug("[reloadData] due to context change during previous reload")
                self.reloadData()
            }
        }
    }

    private enum Section: Int {
        case hud = 0
        case status   // Bolus or TempBasalRecommendation
        case detached  // DetachedMode reminder
        case treatment  // Advanced Treatment and ongoing Bolus Information
        case glucose // Glucose not available reminder
        case meal   // Meal Information
        case charts

        static let count = 7
    }

    // MARK: - Chart Section Data

    private enum ChartRow: Int {
        case glucose = 0
        case iob
        case dose
        case cob

        static let count = 4
    }

    // MARK: Glucose

    private var eventualGlucoseDescription: String?

    // MARK: IOB

    private var currentIOBDescription: String?

    // MARK: Dose

    private var totalDelivery: Double?

    // MARK: COB

    private var currentCOBDescription: String?

    // MARK: - Loop Status Section Data

    private enum StatusRow: Int {
        case status = 0

        static let count = 1
    }

    private enum StatusRowMode {
        case hidden
        case recommendedTempBasal(tempBasal: TempBasalRecommendation, at: Date, enacting: Bool)
        case enactingBolus

        var hasRow: Bool {
            switch self {
            case .hidden:
                return false
            case .enactingBolus:
                // Managed by different row in this version.
                return false
            default:
                return true
            }
        }
    }

    private var statusRowMode = StatusRowMode.hidden
    
    private var shouldShowPumpDetached : Bool {
        return !landscapeMode && (displayPumpDetachedMode != nil)
    }

    private var shouldShowTreatmentInformation: Bool {
        // TODO(Erik) Take dismissed information into account (but needs to be updated by the HUD function below
        if landscapeMode {
            return false
        }
        if let ti = displayTreatmentInformation {
            return ti.state != .none
        }
        return false
    }
    
    private var shouldShowNeedManualGlucose: Bool {
        return !landscapeMode && (displayNeedManualGlucose != nil)
    }
    
    private var shouldShowMeal: Bool {
        return !landscapeMode
    }
    
    private func updateHUDandStatusRows(statusRowMode: StatusRowMode?, newSize: CGSize?, animated: Bool) {
        let hudWasVisible = self.shouldShowHUD
        let statusWasVisible = self.shouldShowStatus
        let treatmentWasVisible = self.shouldShowTreatmentInformation
        let glucoseWasVisible = self.shouldShowNeedManualGlucose
        let detachedWasVisible = self.shouldShowPumpDetached
        let mealWasVisible = self.shouldShowMeal

        let oldStatusRowMode = self.statusRowMode
        if let statusRowMode = statusRowMode {
            self.statusRowMode = statusRowMode
        }
        
        
        let oldTreatmentInformation = self.displayTreatmentInformation
        let newTreatmentInformation = self.treatmentInformation
        self.displayTreatmentInformation = newTreatmentInformation
        
        let oldNeedManualGlucose = self.displayNeedManualGlucose
        let newNeedManualGlucose = self.needManualGlucose
        self.displayNeedManualGlucose = newNeedManualGlucose
        
        let oldPumpDetachedMode = self.displayPumpDetachedMode
        let newPumpDetachedMode = self.pumpDetachedMode
        self.displayPumpDetachedMode = newPumpDetachedMode
        

        if let newSize = newSize {
            self.landscapeMode = newSize.width > newSize.height
        }

        let hudIsVisible = self.shouldShowHUD
        let statusIsVisible = self.shouldShowStatus
        let treatmentIsVisible = self.shouldShowTreatmentInformation
        let glucoseIsVisible = self.shouldShowNeedManualGlucose
        let detachedIsVisible = self.shouldShowPumpDetached
        let mealIsVisible = self.shouldShowMeal
        
        tableView.beginUpdates()

        switch (hudWasVisible, hudIsVisible) {
        case (false, true):
            self.tableView.insertRows(at: [IndexPath(row: 0, section: Section.hud.rawValue)], with: animated ? .top : .none)
        case (true, false):
            self.tableView.deleteRows(at: [IndexPath(row: 0, section: Section.hud.rawValue)], with: animated ? .top : .none)
        default:
            break
        }

        let statusIndexPath = IndexPath(row: StatusRow.status.rawValue, section: Section.status.rawValue)

        switch (statusWasVisible, statusIsVisible) {
        case (true, true):
            switch (oldStatusRowMode, self.statusRowMode) {
            case (.recommendedTempBasal(tempBasal: let oldTempBasal, at: let oldDate, enacting: let wasEnacting),
                  .recommendedTempBasal(tempBasal: let newTempBasal, at: let newDate, enacting: let isEnacting)):
                // Ensure we have a change
                guard oldTempBasal != newTempBasal || oldDate != newDate || wasEnacting != isEnacting else {
                    break
                }

                // If the rate or date change, reload the row
                if oldTempBasal != newTempBasal || oldDate != newDate {
                    self.tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
                } else if let cell = tableView.cellForRow(at: statusIndexPath) {
                    // If only the enacting state changed, update the activity indicator
                    if isEnacting {
                        let indicatorView = UIActivityIndicatorView(activityIndicatorStyle: .gray)
                        indicatorView.startAnimating()
                        cell.accessoryView = indicatorView
                    } else {
                        cell.accessoryView = nil
                    }
                }
            case (.enactingBolus, .enactingBolus):
                break
            default:
                self.tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
            }
        case (false, true):
            self.tableView.insertRows(at: [statusIndexPath], with: animated ? .top : .none)
        case (true, false):
            self.tableView.deleteRows(at: [statusIndexPath], with: animated ? .top : .none)
        default:
            break
        }

        let treatmentIndexPath = IndexPath(row: 0, section: Section.treatment.rawValue)
        switch (treatmentWasVisible, treatmentIsVisible) {
        case (true, true):
            if let old = oldTreatmentInformation, let new = newTreatmentInformation,
                !old.equal(new) {
                self.tableView.reloadRows(at: [treatmentIndexPath], with: animated ? .top : .none)
            }
            if oldTreatmentInformation == nil, newTreatmentInformation != nil {
                self.tableView.reloadRows(at: [treatmentIndexPath], with: animated ? .top : .none)
            }
            if oldTreatmentInformation != nil, newTreatmentInformation == nil {
                self.tableView.reloadRows(at: [treatmentIndexPath], with: animated ? .top : .none)
            }
        case (false, true):
            self.tableView.insertRows(at: [treatmentIndexPath], with: animated ? .top : .none)
        case (true, false):
            self.tableView.deleteRows(at: [treatmentIndexPath], with: animated ? .top : .none)
        default:
            break
        }
        
        let detachedIndexPath = IndexPath(row: 0, section: Section.detached.rawValue)
        switch (detachedWasVisible, detachedIsVisible) {
        case (true, true):
            if oldPumpDetachedMode != newPumpDetachedMode {
                self.tableView.reloadRows(at: [detachedIndexPath], with: animated ? .top : .none)
            }
        case (false, true):
            self.tableView.insertRows(at: [detachedIndexPath], with: animated ? .top : .none)
        case (true, false):
            self.tableView.deleteRows(at: [detachedIndexPath], with: animated ? .top : .none)
        default:
            break
        }
        
        let glucoseIndexPath = IndexPath(row: 0, section: Section.glucose.rawValue)
        switch (glucoseWasVisible, glucoseIsVisible) {
        case (true, true):
            if oldNeedManualGlucose != newNeedManualGlucose {
                self.tableView.reloadRows(at: [glucoseIndexPath], with: animated ? .top : .none)
            }
        case (false, true):
            self.tableView.insertRows(at: [glucoseIndexPath], with: animated ? .top : .none)
        case (true, false):
            self.tableView.deleteRows(at: [glucoseIndexPath], with: animated ? .top : .none)
        default:
            break
        }
        
        let mealIndexPath = IndexPath(row: 0, section: Section.meal.rawValue)
        switch (mealWasVisible, mealIsVisible) {
        case (true, true):
            // TODO(Erik) Make dependent on mealInformation changing.
            self.tableView.reloadRows(at: [mealIndexPath], with: .none)
        case (false, true):
            self.tableView.insertRows(at: [mealIndexPath], with: animated ? .top : .none)
        case (true, false):
            self.tableView.deleteRows(at: [mealIndexPath], with: animated ? .top : .none)
        default:
            break
        }
        
        
        tableView.endUpdates()
    }

    private func redrawCharts() {
        tableView.beginUpdates()
        self.charts.prerender()
        for case let cell as ChartTableViewCell in self.tableView.visibleCells {
            cell.reloadChart()

            if let indexPath = self.tableView.indexPath(for: cell) {
                self.tableView(self.tableView, updateSubtitleFor: cell, at: indexPath)
            }
        }
        tableView.endUpdates()
    }

    // MARK: - Toolbar data

    private var preMealMode: Bool? = nil {
        didSet {
            guard oldValue != preMealMode else {
                return
            }

//            if let preMealMode = preMealMode {
//                toolbarItems![2] = createPreMealButtonItem(selected: preMealMode)
//            } else {
//                toolbarItems![2].isEnabled = false
//            }
        }
    }

    private var workoutMode: Bool? = nil {
        didSet {
            guard oldValue != workoutMode else {
                return
            }

            if let workoutMode = workoutMode {
                toolbarItems![6] = createWorkoutButtonItem(selected: workoutMode)
            } else {
                toolbarItems![6].isEnabled = false
            }
        }
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .hud:
            return shouldShowHUD ? 1 : 0
        case .charts:
            return ChartRow.count
        case .status:
            return shouldShowStatus ? StatusRow.count : 0
        case .detached:
            return shouldShowPumpDetached ? 1 : 0
        case .treatment:
            return shouldShowTreatmentInformation ? 1 : 0
        case .meal:
            return shouldShowMeal ? 1 : 0
        case .glucose:
            return shouldShowNeedManualGlucose ? 1 : 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .hud:
            let cell = tableView.dequeueReusableCell(withIdentifier: HUDViewTableViewCell.className, for: indexPath) as! HUDViewTableViewCell
            self.hudView = cell.hudView

            return cell
        case .charts:
            let cell = tableView.dequeueReusableCell(withIdentifier: ChartTableViewCell.className, for: indexPath) as! ChartTableViewCell

            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                cell.chartContentView.chartGenerator = { [weak self] (frame) in
                    return self?.charts.glucoseChartWithFrame(frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Glucose", comment: "The title of the glucose and prediction graph")
            case .iob:
                cell.chartContentView.chartGenerator = { [weak self] (frame) in
                    return self?.charts.iobChartWithFrame(frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Active Insulin", comment: "The title of the Insulin On-Board graph")
            case .dose:
                cell.chartContentView?.chartGenerator = { [weak self] (frame) in
                    return self?.charts.doseChartWithFrame(frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Insulin Delivery", comment: "The title of the insulin delivery graph")
            case .cob:
                cell.chartContentView?.chartGenerator = { [weak self] (frame) in
                    return self?.charts.cobChartWithFrame(frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Active Carbohydrates", comment: "The title of the Carbs On-Board graph")
            }

            self.tableView(tableView, updateSubtitleFor: cell, at: indexPath)

            let alpha: CGFloat = charts.gestureRecognizer?.state == .possible ? 1 : 0
            cell.titleLabel?.alpha = alpha
            cell.subtitleLabel?.alpha = alpha

            cell.subtitleLabel?.textColor = UIColor.secondaryLabelColor

            return cell
        case .status:
            let cell = tableView.dequeueReusableCell(withIdentifier: TitleSubtitleTableViewCell.className, for: indexPath) as! TitleSubtitleTableViewCell
            cell.selectionStyle = .none

            switch StatusRow(rawValue: indexPath.row)! {
            case .status:
                switch statusRowMode {
                case .hidden:
                    cell.titleLabel.text = nil
                    cell.subtitleLabel?.text = nil
                    cell.accessoryView = nil
                case .recommendedTempBasal(tempBasal: let tempBasal, at: let date, enacting: let enacting):
                    let timeFormatter = DateFormatter()
                    timeFormatter.dateStyle = .none
                    timeFormatter.timeStyle = .short

                    cell.titleLabel.text = NSLocalizedString("Recommended Basal", comment: "The title of the cell displaying a recommended temp basal value")
                    cell.subtitleLabel?.text = String(format: NSLocalizedString("%1$@ U/hour @ %2$@", comment: "The format for recommended temp basal rate and time. (1: localized rate number)(2: localized time)"), NumberFormatter.localizedString(from: NSNumber(value: tempBasal.unitsPerHour), number: .decimal), timeFormatter.string(from: date))
                    cell.selectionStyle = .default

                    if enacting {
                        let indicatorView = UIActivityIndicatorView(activityIndicatorStyle: .gray)
                        indicatorView.startAnimating()
                        cell.accessoryView = indicatorView
                    } else {
                        cell.accessoryView = nil
                    }
                case .enactingBolus:
                    cell.titleLabel.text = NSLocalizedString("Starting Bolus", comment: "The title of the cell indicating a bolus is being sent")
                    cell.subtitleLabel.text = nil

                    let indicatorView = UIActivityIndicatorView(activityIndicatorStyle: .gray)
                    indicatorView.startAnimating()
                    cell.accessoryView = indicatorView
                }
            }

            return cell
            
        case .treatment:
            let cell = tableView.dequeueReusableCell(withIdentifier: "BolusTableViewCell", for: indexPath) as! TitleSubtitleTableViewCell
            if let pending = self.treatmentInformation {
                let description = pending.description()
                let kind = pending.kind()
                cell.titleLabel?.text = "\(description) \(kind)"
                if pending.carbs > 0 {
                    cell.subtitleLabel?.text = String(format: NSLocalizedString("%1$@ g @ %2$@", comment: "The format for current carbs and time. (1: localized unit number)(2: localized time)"), NumberFormatter.localizedString(from: NSNumber(value: pending.carbs), number: .decimal), timeFormatter.string(from: pending.date))
                } else {
                    cell.subtitleLabel?.text = String(format: NSLocalizedString("%1$@ U @ %2$@", comment: "The format for current bolus and time. (1: localized unit number)(2: localized time)"), NumberFormatter.localizedString(from: NSNumber(value: pending.units), number: .decimal), timeFormatter.string(from: pending.date))
                }
                var color : UIColor = UIColor.black
                let spinWheel = pending.inProgress()
                
                var readPump = false
                switch(pending.state) {
                case .sent:
                    color = UIColor.orange
                    readPump = true
                case .maybefailed:
                    color = UIColor.orange
                    readPump = true
                case .failed:
                    color = UIColor.red
                case .timeout:
                    color = UIColor.red
                case .pending:
                    readPump = true
                default: _ = true
                }
                if readPump {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                        self.deviceManager.triggerPumpDataRead()
                    }
                }
                if cell.explanationLabel != nil {
                    cell.explanationLabel?.text = pending.explanation(bolusEnabled: deviceManager.loopManager.settings.bolusEnabled)
                }
                cell.titleLabel?.textColor = color
                cell.subtitleLabel?.textColor = color
                
                if spinWheel {
                    let indicatorView = UIActivityIndicatorView(activityIndicatorStyle: .gray)
                    indicatorView.startAnimating()
                    cell.accessoryView = indicatorView
                } else {
                    cell.accessoryView = nil
                }
            } else {
                cell.titleLabel?.text = "Bolus?"
                cell.subtitleLabel?.text = "- nil -"
                cell.accessoryView = nil
                
            }
            cell.selectionStyle = .default
            
            return cell
        case .meal:
            let cell = tableView.dequeueReusableCell(withIdentifier: "MealTableViewCell", for: indexPath) as! MealTableViewCell
            //let dataSource = FoodRecentCollectionViewDataSource()
            
            var foodPicks = FoodPicks()
            
            var undoPossible = false
            if let mi = self.mealInformation, let mealEnd = mi.end, mealEnd.timeIntervalSinceNow > TimeInterval(minutes: -30) {
                let intcarbs = Int(mi.carbs ?? 0)
                cell.currentCarbLabel.text = "\(intcarbs) g"
                if let fp = mi.picks {
                    foodPicks = fp
                }
//                if let estimator = mi.estimator {
//                    let td = timeFormatter.string(from: estimator.start)
//                    let ti = Int(estimator.absorbed)
//                    let tr = Int(estimator.rate)
//
//                    cell.debugLabelTop.text = "@\(td)"
//                    cell.debugLabelBottom.text = "\(ti) g, \(tr) g/h"
//                } else {
                    cell.debugLabelTop.text = ""
                    cell.debugLabelBottom.text = ""
                    
//                }
                if let start = mi.start, let end = mi.end {
                    let t1 = timeFormatter.string(from: start)
                    let t2 = timeFormatter.string(from: end)
                    if start > end {
                        // meal not started, show nothing.
                        cell.currentCarbDate.text = "(tap to eat)"
                    } else if t1 == t2 {
                        cell.currentCarbDate.text = "\(t1)"
                    } else {
                        cell.currentCarbDate.text = "\(t1) - \(t2)"
                    }
                } else {
                    
                    cell.currentCarbDate.text = "(tap to eat)"
                    
                }
                undoPossible = mi.undoPossible
            } else {
                cell.currentCarbLabel.text = ""
                cell.currentCarbDate.text = ""
                cell.debugLabelTop.text = ""
                cell.debugLabelBottom.text = ""
                cell.currentCarbLabel.text = "0 g"
                cell.currentCarbDate.text = "(tap to eat)"
            }
            
            if undoPossible, mealInformation?.lastCarbEntry != nil {
                cell.undoLabel.text = "Undo"
                cell.undoLabel.backgroundColor = UIColor.orange
            } else {
                cell.undoLabel.text = ""
                cell.undoLabel.backgroundColor = UIColor.white
                /*
                 if picks.count == 0 {
                 cell.undoLabel.text = "Start\nMeal"
                 } else {
                 cell.undoLabel.text = "Add\nmore"
                 }
                 */
            }
            //cell.undoLabel.frame = cell.lastItemView.frame
            cell.leftImageView.tintColor = UIColor.COBTintColor
            cell.leftImageView.image = UIImage(named: "fork")?.withRenderingMode(.alwaysTemplate)
            // cell.leftImageView.image?.renderingMode = .alwaysTemplate
            //cell.leftButton.tintColor = UIColor.COBTintColor
            //cell.leftButton.render
            //cell.recentFoodCollectionView.collectionViewLayout = FoodRecentPickerFlowLayout()
            cell.delegate = self
            if cell.recentFoodCollectionView.dataSource == nil {
                cell.recentFoodCollectionView.dataSource = foodRecentCollectionViewDataSource //as UICollectionViewDataSource
            }
            foodRecentCollectionViewDataSource.foodManager = foodManager
            foodRecentCollectionViewDataSource.foodPicks = foodPicks
            cell.recentFoodCollectionView.reloadData()
            cell.recentFoodCollectionView.collectionViewLayout.invalidateLayout()
            return cell
        case .detached:
            let cell = tableView.dequeueReusableCell(withIdentifier: "DisconnectTableViewCell", for: indexPath) as! TitleSubtitleTableViewCell
            if let detached = self.pumpDetachedMode {
                let color = UIColor.red
                cell.subtitleLabel?.text = "until " + timeFormatter.string(from: detached)
                cell.explanationLabel?.textColor = color
                cell.titleLabel?.textColor = color
                cell.subtitleLabel?.textColor = color
                cell.accessoryView = nil
            }
            cell.selectionStyle = .default
            
            return cell
        case .glucose:
            let cell = tableView.dequeueReusableCell(withIdentifier: "GlucoseTableViewCell", for: indexPath) as! TitleSubtitleTableViewCell
            if let glucoseDate = displayNeedManualGlucose {
                cell.subtitleLabel?.text = timeFormatter.string(from: glucoseDate)
            }
            cell.accessoryView = nil
            
            cell.selectionStyle = .default
            
            return cell
        }
        
    }

    private func tableView(_ tableView: UITableView, updateSubtitleFor cell: ChartTableViewCell, at indexPath: IndexPath) {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                if let eventualGlucose = eventualGlucoseDescription {
                    cell.subtitleLabel?.text = String(format: NSLocalizedString("Eventually %@", comment: "The subtitle format describing eventual glucose. (1: localized glucose value description)"), eventualGlucose)
                } else {
                    cell.subtitleLabel?.text = nil
                }
            case .iob:
                if let currentIOB = currentIOBDescription {
                    cell.subtitleLabel?.text = currentIOB
                } else {
                    cell.subtitleLabel?.text = nil
                }
            case .dose:
                let integerFormatter = NumberFormatter()
                integerFormatter.maximumFractionDigits = 0

                if  let total = totalDelivery,
                    let totalString = integerFormatter.string(from: total) {
                    cell.subtitleLabel?.text = String(format: NSLocalizedString("%@ U Total", comment: "The subtitle format describing total insulin. (1: localized insulin total)"), totalString)
                } else {
                    cell.subtitleLabel?.text = nil
                }
            case .cob:
                if let currentCOB = currentCOBDescription {
                    cell.subtitleLabel?.text = currentCOB
                } else {
                    cell.subtitleLabel?.text = nil
                }
            }
        case .hud, .status:
            break
        case .detached:
            break
        case .treatment:
            break
        case .glucose:
            break
        case .meal:
            break
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            // Compute the height of the HUD, defaulting to 70
            let hudHeight = ceil(hudView?.systemLayoutSizeFitting(UILayoutFittingCompressedSize).height ?? 70)
            var availableSize = max(tableView.bounds.width, tableView.bounds.height)

            if #available(iOS 11.0, *) {
                availableSize -= (tableView.safeAreaInsets.top + tableView.safeAreaInsets.bottom + hudHeight)
            } else {
                // 20: Status bar
                // 44: Toolbar
                availableSize -= hudHeight + 20 + 44
            }

            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                return max(106, 0.37 * availableSize)
            case .iob, .dose, .cob:
                return max(106, 0.21 * availableSize)
            }
        case .hud, .status:
            return UITableViewAutomaticDimension
        case .treatment:
            return 70 // UITableViewAutomaticDimension
        case .meal:
            return 120  //UITableViewAutomaticDimension
            /*
             if let mi = self.mealInformation, let lastEntry = mi.lastCarbEntry, lastEntry.foodPicks().picks.count > 0 {
             
             return 120
             } else {
             return 70
             }
             */
        case .detached:
            return 70 // UITableViewAutomaticDimension
        case .glucose:
            return 70 // UITableViewAutomaticDimension
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            if expertMode {
                switch ChartRow(rawValue: indexPath.row)! {
                case .glucose:
                    performSegue(withIdentifier: PredictionTableViewController.className, sender: indexPath)
                case .iob, .dose:
                    performSegue(withIdentifier: InsulinDeliveryTableViewController.className, sender: indexPath)
                case .cob:
                    performSegue(withIdentifier: CarbAbsorptionViewController.className, sender: indexPath)
                }
            }
        case .status:
            switch StatusRow(rawValue: indexPath.row)! {
            case .status:
                tableView.deselectRow(at: indexPath, animated: true)

                if case .recommendedTempBasal(tempBasal: let tempBasal, at: let date, enacting: let enacting) = statusRowMode, !enacting {
                    self.updateHUDandStatusRows(statusRowMode: .recommendedTempBasal(tempBasal: tempBasal, at: date, enacting: true), newSize: nil, animated: true)

                    self.deviceManager.loopManager.enactRecommendedTempBasal { (error) in
                        DispatchQueue.main.async {
                            self.updateHUDandStatusRows(statusRowMode: .hidden, newSize: nil, animated: true)

                            if let error = error {
                                self.deviceManager.logger.addError(error, fromSource: "TempBasal")
                                self.presentAlertController(with: error)
                            } else {
                                self.refreshContext.update(with: .status)
                                self.log.debug("[reloadData] after manually enacting temp basal")
                                self.reloadData()
                            }
                        }
                    }
                }
            }
        case .hud:
            break
        case .treatment:
            tableView.deselectRow(at: indexPath, animated: true)
            
            // clear bolus if in last/failed state
            if let pending = self.treatmentInformation {
                switch(pending.state) {
                case .recommended:
                    if pending.units > 0 {
                        if !deviceManager.loopManager.settings.bolusEnabled {
                            deviceManager.enactBolus(units: pending.units ) { (_) in
                                DispatchQueue.main.async {
                                    self.bolusState = nil
                                }
                            }
                            // TODO(Erik) This needs to be queued properly
                            self.treatmentDisplayDismissed = true
                            self.treatmentInformation = nil
                        } else {
                            performSegue(withIdentifier: BolusViewController.className, sender: indexPath)
                        }
                    } else if pending.carbs > 0 {
                        performSegue(withIdentifier: QuickCarbEntryViewController.className, sender: indexPath)
                        //performSegue(withIdentifier: "CarbEntryEditViewController", sender: indexPath)
                    }
                case .failed:
                    self.treatmentDisplayDismissed = true
                    self.treatmentInformation = nil
                    performSegue(withIdentifier: BolusViewController.className, sender: indexPath)
                case .timeout:
                    self.treatmentDisplayDismissed = true
                    self.treatmentInformation = nil
                    performSegue(withIdentifier: BolusViewController.className, sender: indexPath)
                case .success:
                    self.treatmentDisplayDismissed = true
                    self.treatmentInformation = nil
                default:
                    _ = true
                }
            }
            
            DispatchQueue.main.async {
                //self.needsRefresh = true
                self.reloadData()
            }
            break
        case .meal:
            tableView.deselectRow(at: indexPath, animated: true)
        case .detached:
            tableView.deselectRow(at: indexPath, animated: true)
            deviceManager.loopManager.disablePumpDetachedMode()
            // TODO this should use a callback
            DispatchQueue.main.async {
                //self.needsRefresh = true
                self.reloadData()
            }
        case .glucose:
            tableView.deselectRow(at: indexPath, animated: true)
            performSegue(withIdentifier: "QuickCarbEntryViewController", sender: indexPath)
        }
    }

    // MARK: - Actions

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)

        var targetViewController = segue.destination

        if let navVC = targetViewController as? UINavigationController, let topViewController = navVC.topViewController {
            targetViewController = topViewController
        }

        switch targetViewController {
        case let vc as CarbAbsorptionViewController:
            vc.deviceManager = deviceManager
            vc.hidesBottomBarWhenPushed = true
        case let vc as CarbEntryTableViewController:
            vc.carbStore = deviceManager.loopManager.carbStore
            vc.hidesBottomBarWhenPushed = true
        case let vc as CarbEntryEditViewController:
            vc.defaultAbsorptionTimes = deviceManager.loopManager.carbStore.defaultAbsorptionTimes
            vc.preferredUnit = deviceManager.loopManager.carbStore.preferredUnit
        case let vc as InsulinDeliveryTableViewController:
            vc.doseStore = deviceManager.loopManager.doseStore
            vc.hidesBottomBarWhenPushed = true
        case let vc as BolusViewController:
            vc.configureWithLoopManager(self.deviceManager.loopManager,
                recommendation: sender as? BolusRecommendation,
                glucoseUnit: self.charts.glucoseUnit,
                expertMode: self.expertMode
            )
        case let vc as PredictionTableViewController:
            vc.deviceManager = deviceManager
        case let vc as SettingsTableViewController:
            vc.dataManager = deviceManager
        case let vc as NewFoodPickerViewController:
            foodManager?.updatePopular()
            vc.foodManager = foodManager
        case let vc as QuickCarbEntryViewController:
            vc.carbStore = deviceManager.loopManager.carbStore
            vc.preferredGlucoseUnit = self.charts.glucoseUnit
            vc.shouldShowGlucose = self.validGlucose == nil
            vc.automatedBolusEnabled = deviceManager.loopManager.settings.bolusEnabled
        default:
            break
        }
    }

    /// Unwind segue action from the CarbEntryEditViewController
    ///
    /// - parameter segue: The unwind segue
    @IBAction func unwindFromEditing(_ segue: UIStoryboardSegue) {
        guard let carbVC = segue.source as? CarbEntryEditViewController, let updatedEntry = carbVC.updatedCarbEntry else {
            return
        }
        updateCarbEntry(updatedEntry: updatedEntry)
    }
    
    func updateCarbEntry(updatedEntry: NewCarbEntry) {
        deviceManager.loopManager.addCarbEntryAndRecommendBolus(updatedEntry) { (result) -> Void in
            DispatchQueue.main.async {
                switch result {
                case .success(let recommendation):
                    if self.active && self.visible, let bolus = recommendation?.amount, bolus > 0 {
                        if self.bolusState == nil {
                            self.bolusState = .recommended
                        }
                        if !self.deviceManager.loopManager.settings.bolusEnabled {
                            // TOOD(Erik): With no glucose but pump information we should still propose
                            //             a bolus based on the amount of carbs.
                            if let ti = self.treatmentInformation, ti.allowed {
                                self.performSegue(withIdentifier: BolusViewController.className, sender: recommendation)
                            }
                        }
                    }
                case .failure(let error):
                    // Ignore bolus wizard errors
                    if error is CarbStore.CarbStoreError {
                        self.presentAlertController(with: error)
                    } else {
                        self.deviceManager.logger.addError(error, fromSource: "Bolus")
                    }
                }
            }
        }
    }

    @IBAction func unwindFromBolusViewController(_ segue: UIStoryboardSegue) {
        if let bolusViewController = segue.source as? BolusViewController {
            guard let ti = treatmentInformation, ti.allowed else {
                
                //self.presentAlertController(
                self.bolusState = nil
                return
            }
                
            if let bolus = bolusViewController.bolus, bolus > 0 {
                self.bolusState = .enacting
                deviceManager.enactBolus(units: bolus) { (_) in
                    DispatchQueue.main.async {
                        self.bolusState = nil
                    }
                }
            } else {
                self.bolusState = nil
            }
        }
    }

    @IBAction func unwindFromSettings(_ segue: UIStoryboardSegue) {
    }

    private func createPreMealButtonItem(selected: Bool) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage.preMealImage(selected: selected), style: .plain, target: self, action: #selector(togglePreMealMode(_:)))
        item.accessibilityLabel = NSLocalizedString("Pre-Meal Targets", comment: "The label of the pre-meal mode toggle button")

        if selected {
            item.accessibilityTraits = item.accessibilityTraits | UIAccessibilityTraitSelected
            item.accessibilityHint = NSLocalizedString("Disables", comment: "The action hint of the workout mode toggle button when enabled")
        } else {
            item.accessibilityHint = NSLocalizedString("Enables", comment: "The action hint of the workout mode toggle button when disabled")
        }

        item.tintColor = UIColor.COBTintColor

        return item
    }

    private func createWorkoutButtonItem(selected: Bool) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage.workoutImage(selected: selected), style: .plain, target: self, action: #selector(toggleWorkoutMode(_:)))
        item.accessibilityLabel = NSLocalizedString("Workout Targets", comment: "The label of the workout mode toggle button")

        if selected {
            item.accessibilityTraits = item.accessibilityTraits | UIAccessibilityTraitSelected
            item.accessibilityHint = NSLocalizedString("Disables", comment: "The action hint of the workout mode toggle button when enabled")
        } else {
            item.accessibilityHint = NSLocalizedString("Enables", comment: "The action hint of the workout mode toggle button when disabled")
        }

        item.tintColor = UIColor.glucoseTintColor

        return item
    }

    @IBAction func togglePreMealMode(_ sender: UIBarButtonItem) {
        if preMealMode == true {
            deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.clearOverride(matching: .preMeal)
        } else {
            _ = self.deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.setOverride(.preMeal, until: Date(timeIntervalSinceNow: .hours(1)))
        }
    }

    @IBAction func toggleWorkoutMode(_ sender: UIBarButtonItem) {
        if workoutMode == true {
            deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.clearOverride(matching: .workout)
        } else {
            let vc = UIAlertController(workoutDurationSelectionHandler: { (endDate, disconnect) in
                if disconnect {
                    self.deviceManager.loopManager.enablePumpDetachedMode()
                } else {
                    _ = self.deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.setOverride(.workout, until: endDate)
                    self.workoutMode = true
                }
                
            })

            present(vc, animated: true, completion: nil)
        }
    }

    // MARK: - HUDs

    @IBOutlet var hudView: HUDView? {
        didSet {
            guard let hudView = hudView, hudView != oldValue else {
                return
            }

            let statusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(showLastError(_:)))
            hudView.loopCompletionHUD.addGestureRecognizer(statusTapGestureRecognizer)
            hudView.loopCompletionHUD.accessibilityHint = NSLocalizedString("Shows last loop error", comment: "Loop Completion HUD accessibility hint")

            let glucoseTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(openCGMApp(_:)))
            hudView.glucoseHUD.addGestureRecognizer(glucoseTapGestureRecognizer)
            
            if deviceManager.cgm?.appURL != nil {
                hudView.glucoseHUD.accessibilityHint = NSLocalizedString("Launches CGM app", comment: "Glucose HUD accessibility hint")
            }

            hudView.loopCompletionHUD.stateColors = .loopStatus
            hudView.glucoseHUD.stateColors = .cgmStatus
            hudView.glucoseHUD.tintColor = .glucoseTintColor
            hudView.basalRateHUD.tintColor = .doseTintColor
            hudView.reservoirVolumeHUD.stateColors = .pumpStatus
            hudView.batteryHUD.stateColors = .pumpStatus

            refreshContext.update(with: .status)
            self.log.debug("[reloadData] after hudView loaded")
            reloadData()
        }
    }

    @objc private func showLastError(_: Any) {
        // First, check whether we have a device error after the most recent completion date
        if let deviceError = deviceManager.lastError,
            deviceError.date > (hudView?.loopCompletionHUD.lastLoopCompleted ?? .distantPast)
        {
            self.presentAlertController(with: deviceError.error)
        } else if let lastLoopError = lastLoopError {
            self.presentAlertController(with: lastLoopError)
        }
    }

    @objc private func openCGMApp(_: Any) {
        if let url = deviceManager.cgm?.appURL, UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
    
    // MODIFICATIONS
    
    // CARB / BOLUS NOTIFICATION
    private var treatmentInformation: TreatmentInformation?
    private var treatmentDisplayDismissed = false
    // what the data view currently displays
    private var displayTreatmentInformation: TreatmentInformation?

    // MANUAL GLUCOSE ENTRY
    private var validGlucose : GlucoseValue? = nil
    private var needManualGlucose : Date? = nil
    private var displayNeedManualGlucose : Date? = nil
    
    // DETACHED MODE
    private var pumpDetachedMode : Date?
    private var displayPumpDetachedMode : Date?

    // EXPERT MODE
    private var expertMode : Bool = false
    private var settingsTouchTime : Date? = nil
    @objc func toggleExpertMode(_ sender: UILongPressGestureRecognizer) {
        guard let toolbar = navigationController?.toolbar else {
            return
        }
        let location = sender.location(in: toolbar)
        let width = toolbar.frame.width
        
        if location.x > width/5 {
            if sender.state == .began {
                settingsTouchTime = Date()
            }
            if sender.state == .ended, let duration = settingsTouchTime?.timeIntervalSinceNow  {
                if abs(duration) > TimeInterval(2) {
                    expertMode = !expertMode
                    deviceManager.loopManager.addInternalNote("toggleExpertMode \(expertMode)")
                    toolbarItems![8].isEnabled = expertMode
                    if expertMode {
                        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(minutes: 30)) {
                            self.expertMode = false
                            self.toolbarItems![8].isEnabled = self.expertMode
                        }
                    }
                } else {
                    if !expertMode {
                        presentAlertController(withTitle: "Hint", message: "Press for 2 seconds to toggle expert mode.")
                    } else {
                        // performSegue(withIdentifier: SettingsTableViewController.className, sender: nil)
                    }
                }
            }
        }
    }
    
    // Notes
    @IBAction func unwindFromNoteTableViewController(_ segue: UIStoryboardSegue) {
        if let controller = segue.source as? NoteTableViewController, controller.saved {
            let note = controller.text
            deviceManager.loopManager.addNote(note)
        }
    }
    
    // QuickCarbEntry
    @IBAction func unwindFromQuickCarbEntry(_ segue: UIStoryboardSegue) {
        if let carbVC = segue.source as? QuickCarbEntryViewController, carbVC.saved {
            var foodPick : FoodPick?
            if let carbVCcarbs = carbVC.carbs {
                let carbs = carbVCcarbs.quantity.doubleValue(for: HKUnit.gram())
                let title = "QuickCarbEntry \(carbVC.noteEntered)"
                let foodItem = FoodItem(carbRatio: 1.0, portionSize: carbs, absorption: .normal, title: title)
                foodPick = FoodPick(item: foodItem, ratio: 1, date: carbVCcarbs.startDate)
            }
            handleFoodPick(foodPick, carbVC.glucose)
        }
    }
    
    private func handleFoodPick(_ foodPick : FoodPick?, _ updatedGlucose : HKQuantity?) {
        if let carbEntry = foodPick?.carbEntry {
            
            updateCarbEntry(updatedEntry: carbEntry)
        }
        
        let glucoseStore = deviceManager.loopManager.glucoseStore
            if let glucoseEntry = updatedGlucose {
                let sample = NewGlucoseSample(date: Date(), quantity: glucoseEntry, isDisplayOnly: false,
                                              syncIdentifier: UUID().uuidString, device: nil )
                glucoseStore.addGlucose(sample) { (result) in
                    switch(result) {
                    case .failure(let error):
                        NSLog("handleFoodPick: addGlucose error \(error as Any)")
                    case .success(let sample):
                        NSLog("handleFoodPick: success \(sample)")
                    }
                }
                let g = Int(glucoseEntry.doubleValue(for: HKUnit.milligramsPerDeciliter))
                NSLog("handleFoodPick: Adding glucose to Nightscout \(g) mg/dl")
                deviceManager.loopManager.addBGReceived(bloodGlucose: g, comment: "Manually Entered")
            } else {
                // no glucose entry given
            }

    }
    
    @IBAction func unwindFromNewFoodPickerViewController(_ segue: UIStoryboardSegue) {
        if let controller = segue.source as? NewFoodPickerViewController, let pick = controller.foodPick {
            handleFoodPick(pick, nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // self.needsRefresh = true
                self.reloadData()
            }
        }
    }
    
    private var foodRecentCollectionViewDataSource = FoodRecentCollectionViewDataSource()
    private var displayMeal : Bool = true
    weak var foodManager: FoodManager!
    typealias MealInformation = (date: Date, lastCarbEntry: StoredCarbEntry?, picks: FoodPicks?, start: Date?, end: Date?, carbs: Double?, undoPossible: Bool)
    private var mealInformation : MealInformation?
    
    func mealTableViewCellTap(_ sender : MealTableViewCell) {
        //        performSegue(withIdentifier: FoodPickerViewController.className, sender: sender)
        performSegue(withIdentifier: NewFoodPickerViewController.className, sender: sender)
    }
    
    func mealTableViewCellImageTap(_ sender : MealTableViewCell) {
        if let mi = self.mealInformation, let lastCarbEntry = mi.lastCarbEntry, let pick = lastCarbEntry.foodPicks().last,  mi.undoPossible {
            
            let alert = UIAlertController(title: "Undo Food Selection", message: "Are you sure you want to remove the last food pick \(pick.item.title) of \(pick.displayCarbs) g carbs?", preferredStyle: .alert)
            
            
            alert.addAction(UIAlertAction(title: "Remove", style: .default, handler: { [weak alert] (_) in
                NSLog("removeLastFoodPick Alert \(alert as Any)")
                self.deviceManager.loopManager.removeCarbEntry(carbEntry: lastCarbEntry) { (error) in
                    if let err = error {
                        NSLog("removeLastFoodPick Error \(err as Any)")
                        self.presentAlertController(with: err)
                    }
                    self.reloadData()
                }
            }))
            
            alert.addAction(UIAlertAction(title: "Back", style: .cancel, handler: nil))
            self.present(alert, animated: true, completion: nil)
            
        } else {
            //            performSegue(withIdentifier: FoodPickerViewController.className, sender: sender)
            performSegue(withIdentifier: NewFoodPickerViewController.className, sender: sender)
            
        }
    }
    
    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        
        return formatter
    }()

    @objc func showNote(_ sender: UIBarButtonItem) {
        performSegue(withIdentifier: NoteTableViewController.className, sender: sender)
    }
    
    @objc func showQuickCarbEntry(_ sender: UIBarButtonItem) {
        performSegue(withIdentifier: QuickCarbEntryViewController.className, sender: sender)
    }
    
    private func createNoteButtonItem() -> UIBarButtonItem {
        let originalImage = #imageLiteral(resourceName: "pencil")
        let scaledIcon = UIImage(cgImage: originalImage.cgImage!, scale: 8, orientation: originalImage.imageOrientation)

        let item = UIBarButtonItem(image: scaledIcon, style: .plain, target: self, action: #selector(showNote(_:)))
        item.accessibilityLabel = NSLocalizedString("Note Taking", comment: "The label of the note taking button")
        
        item.tintColor = UIColor(red: 249.0/255, green: 229.0/255, blue: 0.0/255, alpha: 1.0)
        
        return item
    }
    
}
