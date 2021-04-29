//
//  StatusTableViewController.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 9/6/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import UIKit
import HealthKit
import Intents
import LoopCore
import LoopKit
import LoopKitUI
import LoopUI
import SwiftCharts
import os.log


private extension RefreshContext {
    static let all: Set<RefreshContext> = [.status, .glucose, .insulin, .carbs, .targets]
}

final class StatusTableViewController: ChartsTableViewController, MealTableViewCellDelegate {

    private let log = OSLog(category: "StatusTableViewController")

    lazy var quantityFormatter: QuantityFormatter = QuantityFormatter()

    override func viewDidLoad() {
        super.viewDidLoad()

        statusCharts.glucose.glucoseDisplayRange = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100)...HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 175)

        registerPumpManager()

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
            },
            notificationCenter.addObserver(forName: .PumpManagerChanged, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.registerPumpManager()
                    self?.configurePumpManagerHUDViews()
                }
            },
            notificationCenter.addObserver(forName: .PumpEventsAdded, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.refreshContext.update(with: .insulin)
                    self?.reloadData(animated: true)
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

        toolbarItems![2] = createNoteButtonItem()

        toolbarItems![4].accessibilityLabel = NSLocalizedString("Bolus", comment: "The label of the bolus entry button")
        toolbarItems![4].tintColor = UIColor.doseTintColor

        if #available(iOS 13.0, *) {
            toolbarItems![8].image = UIImage(systemName: "gear")
        }
        toolbarItems![8].accessibilityLabel = NSLocalizedString("Settings", comment: "The label of the settings button")
        toolbarItems![8].tintColor = UIColor.secondaryLabelColor

        let longTapGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(toggleExpertMode(_:)))
        longTapGestureRecognizer.minimumPressDuration = 0.3

        self.navigationController?.toolbar.addGestureRecognizer(longTapGestureRecognizer)
        toolbarItems![8].isEnabled = expertMode

        tableView.register(BolusProgressTableViewCell.nib(), forCellReuseIdentifier: BolusProgressTableViewCell.className)

        addScenarioStepGestureRecognizers()
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

        updateBolusProgress()
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

        onscreen = true

        AnalyticsManager.shared.didDisplayStatusScreen()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        onscreen = false

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
        didSet {
            hudView?.loopCompletionHUD.assertTimer(active)
            updateHUDActive()
        }
    }

    // This is similar to the visible property, but is set later, on viewDidAppear, to be
    // suitable for animations that should be seen in their entirety.
    var onscreen: Bool = false {
        didSet {
            updateHUDActive()
        }
    }

    private var bolusState = PumpManagerStatus.BolusState.none {
        didSet {
            if oldValue != bolusState {
                // Bolus starting
                if case .inProgress = bolusState {
                    self.bolusProgressReporter = self.deviceManager.pumpManager?.createBolusProgressReporter(reportingOn: DispatchQueue.main)
                }
                refreshContext.update(with: .status)
                self.reloadData(animated: true)
            }
        }
    }

    private var bolusProgressReporter: DoseProgressReporter?

    private func updateBolusProgress() {
        if let cell = tableView.cellForRow(at: IndexPath(row: StatusRow.status.rawValue, section: Section.status.rawValue)) as? BolusProgressTableViewCell {
            cell.deliveredUnits = bolusProgressReporter?.progress.deliveredUnits
        }
    }

    private func updateHUDActive() {
        deviceManager.pumpManagerHUDProvider?.visible = active && onscreen
    }
    
    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState = .active(Date()) {
        didSet {
            if oldValue != basalDeliveryState {
                log.debug("New basalDeliveryState: %@", String(describing: basalDeliveryState))
                refreshContext.update(with: .status)
                self.reloadData(animated: true)
            }
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

    private var shouldShowOverride: Bool {
        return !landscapeMode && overrideRowMode.hasRow
    }

    private var shouldShowNeedManualGlucose: Bool {
        return !landscapeMode && (displayNeedManualGlucose != nil)
    }

    private var shouldShowMeal: Bool {
        return !landscapeMode
    }

    override func glucoseUnitDidChange() {
        refreshContext = RefreshContext.all
    }

    private func registerPumpManager() {
        if let pumpManager = deviceManager.pumpManager {
            self.basalDeliveryState = pumpManager.status.basalDeliveryState
            pumpManager.removeStatusObserver(self)
            pumpManager.addStatusObserver(self, queue: .main)
        }
    }

    private lazy var statusCharts = StatusChartsManager(colors: .default, settings: .default, traitCollection: self.traitCollection)

    override func createChartsManager() -> ChartsManager {
        return statusCharts
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

        if case .bolusing = statusRowMode, bolusProgressReporter?.progress.isComplete == true {
            refreshContext.update(with: .status)
        }

        if visible && active {
            bolusProgressReporter?.addObserver(self)
        } else {
            bolusProgressReporter?.removeObserver(self)
        }

        guard active && visible && !refreshContext.isEmpty else {
            return
        }

        log.debug("Reloading data with context: %@", String(describing: refreshContext))

        let currentContext = refreshContext
        var retryContext: Set<RefreshContext> = []
        self.refreshContext = []
        reloading = true

        let reloadGroup = DispatchGroup()
        var newRecommendedTempBasal: (recommendation: AutomaticDoseRecommendation, date: Date)?
        var newManualBolusRecommendation: (recommendation: ManualBolusRecommendation, date: Date)?
        var glucoseValues: [StoredGlucoseSample]?
        var predictedGlucoseValues: [GlucoseValue]?
        var iobValues: [InsulinValue]?
        var doseEntries: [DoseEntry]?
        var totalDelivery: Double?
        var cobValues: [CarbValue]?
        let startDate = charts.startDate
        let basalDeliveryState = self.basalDeliveryState

        // TODO: Don't always assume currentContext.contains(.status)
        reloadGroup.enter()
        self.deviceManager.loopManager.getLoopState { (manager, state) -> Void in
            predictedGlucoseValues = state.predictedGlucoseIncludingPendingInsulin ?? []

            // Retry this refresh again if predicted glucose isn't available
            if state.predictedGlucose == nil {
                retryContext.update(with: .status)
            }

            /// Update the status HUDs immediately
            let lastLoopCompleted = manager.lastLoopCompleted
            let lastLoopError = state.error

            // Net basal rate HUD
            let netBasal: NetBasal?
            if let basalSchedule = manager.basalRateScheduleApplyingOverrideHistory {
                netBasal = basalDeliveryState.getNetBasal(basalSchedule: basalSchedule, settings: manager.settings)
            } else {
                netBasal = nil
            }
            self.log.debug("Update net basal to %{public}@", String(describing: netBasal))

            DispatchQueue.main.async {
                self.hudView?.loopCompletionHUD.dosingEnabled = manager.settings.dosingEnabled
                self.lastLoopError = lastLoopError

                if let netBasal = netBasal {
                    self.hudView?.basalRateHUD.setNetBasalRate(netBasal.rate, percent: netBasal.percent, at: netBasal.start)
                }


            }

            // Display a recommended basal change only if we haven't completed recently, or we're in open-loop mode
            if lastLoopCompleted == nil ||
                lastLoopCompleted! < Date(timeIntervalSinceNow: .minutes(-6)) ||
                !manager.settings.dosingEnabled
            {
                newRecommendedTempBasal = state.recommendedAutomaticDose
            }

            newManualBolusRecommendation = state.recommendedBolus

            if currentContext.contains(.carbs) {
                reloadGroup.enter()
                manager.carbStore.getCarbsOnBoardValues(start: startDate, effectVelocities: manager.settings.dynamicCarbAbsorptionEnabled ? state.insulinCounteractionEffects : nil) { (values) in
                    DispatchQueue.main.async {
                        cobValues = values
                        reloadGroup.leave()
                    }
                }
            }

            self.validGlucose = state.validGlucose
            if let _ = self.validGlucose {
                self.needManualGlucose = nil
            } else {
                self.needManualGlucose = Date()
            }

            self.updateMealInformation(reloadGroup, manager.carbStore)

            reloadGroup.leave()
        }

        if currentContext.contains(.glucose) {
            reloadGroup.enter()
            self.deviceManager.loopManager.glucoseStore.getCachedGlucoseSamples(start: startDate) { (values) -> Void in
                DispatchQueue.main.async {
                    glucoseValues = values
                    reloadGroup.leave()
                }
            }
        }

        if currentContext.contains(.insulin) {
            reloadGroup.enter()
            deviceManager.loopManager.doseStore.getInsulinOnBoardValues(start: startDate) { (result) -> Void in
                DispatchQueue.main.async {
                    switch result {
                    case .failure(let error):
                        self.log.error("DoseStore failed to get insulin on board values: %{public}@", String(describing: error))
                        retryContext.update(with: .insulin)
                        iobValues = []
                    case .success(let values):
                        iobValues = values
                    }
                    reloadGroup.leave()
                }
            }

            reloadGroup.enter()
            deviceManager.loopManager.doseStore.getNormalizedDoseEntries(start: startDate) { (result) -> Void in
                DispatchQueue.main.async {
                    switch result {
                    case .failure(let error):
                        self.log.error("DoseStore failed to get normalized dose entries: %{public}@", String(describing: error))
                        retryContext.update(with: .insulin)
                        doseEntries = []
                    case .success(let doses):
                        doseEntries = doses
                    }
                    reloadGroup.leave()
                }
            }

            reloadGroup.enter()
            deviceManager.loopManager.doseStore.getTotalUnitsDelivered(since: Calendar.current.startOfDay(for: Date())) { (result) in
                DispatchQueue.main.async {
                    switch result {
                    case .failure:
                        retryContext.update(with: .insulin)
                        totalDelivery = nil
                    case .success(let total):
                        totalDelivery = total.value
                    }

                    reloadGroup.leave()
                }
            }
        }

        if deviceManager.loopManager.settings.preMealTargetRange == nil {
            preMealMode = nil
        } else {
            preMealMode = deviceManager.loopManager.settings.preMealTargetEnabled()
        }

        if !FeatureFlags.sensitivityOverridesEnabled, deviceManager.loopManager.settings.legacyWorkoutTargetRange == nil {
            workoutMode = nil
        } else {
            workoutMode = deviceManager.loopManager.settings.nonPreMealOverrideEnabled()
        }

        reloadGroup.notify(queue: .main) {
            /// Update the chart data

            // Glucose
            if let glucoseValues = glucoseValues {
                self.statusCharts.setGlucoseValues(glucoseValues)
            }
            if let predictedGlucoseValues = predictedGlucoseValues {
                self.statusCharts.setPredictedGlucoseValues(predictedGlucoseValues)
            }
            if let lastPoint = self.statusCharts.glucose.predictedGlucosePoints.last?.y {
                self.eventualGlucoseDescription = String(describing: lastPoint)
            } else {
                self.eventualGlucoseDescription = nil
            }
            if currentContext.contains(.targets) {
                self.statusCharts.targetGlucoseSchedule = self.deviceManager.loopManager.settings.glucoseTargetRangeSchedule
                self.statusCharts.scheduleOverride = self.deviceManager.loopManager.settings.scheduleOverride
            }
            if self.statusCharts.scheduleOverride?.hasFinished() == true {
                self.statusCharts.scheduleOverride = nil
            }

            let charts = self.statusCharts

            // Active Insulin
            if let iobValues = iobValues {
                charts.setIOBValues(iobValues)
            }

            // Show the larger of the value either before or after the current date
            if let maxValue = charts.iob.iobPoints.allElementsAdjacent(to: Date()).max(by: {
                return $0.y.scalar < $1.y.scalar
            }) {
                self.currentIOBDescription = String(describing: maxValue.y)
            } else {
                self.currentIOBDescription = nil
            }

            // Insulin Delivery
            if let doseEntries = doseEntries {
                charts.setDoseEntries(doseEntries)
            }
            if let totalDelivery = totalDelivery {
                self.totalDelivery = totalDelivery
            }

            // Active Carbohydrates
            if let cobValues = cobValues {
                charts.setCOBValues(cobValues)
            }
            if let index = charts.cob.cobPoints.closestIndex(priorTo: 	Date()) {
                self.currentCOBDescription = String(describing: charts.cob.cobPoints[index].y)
            } else {
                self.currentCOBDescription = nil
            }

            self.tableView.beginUpdates()
            if let hudView = self.hudView {
                // Glucose HUD
                if let glucose = self.deviceManager.loopManager.glucoseStore.latestGlucose {
                    let unit = self.statusCharts.glucose.glucoseUnit
                    hudView.glucoseHUD.setGlucoseQuantity(glucose.quantity.doubleValue(for: unit),
                        at: glucose.startDate,
                        unit: unit,
                        staleGlucoseAge: self.deviceManager.loopManager.settings.inputDataRecencyInterval,
                        sensor: self.deviceManager.sensorState
                    )
                }
            }

            // Show/hide the table view rows
            let statusRowMode = self.determineStatusRowMode(recommendedDose: newRecommendedTempBasal,
                                                            manualBolus: newManualBolusRecommendation)

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
        case status
        case override
        case glucose // Glucose not available reminder
        case meal   // Meal Information
        case charts

        static let count = 6
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
        case recommendedDose(dose: AutomaticDoseRecommendation, at: Date, enacting: Bool)
        case manualBolus(dose: ManualBolusRecommendation, at: Date)
        case manualCarbs(dose: ManualBolusRecommendation, at: Date)
        case scheduleOverrideEnabled(TemporaryScheduleOverride)
        case enactingBolus
        case bolusing(dose: DoseEntry)
        case cancelingBolus
        case pumpSuspended(resuming: Bool)

        var hasRow: Bool {
            switch self {
            case .hidden:
                return false
            default:
                return true
            }
        }
    }

    private var statusRowMode = StatusRowMode.hidden

    private var overrideRowMode = StatusRowMode.hidden

    private func determineStatusRowMode(
        recommendedDose: (recommendation: AutomaticDoseRecommendation, date: Date)? = nil,
        manualBolus: (recommendation: ManualBolusRecommendation, date: Date)? = nil
        ) -> StatusRowMode {
        let statusRowMode: StatusRowMode
        if case .initiating = bolusState {
            statusRowMode = .enactingBolus
        } else if case .canceling = bolusState {
            statusRowMode = .cancelingBolus
        } else if case .suspended = basalDeliveryState {
            statusRowMode = .pumpSuspended(resuming: false)
        } else if self.basalDeliveryState == .resuming {
            statusRowMode = .pumpSuspended(resuming: true)
        } else if case .inProgress(let dose) = bolusState, dose.endDate.timeIntervalSinceNow > 0 {
            statusRowMode = .bolusing(dose: dose)
        } else if let (recommendation: dose, date: date) = recommendedDose, dose.bolusUnits > 0 || dose.basalAdjustment != nil {
            statusRowMode = .recommendedDose(dose: dose, at: date, enacting: false)
        } else if let (recommendation: dose, date: date) = manualBolus, dose.amount > 0 {
            statusRowMode = .manualBolus(dose: dose, at: date)
        } else if let (recommendation: dose, date: date) = manualBolus, dose.carbs > 0 {
            statusRowMode = .manualCarbs(dose: dose, at: date)
        } else {
            statusRowMode = .hidden
        }

        return statusRowMode
    }

    private func determineOverrideRowMode() -> StatusRowMode {
        if let scheduleOverride = deviceManager.loopManager.settings.scheduleOverride,
            scheduleOverride.context != .preMeal && scheduleOverride.context != .legacyWorkout,
            !scheduleOverride.hasFinished()
        {
            return .scheduleOverrideEnabled(scheduleOverride)
        } else {
            return .hidden
        }
    }

    private func updateHUDandStatusRows(statusRowMode: StatusRowMode, newSize: CGSize?, animated: Bool) {
        let hudWasVisible = self.shouldShowHUD
        let statusWasVisible = self.shouldShowStatus
        let overrideWasVisible = self.shouldShowOverride
        let mealWasVisible = self.shouldShowMeal

        let glucoseWasVisible = self.shouldShowNeedManualGlucose

        let oldStatusRowMode = self.statusRowMode
        let oldOverrideRowMode = self.overrideRowMode

        self.overrideRowMode = determineOverrideRowMode()
        self.statusRowMode = statusRowMode

        let oldNeedManualGlucose = self.displayNeedManualGlucose
        let newNeedManualGlucose = self.needManualGlucose
        self.displayNeedManualGlucose = newNeedManualGlucose

        if let newSize = newSize {
            self.landscapeMode = newSize.width > newSize.height
        }

        let hudIsVisible = self.shouldShowHUD
        let statusIsVisible = self.shouldShowStatus
        let overrideIsVisible = self.shouldShowOverride
        let glucoseIsVisible = self.shouldShowNeedManualGlucose
        let mealIsVisible = self.shouldShowMeal // influenced by landscape mode

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
            case (.recommendedDose(dose: let oldDose, at: let oldDate, enacting: let wasEnacting),
                  .recommendedDose(dose: let newDose, at: let newDate, enacting: let isEnacting)):
                // Ensure we have a change
                guard oldDose != newDose || oldDate != newDate || wasEnacting != isEnacting else {
                    break
                }

                // If the rate or date change, reload the row
                if oldDose != newDose || oldDate != newDate {
                    self.tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
                } else if let cell = tableView.cellForRow(at: statusIndexPath) {
                    // If only the enacting state changed, update the activity indicator
                    if isEnacting {
                        let indicatorView = UIActivityIndicatorView(style: .default)
                        indicatorView.startAnimating()
                        cell.accessoryView = indicatorView
                    } else {
                        cell.accessoryView = nil
                    }
                }
            case (.manualBolus(dose: let oldDose, at: let oldDate),
                  .manualBolus(dose: let newDose, at: let newDate)):
                // Ensure we have a change
                guard oldDose != newDose || oldDate != newDate else {
                    break
                }

                // If the rate or date change, reload the row
                if oldDose != newDose || oldDate != newDate {
                    self.tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
                }
            case (.manualCarbs(dose: let oldDose, at: let oldDate),
                  .manualCarbs(dose: let newDose, at: let newDate)):
                // Ensure we have a change
                guard oldDose != newDose || oldDate != newDate else {
                    break
                }

                // If the rate or date change, reload the row
                if oldDose != newDose || oldDate != newDate {
                    self.tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
                }
            case (.enactingBolus, .enactingBolus):
                break
            case (.bolusing(let oldDose), .bolusing(let newDose)):
                if oldDose != newDose {
                    self.tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
                }
            case (.pumpSuspended(resuming: let wasResuming), .pumpSuspended(resuming: let isResuming)):
                if isResuming != wasResuming {
                    self.tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
                }
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

        let overrideIndexPath = IndexPath(row: StatusRow.status.rawValue, section: Section.override.rawValue)
        switch (overrideWasVisible, overrideIsVisible) {
        case (true, true):
            switch (oldOverrideRowMode, self.overrideRowMode) {
            case (.scheduleOverrideEnabled(let oldScheduleOverride), .scheduleOverrideEnabled(let newScheduleOverride)):
                if oldScheduleOverride != newScheduleOverride {
                    self.tableView.reloadRows(at: [overrideIndexPath], with: animated ? .fade : .none)
                }
            default:
                // Should not happen as the row does not show up in this case.
                self.tableView.reloadRows(at: [overrideIndexPath], with: animated ? .fade : .none)
            }
        case (false, true):
            self.tableView.insertRows(at: [overrideIndexPath], with: animated ? .top : .none)
        case (true, false):
            self.tableView.deleteRows(at: [overrideIndexPath], with: animated ? .top : .none)
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

            if let preMealMode = preMealMode {
                toolbarItems![2] = createPreMealButtonItem(selected: preMealMode)
            } else {
                toolbarItems![2].isEnabled = false
            }
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
        case .override:
            return shouldShowOverride ? StatusRow.count : 0
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
                    return self?.statusCharts.glucoseChart(withFrame: frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Glucose", comment: "The title of the glucose and prediction graph")
            case .iob:
                cell.chartContentView.chartGenerator = { [weak self] (frame) in
                    return self?.statusCharts.iobChart(withFrame: frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Active Insulin", comment: "The title of the Insulin On-Board graph")
            case .dose:
                cell.chartContentView?.chartGenerator = { [weak self] (frame) in
                    return self?.statusCharts.doseChart(withFrame: frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Insulin Delivery", comment: "The title of the insulin delivery graph")
            case .cob:
                cell.chartContentView?.chartGenerator = { [weak self] (frame) in
                    return self?.statusCharts.cobChart(withFrame: frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Active Carbohydrates", comment: "The title of the Carbs On-Board graph")
            }

            self.tableView(tableView, updateSubtitleFor: cell, at: indexPath)

            let alpha: CGFloat = charts.gestureRecognizer?.state == .possible ? 1 : 0
            cell.titleLabel?.alpha = alpha
            cell.subtitleLabel?.alpha = alpha

            cell.subtitleLabel?.textColor = UIColor.secondaryLabelColor

            return cell
        case .status, .override:

            func getTitleSubtitleCell() -> TitleSubtitleTableViewCell {
                let cell = tableView.dequeueReusableCell(withIdentifier: TitleSubtitleTableViewCell.className, for: indexPath) as! TitleSubtitleTableViewCell
                cell.selectionStyle = .none
                return cell
            }

            switch StatusRow(rawValue: indexPath.row)! {
            case .status:
                let rowMode = Section(rawValue: indexPath.section)! == .status ? statusRowMode : overrideRowMode
                switch rowMode {
                case .hidden:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = nil
                    cell.subtitleLabel?.text = nil
                    cell.accessoryView = nil
                    return cell
                case .recommendedDose(dose: let dose, at: let date, enacting: let enacting):
                    let cell = getTitleSubtitleCell()
                    let timeFormatter = DateFormatter()
                    timeFormatter.dateStyle = .none
                    timeFormatter.timeStyle = .short

                    //cell.titleLabel.text = NSLocalizedString("Recommended Dose", comment: "The title of the cell displaying a recommended dose")
                    
                    var text: String

                    if let basalAdjustment = dose.basalAdjustment, dose.bolusUnits == 0 {
                        cell.titleLabel.text = NSLocalizedString("Recommended Basal", comment: "The title of the cell displaying a recommended temp basal value")
                        text = String(format: NSLocalizedString("%1$@ U/h", comment: "The format for recommended temp basal rate and time. (1: localized rate number)"), NumberFormatter.localizedString(from: NSNumber(value: basalAdjustment.unitsPerHour), number: .decimal))
                    } else {
                        let bolusUnitsStr = quantityFormatter.string(from: HKQuantity(unit: .internationalUnit(), doubleValue: dose.bolusUnits), for: .internationalUnit()) ?? ""
                        cell.titleLabel.text = NSLocalizedString("Recommended Auto-Bolus", comment: "The title of the cell displaying a recommended automatic bolus value")
                        text = String(format: NSLocalizedString("%1$@ ", comment: "The format for recommended bolus string.  (1: localized bolus volume)" ), bolusUnitsStr)
                    }
                    text += String(format: NSLocalizedString(" @ %1$@", comment: "The format for dose recommendation time. (1: localized time)"), timeFormatter.string(from: date))
                    
                    cell.subtitleLabel.text = text

                    cell.selectionStyle = .default

                    if enacting {
                        let indicatorView = UIActivityIndicatorView(style: .default)
                        indicatorView.startAnimating()
                        cell.accessoryView = indicatorView
                    } else {
                        cell.accessoryView = nil
                    }
                    return cell
                case .manualBolus(dose: let dose, at: let date):
                    let cell = getTitleSubtitleCell()
                    let timeFormatter = DateFormatter()
                    timeFormatter.dateStyle = .none
                    timeFormatter.timeStyle = .short

                    var text: String

                    let bolusUnitsStr = quantityFormatter.string(from: HKQuantity(unit: .internationalUnit(), doubleValue: dose.amount), for: .internationalUnit()) ?? ""
                        cell.titleLabel.text = NSLocalizedString("Recommended Manual-Bolus", comment: "The title of the cell displaying a recommended manual bolus value")
                        text = String(format: NSLocalizedString("%1$@ ", comment: "The format for recommended bolus string.  (1: localized bolus volume)" ), bolusUnitsStr)

                    text += String(format: NSLocalizedString(" @ %1$@", comment: "The format for dose recommendation time. (1: localized time)"), timeFormatter.string(from: date))

                    cell.subtitleLabel.text = text

                    cell.selectionStyle = .default

                    cell.accessoryView = nil
                    return cell
                case .manualCarbs(dose: let dose, at: let date):
                    let cell = getTitleSubtitleCell()
                    let timeFormatter = DateFormatter()
                    timeFormatter.dateStyle = .none
                    timeFormatter.timeStyle = .short

                    var text: String

                    let carbUnitsStr = quantityFormatter.string(from: HKQuantity(unit: HKUnit.gram(), doubleValue: dose.carbs), for: HKUnit.gram()) ?? ""
                        cell.titleLabel.text = NSLocalizedString("Recommended Carbs", comment: "The title of the cell displaying a recommended carb amount")
                        text = String(format: NSLocalizedString("%1$@ ", comment: "The format for recommended carb string.  (1: localized carb amount)" ), carbUnitsStr)

                    text += String(format: NSLocalizedString(" @ %1$@", comment: "The format for dose recommendation time. (1: localized time)"), timeFormatter.string(from: date))

                    cell.subtitleLabel.text = text

                    cell.selectionStyle = .default

                    cell.accessoryView = nil
                    return cell
                case .scheduleOverrideEnabled(let override):
                    let cell = getTitleSubtitleCell()
                    switch override.context {
                    case .preMeal, .legacyWorkout:
                        assertionFailure("Pre-meal and legacy workout modes should not produce status rows")
                    case .preset(let preset):
                        cell.titleLabel.text = String(format: NSLocalizedString("%@ %@", comment: "The format for an active override preset. (1: preset symbol)(2: preset name)"), preset.symbol, preset.name)
                    case .custom:
                        switch override.enactTrigger {
                        case .autosense:
                            cell.titleLabel.text = NSLocalizedString("Autosense", comment: "The title of the cell indicating a autosense temporary override is enabled")
                        default:
                            cell.titleLabel.text = NSLocalizedString("Custom Override", comment: "The title of the cell indicating a generic temporary override is enabled")
                        }
                    }

                    if override.isActive() {
                        switch override.duration {
                        case .finite:
                            let endTimeText = DateFormatter.localizedString(from: override.activeInterval.end, dateStyle: .none, timeStyle: .short)
                            cell.subtitleLabel.text = String(format: NSLocalizedString("until %@", comment: "The format for the description of a temporary override end date"), endTimeText)
                        case .indefinite:
                            cell.subtitleLabel.text = nil
                        }
                    } else {
                        let startTimeText = DateFormatter.localizedString(from: override.startDate, dateStyle: .none, timeStyle: .short)
                        cell.subtitleLabel.text = String(format: NSLocalizedString("starting at %@", comment: "The format for the description of a temporary override start date"), startTimeText)
                    }

                    cell.accessoryView = nil
                    return cell
                case .enactingBolus:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Starting Bolus", comment: "The title of the cell indicating a bolus is being sent")
                    cell.subtitleLabel.text = nil

                    let indicatorView = UIActivityIndicatorView(style: .default)
                    indicatorView.startAnimating()
                    cell.accessoryView = indicatorView
                    return cell
                case .bolusing(let dose):
                    let progressCell = tableView.dequeueReusableCell(withIdentifier: BolusProgressTableViewCell.className, for: indexPath) as! BolusProgressTableViewCell
                    progressCell.selectionStyle = .none
                    progressCell.totalUnits = dose.programmedUnits
                    progressCell.tintColor = .doseTintColor
                    progressCell.unit = HKUnit.internationalUnit()
                    progressCell.deliveredUnits = bolusProgressReporter?.progress.deliveredUnits
                    return progressCell
                case .cancelingBolus:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Canceling Bolus", comment: "The title of the cell indicating a bolus is being canceled")
                    cell.subtitleLabel.text = nil

                    let indicatorView = UIActivityIndicatorView(style: .default)
                    indicatorView.startAnimating()
                    cell.accessoryView = indicatorView
                    return cell
                    
                case .pumpSuspended(let resuming):
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Pump Suspended", comment: "The title of the cell indicating the pump is suspended")

                    if resuming {
                        let indicatorView = UIActivityIndicatorView(style: .default)
                        indicatorView.startAnimating()
                        cell.accessoryView = indicatorView
                        cell.subtitleLabel.text = nil
                    } else {
                        cell.accessoryView = nil
                        cell.subtitleLabel.text = NSLocalizedString("Tap to Resume", comment: "The subtitle of the cell displaying an action to resume insulin delivery")
                    }
                    cell.selectionStyle = .default
                    return cell
                }
            }

            case .meal:
                let cell = tableView.dequeueReusableCell(withIdentifier: "MealTableViewCell", for: indexPath) as! MealTableViewCell
                //let dataSource = FoodRecentCollectionViewDataSource()

                var foodPicks = FoodPicks()

                var undoPossible = false
                if let mi = self.mealInformation /*, let mealEnd = mi.end, mealEnd.timeIntervalSinceNow > TimeInterval(minutes: -30)*/ {
                    let intcarbs = Int(mi.carbs)
                    cell.currentCarbLabel.text = "\(intcarbs) g"
                    foodPicks = mi.picks
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
                foodRecentCollectionViewDataSource.foodManager = deviceManager.foodManager
                foodRecentCollectionViewDataSource.foodPicks = foodPicks
                cell.recentFoodCollectionView.reloadData()
                cell.recentFoodCollectionView.collectionViewLayout.invalidateLayout()
                return cell

            case .glucose:
                let timeFormatter = DateFormatter()
                timeFormatter.dateStyle = .none
                timeFormatter.timeStyle = .short

                let cell = tableView.dequeueReusableCell(withIdentifier: TitleSubtitleTableViewCell.className, for: indexPath) as! TitleSubtitleTableViewCell
                cell.selectionStyle = .none
                cell.titleLabel.text = "🩸 No blood glucose!"
                if let glucoseDate = displayNeedManualGlucose {
                    cell.subtitleLabel?.text = String(format: NSLocalizedString(" @ %1$@", comment: "The format for last glucose time. (1: localized time)"), timeFormatter.string(from: glucoseDate))
                } else {
                    cell.subtitleLabel?.text = nil
                }
                cell.accessoryView = nil
                cell.selectionStyle = .default
                return cell
        }
    }
    
    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        return formatter
    }()

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
        case .override:
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
            let hudHeight = ceil(hudView?.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height ?? 70)
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
        case .hud, .status, .override, .glucose:
            return UITableView.automaticDimension
        case .meal:
            if let mi = self.mealInformation, let lastEntry = mi.lastCarbEntry, lastEntry.foodPicks().picks.count > 0 {
                return 110
            } else {
                return 70
            }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            if !expertMode {
                break
            }
            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                performSegue(withIdentifier: PredictionTableViewController.className, sender: indexPath)
            case .iob, .dose:
                performSegue(withIdentifier: InsulinDeliveryTableViewController.className, sender: indexPath)
            case .cob:
                performSegue(withIdentifier: CarbAbsorptionViewController.className, sender: indexPath)
            }
        case .status, .override:
            switch StatusRow(rawValue: indexPath.row)! {
            case .status:
                tableView.deselectRow(at: indexPath, animated: true)
                let rowMode = Section(rawValue: indexPath.section)! == .status ? statusRowMode : overrideRowMode
                switch rowMode {
                case .recommendedDose(dose: let dose, at: let date, enacting: let enacting) where !enacting:
                    self.updateHUDandStatusRows(statusRowMode: .recommendedDose(dose: dose, at: date, enacting: true), newSize: nil, animated: true)

                    self.deviceManager.loopManager.enactRecommendedDose { (error) in
                        DispatchQueue.main.async {
                            self.updateHUDandStatusRows(statusRowMode: .hidden, newSize: nil, animated: true)

                            if let error = error {
                                self.log.error("Failed to enact recommended temp basal: %{public}@", String(describing: error))
                                self.present(UIAlertController(with: error), animated: true)
                            } else {
                                self.refreshContext.update(with: .status)
                                self.log.debug("[reloadData] after manually enacting temp basal")
                                self.reloadData()
                            }
                        }
                    }
                case .manualBolus(dose: let dose, at: _):
                    //self.updateHUDandStatusRows(statusRowMode: .recommendedDose(dose: dose, at: date, enacting: true), newSize: nil, animated: true)
                    self.deviceManager.enactBolus(units: dose.amount) { (error) in
                        DispatchQueue.main.async {
                            self.updateHUDandStatusRows(statusRowMode: .hidden, newSize: nil, animated: true)
                            AnalyticsManager.shared.didToggleBluetooth("enactStatusView \(error)")
                            if let error = error {
                                self.log.error("Failed to enact recommended bolus: %{public}@", String(describing: error))
                                self.present(UIAlertController(with: error), animated: true)
                            } else {
                                self.refreshContext.update(with: .status)
                                self.log.debug("[reloadData] after manually enacting bolus")
                                self.reloadData()
                            }
                        }
                    }
                case .manualCarbs(dose: _, at: _):
                    performSegue(withIdentifier: CarbEntryViewController.className, sender: indexPath)

                case .pumpSuspended(let resuming) where !resuming:
                    self.updateHUDandStatusRows(statusRowMode: .pumpSuspended(resuming: true), newSize: nil, animated: true)
                    self.deviceManager.pumpManager?.resumeDelivery() { (error) in
                        DispatchQueue.main.async {
                            if let error = error {
                                let alert = UIAlertController(with: error, title: NSLocalizedString("Error Resuming", comment: "The alert title for a resume error"))
                                self.present(alert, animated: true, completion: nil)
                                if case .suspended = self.basalDeliveryState {
                                    self.updateHUDandStatusRows(statusRowMode: .pumpSuspended(resuming: false), newSize: nil, animated: true)
                                }
                            } else {
                                self.updateHUDandStatusRows(statusRowMode: self.determineStatusRowMode(), newSize: nil, animated: true)
                                self.refreshContext.update(with: .insulin)
                                self.log.debug("[reloadData] after manually resuming suspend")
                                self.reloadData()
                            }
                        }
                    }
                case .scheduleOverrideEnabled(let override):
                    let vc = AddEditOverrideTableViewController(glucoseUnit: statusCharts.glucose.glucoseUnit)
                    vc.inputMode = .editOverride(override)
                    vc.delegate = self
                    show(vc, sender: tableView.cellForRow(at: indexPath))
                case .bolusing:
                    self.updateHUDandStatusRows(statusRowMode: .cancelingBolus, newSize: nil, animated: true)
                    self.deviceManager.pumpManager?.cancelBolus() { (result) in
                        DispatchQueue.main.async {
                            switch result {
                            case .success:
                                // show user confirmation and actual delivery amount?
                                break
                            case .failure(let error):
                                let alert = UIAlertController(with: error, title: NSLocalizedString("Error Canceling Bolus", comment: "The alert title for an error while canceling a bolus"))
                                self.present(alert, animated: true, completion: nil)
                                if case .inProgress(let dose) = self.bolusState {
                                    self.updateHUDandStatusRows(statusRowMode: .bolusing(dose: dose), newSize: nil, animated: true)
                                } else {
                                    self.updateHUDandStatusRows(statusRowMode: .hidden, newSize: nil, animated: true)
                                }
                            }
                        }
                    }

                default:
                    break
                }
            }
        case .hud:
            break
        case .meal:
            tableView.deselectRow(at: indexPath, animated: true)
        case .glucose:
            tableView.deselectRow(at: indexPath, animated: true)
            performSegue(withIdentifier: CarbEntryViewController.className, sender: indexPath)
        }
    }

    // MARK: - Actions

    override func restoreUserActivityState(_ activity: NSUserActivity) {
        switch activity.activityType {
        case NSUserActivity.newCarbEntryActivityType:
            performSegue(withIdentifier: CarbEntryViewController.className, sender: activity)
        default:
            break
        }
    }

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
        case let vc as CarbEntryViewController:
            vc.deviceManager = deviceManager
            vc.glucoseUnit = statusCharts.glucose.glucoseUnit
            vc.currentGlucose = validGlucose
            vc.defaultAbsorptionTimes = deviceManager.loopManager.carbStore.defaultAbsorptionTimes
            vc.preferredUnit = deviceManager.loopManager.carbStore.preferredUnit

            if let activity = sender as? NSUserActivity {
                vc.restoreUserActivityState(activity)
            }
        case let vc as InsulinDeliveryTableViewController:
            vc.doseStore = deviceManager.loopManager.doseStore
            vc.hidesBottomBarWhenPushed = true
        case let vc as BolusViewController:
            vc.deviceManager = deviceManager
            vc.glucoseUnit = statusCharts.glucose.glucoseUnit
            vc.configuration = .manualCorrection
            vc.expertMode = expertMode
            AnalyticsManager.shared.didDisplayBolusScreen()
        case let vc as OverrideSelectionViewController:
            if deviceManager.loopManager.settings.futureOverrideEnabled() {
                vc.scheduledOverride = deviceManager.loopManager.settings.scheduleOverride
            }
            vc.presets = deviceManager.loopManager.settings.overridePresets
            vc.glucoseUnit = statusCharts.glucose.glucoseUnit
            vc.delegate = self
        case let vc as PredictionTableViewController:
            vc.deviceManager = deviceManager
        case let vc as SettingsTableViewController:
            vc.dataManager = deviceManager
        case let vc as NewFoodPickerViewController:
            deviceManager.foodManager.updatePopular()
            vc.foodManager = deviceManager.foodManager
        default:
            break
        }
    }

    @IBAction func unwindFromEditing(_ segue: UIStoryboardSegue) {}

    @IBAction func unwindFromCarbEntryViewController(_ segue: UIStoryboardSegue) {
        guard let carbEntryViewController = segue.source as? CarbEntryViewController else {
            return
        }

        guard carbEntryViewController.closeWithContinue else {
            return
        }

        if carbEntryViewController.updatedCarbEntry != nil {
            if #available(iOS 12.0, *) {
                let interaction = INInteraction(intent: NewCarbEntryIntent(), response: nil)
                interaction.donate { [weak self] (error) in
                    if let error = error {
                        self?.log.error("Failed to donate intent: %{public}@", String(describing: error))
                    }
                }
            }
        }
        addCarbAndGlucose(carbEntry: carbEntryViewController.updatedCarbEntry, glucoseSample: carbEntryViewController.glucoseSample)
    }

    @IBAction func unwindFromBolusViewController(_ segue: UIStoryboardSegue) {
        guard let bolusViewController = segue.source as? BolusViewController else {
            return
        }

        if let carbEntry = bolusViewController.updatedCarbEntry {
            if #available(iOS 12.0, *) {
                let interaction = INInteraction(intent: NewCarbEntryIntent(), response: nil)
                interaction.donate { [weak self] (error) in
                    if let error = error {
                        self?.log.error("Failed to donate intent: %{public}@", String(describing: error))
                    }
                }
            }

            deviceManager.loopManager.addCarbEntryAndRecommendBolus(carbEntry) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        // Enact the user-entered bolus
                        if let bolus = bolusViewController.bolus, bolus > 0 {
                            self.deviceManager.enactBolus(units: bolus) { _ in }
                        }
                    case .failure(let error):
                        // Ignore bolus wizard errors
                        if error is CarbStore.CarbStoreError {
                            self.present(UIAlertController(with: error), animated: true)
                        } else {
                            self.log.error("Failed to add carb entry: %{public}@", String(describing: error))
                        }
                    }
                }
            }
        } else if let bolus = bolusViewController.bolus, bolus > 0 {
            self.deviceManager.enactBolus(units: bolus) { _ in }
        }
    }

    @IBAction func unwindFromSettings(_ segue: UIStoryboardSegue) {
    }

    private func createPreMealButtonItem(selected: Bool) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage.preMealImage(selected: selected), style: .plain, target: self, action: #selector(togglePreMealMode(_:)))
        item.accessibilityLabel = NSLocalizedString("Pre-Meal Targets", comment: "The label of the pre-meal mode toggle button")

        if selected {
            item.accessibilityTraits.insert(.selected)
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
            item.accessibilityTraits.insert(.selected)
            item.accessibilityHint = NSLocalizedString("Disables", comment: "The action hint of the workout mode toggle button when enabled")
        } else {
            item.accessibilityHint = NSLocalizedString("Enables", comment: "The action hint of the workout mode toggle button when disabled")
        }

        item.tintColor = UIColor.glucoseTintColor

        return item
    }

    @IBAction func togglePreMealMode(_ sender: UIBarButtonItem) {
        if preMealMode == true {
            deviceManager.loopManager.settings.clearOverride(matching: .preMeal)
        } else {
            deviceManager.loopManager.settings.enablePreMealOverride(for: .hours(1))
        }
    }

    @IBAction func toggleWorkoutMode(_ sender: UIBarButtonItem) {
        if workoutMode == true {
            deviceManager.loopManager.settings.clearOverride()
        } else {
            if FeatureFlags.sensitivityOverridesEnabled {
                performSegue(withIdentifier: OverrideSelectionViewController.className, sender: toolbarItems![6])
            } else {
                let vc = UIAlertController(workoutDurationSelectionHandler: { duration in
                    let startDate = Date()
                    self.deviceManager.loopManager.settings.enableLegacyWorkoutOverride(at: startDate, for: duration)
                })

                present(vc, animated: true, completion: nil)
            }
        }
    }

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
                    // deviceManager.loopManager.addInternalNote("toggleExpertMode \(expertMode)")
                    toolbarItems![8].isEnabled = expertMode
                    if expertMode {
                        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(minutes: 30)) {
                            self.expertMode = false
                            self.toolbarItems![8].isEnabled = self.expertMode
                        }
                    }
                } else {
                    if !expertMode {
                        let alert = UIAlertController(title: "Hint", message: "Press for 2 seconds to toggle expert mode.",
                                                                preferredStyle: .alert)
                        let action = UIAlertAction(title: NSLocalizedString("com.loudnate.LoopKit.errorAlertActionTitle", value: "OK", comment: "The title of the action used to dismiss an error alert"), style: .default)
                        alert.addAction(action)
                        alert.preferredAction = action
                        present(alert, animated: true)

                    } else {
                        // performSegue(withIdentifier: SettingsTableViewController.className, sender: nil)
                    }
                }
            }
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
            
            if deviceManager.cgmManager?.appURL != nil {
                hudView.glucoseHUD.accessibilityHint = NSLocalizedString("Launches CGM app", comment: "Glucose HUD accessibility hint")
            }
            
            configurePumpManagerHUDViews()
            
            hudView.loopCompletionHUD.stateColors = .loopStatus
            hudView.glucoseHUD.stateColors = .cgmStatus
            hudView.glucoseHUD.tintColor = .glucoseTintColor
            hudView.basalRateHUD.tintColor = .doseTintColor

            refreshContext.update(with: .status)
            self.log.debug("[reloadData] after hudView loaded")
            reloadData()
        }
    }
    
    private func configurePumpManagerHUDViews() {
        if let hudView = hudView {
            hudView.removePumpManagerProvidedViews()
            if let pumpManagerHUDProvider = deviceManager.pumpManagerHUDProvider {
                let views = pumpManagerHUDProvider.createHUDViews()
                for view in views {
                    addViewToHUD(view)
                }
                pumpManagerHUDProvider.visible = active && onscreen
            } else {
                let reservoirView = ReservoirVolumeHUDView.instantiate()
                let batteryView = BatteryLevelHUDView.instantiate()
                for view in [reservoirView, batteryView] {
                    addViewToHUD(view)
                }
            }
        }
    }
    
    private func addViewToHUD(_ view: BaseHUDView) {
        if let hudView = hudView {
            let hudTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(hudViewTapped(_:)))
            view.addGestureRecognizer(hudTapGestureRecognizer)
            view.stateColors = .pumpStatus
            hudView.addHUDView(view)
        }
    }

    @objc private func showLastError(_: Any) {
        var error: Error? = nil
        // First, check whether we have a device error after the most recent completion date
        if let deviceError = deviceManager.lastError,
            deviceError.date > (hudView?.loopCompletionHUD.lastLoopCompleted ?? .distantPast)
        {
            error = deviceError.error
        } else if let lastLoopError = lastLoopError {
            error = lastLoopError
        }

        if error != nil {
            let alertController = UIAlertController(with: error!)
            let manualLoopAction = UIAlertAction(title: NSLocalizedString("Retry", comment: "The button text for attempting a manual loop"), style: .default, handler: { _ in
                self.deviceManager.loopManager.loop(trigger: "showLastError")
            })
            alertController.addAction(manualLoopAction)
            present(alertController, animated: true)
        }
    }

    @objc private func openCGMApp(_: Any) {
        if let url = deviceManager.cgmManager?.appURL, UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    @objc private func hudViewTapped(_ sender: UIGestureRecognizer) {
        if let hudSubView = sender.view as? BaseHUDView,
            let pumpManagerHUDProvider = deviceManager.pumpManagerHUDProvider,
            let action = pumpManagerHUDProvider.didTapOnHUDView(hudSubView)
        {
            switch action {
            case .presentViewController(let vc):
                var completionNotifyingVC = vc
                completionNotifyingVC.completionDelegate = self
                self.present(vc, animated: true, completion: nil)
            case .openAppURL(let url):
                UIApplication.shared.open(url)
            }
        }
    }

    // MARK: - Testing scenarios

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if let testingScenariosManager = deviceManager.testingScenariosManager, !testingScenariosManager.scenarioURLs.isEmpty {
            if motion == .motionShake {
                presentScenarioSelector()
            }
        }
    }

    private func presentScenarioSelector() {
        guard let testingScenariosManager = deviceManager.testingScenariosManager else {
            return
        }

        let vc = TestingScenariosTableViewController(scenariosManager: testingScenariosManager)
        present(UINavigationController(rootViewController: vc), animated: true)
    }

    private func addScenarioStepGestureRecognizers() {
        if debugEnabled {
            let leftSwipe = UISwipeGestureRecognizer(target: self, action: #selector(stepActiveScenarioForward))
            leftSwipe.direction = .left
            let rightSwipe = UISwipeGestureRecognizer(target: self, action: #selector(stepActiveScenarioBackward))
            rightSwipe.direction = .right

            let toolBar = navigationController!.toolbar!
            toolBar.addGestureRecognizer(leftSwipe)
            toolBar.addGestureRecognizer(rightSwipe)
        }
    }

    @objc private func stepActiveScenarioForward() {
        deviceManager.testingScenariosManager?.stepActiveScenarioForward { _ in }
    }

    @objc private func stepActiveScenarioBackward() {
        deviceManager.testingScenariosManager?.stepActiveScenarioBackward { _ in }
    }

    // MODIFICATIONS

    // MANUAL GLUCOSE ENTRY
    private var validGlucose : GlucoseValue? = nil
    private var needManualGlucose : Date? = nil
    private var displayNeedManualGlucose : Date? = nil
    // Notes
    @IBAction func unwindFromNoteTableViewController(_ segue: UIStoryboardSegue) {
        if let controller = segue.source as? NoteTableViewController, controller.saved {
            let note = controller.text
            deviceManager.loopManager.nightscoutDataManager?.uploadNote(date: Date(), note: note)
        }
    }

    private func addCarbAndGlucose(carbEntry: NewCarbEntry?, glucoseSample : NewGlucoseSample? = nil) {
        if let sample = glucoseSample {
            let glucoseStore = deviceManager.loopManager.glucoseStore
            glucoseStore.addGlucose(sample) { result in
                switch result {
                case .failure(let error):
                    self.log.error("addCarbAndGlucose: addGlucose error %{public}@", String(describing: error))
                case .success(let value):
                    self.deviceManager.loopManager.nightscoutDataManager?.uploadMeterGlucose(date: value.startDate, glucose: value.quantity, comment: "Manually Entered")
                }
                if let carbEntry = carbEntry {
                    self.updateCarbEntry(updatedEntry: carbEntry)
                }
            }
        } else {
            if let carbEntry = carbEntry {
                updateCarbEntry(updatedEntry: carbEntry)
            }
        }
    }

    private func updateMealInformation(_ updateGroup: DispatchGroup, _ carbStore: CarbStore?) {
        // This should be populated in LoopDataManager really.
        guard let carbStore = carbStore else {
            self.log.error("updateMealInformation - carbStore not available")
            return
        }
        let endDate = Date()
        let mealDate = endDate.addingTimeInterval(TimeInterval(minutes: -45))

        let undoPossibleDate = endDate.addingTimeInterval(TimeInterval(minutes: -15))
        updateGroup.enter()
        carbStore.getCarbEntries(start: mealDate) { (result) in
            switch result {
            case .success(let values):

                var mealStart = endDate
                var mealEnd = mealDate
                var carbs : Double = 0
                var allPicks = FoodPicks()
                for value in values {
                    mealStart = min(mealStart, value.startDate)
                    mealEnd = max(value.startDate, mealStart)
                    let picks = value.foodPicks()
                    for pick in picks.picks {
                        allPicks.append(pick)
                    }
                    if let lastpick = picks.last {
                        mealEnd = max(lastpick.date, mealEnd)
                    }
                    carbs = carbs + picks.carbs

                }
                carbs = round(carbs)

                let undoPossible = undoPossibleDate <= mealEnd

                self.mealInformation = (date: endDate, lastCarbEntry: values.last,
                                        picks: allPicks,
                                        start: mealStart, end: mealEnd, carbs: carbs, undoPossible: undoPossible)

                self.log.default("updateMealInformation - %{public}@", String(describing: self.mealInformation))
            case .failure(let error):
                self.log.error("updateMealInformation - %{public}@", String(describing:error))
            }
            updateGroup.leave()
        }

    }

    func updateCarbEntry(updatedEntry: NewCarbEntry) {
        deviceManager.loopManager.addCarbEntryAndRecommendBolus(updatedEntry) { (result) -> Void in
            DispatchQueue.main.async {
                switch result {
                case .success(let recommendation):
                    if self.active && self.visible, let bolus = recommendation?.amount, bolus > 0 {
                        if self.deviceManager.loopManager.settings.dosingStrategy != .automaticBolus {
                            if self.bolusState == .none {
                                self.performSegue(withIdentifier: BolusViewController.className, sender: recommendation)
                            } else {
                                // Bolus in progress, skip but give warning?
                            }
                        }
                    }
                case .failure(let error):
                    // Ignore bolus wizard errors
                    if error is CarbStore.CarbStoreError {
                        self.present(UIAlertController(with: error), animated: true)
                    } else {
                        self.log.error("updateCarbEntry: addCarbError - %{public}@", String(describing: error))
                    }
                }
            }
        }
    }

    @IBAction func unwindFromNewFoodPickerViewController(_ segue: UIStoryboardSegue) {
        if let controller = segue.source as? NewFoodPickerViewController, let pick = controller.foodPick {
            addCarbAndGlucose(carbEntry: pick.carbEntry)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // self.needsRefresh = true
                self.reloadData()
            }
        }
    }

    private var foodRecentCollectionViewDataSource = FoodRecentCollectionViewDataSource()
    private var displayMeal : Bool = true
    typealias MealInformation = (date: Date, lastCarbEntry: StoredCarbEntry?, picks: FoodPicks, start: Date?, end: Date?, carbs: Double, undoPossible: Bool)
    private var mealInformation : MealInformation?

    func mealTableViewCellTap(_ sender : MealTableViewCell) {
        //        performSegue(withIdentifier: FoodPickerViewController.className, sender: sender)
        performSegue(withIdentifier: NewFoodPickerViewController.className, sender: sender)
    }

    func mealTableViewCellImageTap(_ sender : MealTableViewCell) {
        if let mi = self.mealInformation, let lastCarbEntry = mi.lastCarbEntry, let pick = lastCarbEntry.foodPicks().last,  mi.undoPossible {

            let alert = UIAlertController(title: "Undo Food Selection", message: "Are you sure you want to remove the last food pick \(pick.item.title) of \(pick.displayCarbs) g carbs?", preferredStyle: .alert)


            alert.addAction(UIAlertAction(title: "Remove", style: .default, handler: { [weak alert] (_) in
                self.log.default("removeLastFoodPick Alert %{public}@", String(describing: alert))
                self.deviceManager.loopManager.removeCarbEntry(carbEntry: lastCarbEntry) { (error) in
                    if let err = error {
                        self.log.error("removeLastFoodPick Error  %{public}@", String(describing: err))
                        let bla = UIAlertController(title: "Undo Food Selection", message: "removeLastFoodPick Alert \(err)?", preferredStyle: .alert)
                        bla.addAction(UIAlertAction(title: "Back", style: .cancel, handler: nil))
                        self.present(bla, animated: true, completion: nil)
                    }
                    DispatchQueue.main.async {
                        self.reloadData()
                    }
                }
            }))

            alert.addAction(UIAlertAction(title: "Back", style: .cancel, handler: nil))
            self.present(alert, animated: true, completion: nil)

        } else {
            //            performSegue(withIdentifier: FoodPickerViewController.className, sender: sender)
            performSegue(withIdentifier: NewFoodPickerViewController.className, sender: sender)

        }
    }
    @objc func showNote(_ sender: UIBarButtonItem) {
        performSegue(withIdentifier: NoteTableViewController.className, sender: sender)
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

extension StatusTableViewController: CompletionDelegate {
    func completionNotifyingDidComplete(_ object: CompletionNotifying) {
        if let vc = object as? UIViewController, presentedViewController === vc {
            dismiss(animated: true, completion: nil)
        }
    }
}

extension StatusTableViewController: PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        dispatchPrecondition(condition: .onQueue(.main))
        log.default("PumpManager:%{public}@ did update status", String(describing: type(of: pumpManager)))

        self.basalDeliveryState = status.basalDeliveryState
        self.bolusState = status.bolusState

        DispatchQueue.main.async {
            self.toolbarItems![4].isEnabled = status.bolusState == .none
        }

    }
}

extension StatusTableViewController: DoseProgressObserver {
    func doseProgressReporterDidUpdate(_ doseProgressReporter: DoseProgressReporter) {

        updateBolusProgress()

        if doseProgressReporter.progress.isComplete {
            // Bolus ended
            self.bolusProgressReporter = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
                self.bolusState = .none
                self.toolbarItems![4].isEnabled = true
                self.reloadData(animated: true)
            })
        }
    }
}

extension StatusTableViewController: OverrideSelectionViewControllerDelegate {
    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didUpdatePresets presets: [TemporaryScheduleOverridePreset]) {
        deviceManager.loopManager.settings.overridePresets = presets
    }

    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didConfirmOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.settings.scheduleOverride = override
    }

    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didCancelOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.settings.scheduleOverride = nil
    }
}

extension StatusTableViewController: AddEditOverrideTableViewControllerDelegate {
    func addEditOverrideTableViewController(_ vc: AddEditOverrideTableViewController, didSaveOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.settings.scheduleOverride = override
    }

    func addEditOverrideTableViewController(_ vc: AddEditOverrideTableViewController, didCancelOverride override: TemporaryScheduleOverride) {
        if deviceManager.loopManager.settings.scheduleOverride?.enactTrigger == .autosense {
            deviceManager.loopManager.settings.autosenseSuspended = Date()
        }
        deviceManager.loopManager.settings.scheduleOverride = nil
    }
}
