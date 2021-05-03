//
//  AppDelegate.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/15/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import UIKit
import BackgroundTasks
import Intents
import LoopKit
import UserNotifications

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate, CLLocationManagerDelegate {

    private lazy var log = DiagnosticLogger.shared.forCategory("AppDelegate")

    var window: UIWindow?

    private var deviceManager: DeviceDataManager?

    private var rootViewController: RootNavigationController! {
        return window?.rootViewController as? RootNavigationController
    }
    
    private var isAfterFirstUnlock: Bool {
        let fileManager = FileManager.default
        do {
            let documentDirectory = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor:nil, create:false)
            let fileURL = documentDirectory.appendingPathComponent("protection.test")
            guard fileManager.fileExists(atPath: fileURL.path) else {
                let contents = Data("unimportant".utf8)
                try? contents.write(to: fileURL, options: .completeFileProtectionUntilFirstUserAuthentication)
                // If file doesn't exist, we're at first start, which will be user directed.
                return true
            }
            let contents = try? Data(contentsOf: fileURL)
            return contents != nil
        } catch {
            log.error(error)
        }
        return false
    }
    
    private func finishLaunch() {
        log.default("Finishing launching")
        
        deviceManager = DeviceDataManager()

        NotificationManager.authorize(delegate: self)
 
        let mainStatusViewController = UIStoryboard(name: "Main", bundle: Bundle(for: AppDelegate.self)).instantiateViewController(withIdentifier: "MainStatusViewController") as! StatusTableViewController
        
        mainStatusViewController.deviceManager = deviceManager
        
        rootViewController.pushViewController(mainStatusViewController, animated: false)
        
    }

    var nightscoutURL: URL? {
        return deviceManager?.remoteDataManager.nightscoutService.siteURL
    }

    private var locationManager = CLLocationManager()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        log.default("didFinishLaunchingWithOptions \(String(describing: launchOptions))")

        guard isAfterFirstUnlock else {
            log.default("Launching before first unlock; pausing launch...")
            return false
        }

        finishLaunch()
        // We can only log to nightscout after setting up deviceManager.
        AnalyticsManager.shared.application(application, didFinishLaunchingWithOptions: launchOptions)

        let notificationOption = launchOptions?[.remoteNotification]
        
        if let notification = notificationOption as? [String: AnyObject] {
            deviceManager?.handleRemoteNotification(notification)
        }

        UIApplication.shared.setMinimumBackgroundFetchInterval(300)

        UIApplication.shared.registerForRemoteNotifications()

        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            // The device does not support this service.

            locationManager.requestAlwaysAuthorization()
            locationManager.delegate? = self
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startMonitoringSignificantLocationChanges()
            locationManager.pausesLocationUpdatesAutomatically = false

            //if locationManager.authorizationStatus == .none {

            //}
            log.error("Location Service for significant changes enabled.")
        } else {
            log.error("Location Service not available.")
        }
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: "com.loop.refresh",
                using: DispatchQueue.global()
            ) { task in
                NSLog("Background App Refresh")
                //self.handleAppRefresh(task)
            }
            scheduleAppRefresh()
        } else {
            // Fallback on earlier versions
        }
        return true
    }

    @available(iOS 13.0, *)
    private func handleAppRefresh(_ task: BGTask) {
        NSLog("background handleAppRefresh")
        refreshBackground("BGFetch")
//        let queue = OperationQueue()
//        queue.maxConcurrentOperationCount = 1
//        let appRefreshOperation = AppRefreshOperation()
//        queue.addOperation(appRefreshOperation)
//
//        task.expirationHandler = {
//            queue.cancelAllOperations()
//        }
//
//        let lastOperation = queue.operations.last
//        lastOperation?.completionBlock = {
//            task.setTaskCompleted(success: !(lastOperation?.isCancelled ?? false))
//        }

        scheduleAppRefresh()
    }


    private func scheduleAppRefresh() {
        if #available(iOS 13.0, *) {
            NSLog("background scheduleAppRefresh")
            let request = BGAppRefreshTaskRequest(identifier: "com.loop.refresh")
            request.earliestBeginDate = Date(timeIntervalSinceNow: 300)
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                self.log.error(error)
            }
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {
        log.default(#function)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        log.default(#function)
        // scheduleAppRefresh()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        log.default(#function)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        deviceManager?.updatePumpManagerBLEHeartbeatPreference()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        log.default(#function)
    }

    func refreshBackground(_ sender: String) {
        let log = DiagnosticLogger.shared.forCategory("AppDelegate+Background")
        log.default("refreshBackground \(sender)")
        deviceManager?.updatePumpManagerBLEHeartbeatPreference()
        /* if let pump = deviceManager?.pumpManager {
            //deviceManager?.pumpManagerBLEHeartbeatDidFire(pump)
            deviceManager?.cgmFetchDataIfNeeded()
        }*/
        deviceManager?.scheduleCgmFetchDataIfNeeded()
    }

    func locationManager(_ manager: CLLocationManager,  didUpdateLocations locations: [CLLocation]) {
       let lastLocation = locations.last!
       refreshBackground("didUpdateLocations \(lastLocation)")
    }

    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        refreshBackground("fetch \(nightscoutURL)")

        guard let url = nightscoutURL else { return }

        URLSession.shared.dataTask(with: url) { (data, response, err) in
            let log = DiagnosticLogger.shared.forCategory("AppDelegate+Background")
            log.default("AppDelegate Download \(String(describing: err)) \(url): \(response)")
//            guard let data = data else { return }
            completionHandler(.noData)
        }.resume()
    }

    // MARK: - Continuity

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        log.default(#function)

        if #available(iOS 12.0, *) {
            if userActivity.activityType == NewCarbEntryIntent.className {
                log.default("Restoring \(userActivity.activityType) intent")
                rootViewController.restoreUserActivityState(.forNewCarbEntry())
                return true
            }
        }

        switch userActivity.activityType {
        case NSUserActivity.newCarbEntryActivityType,
             NSUserActivity.viewLoopStatusActivityType:
            log.default("Restoring \(userActivity.activityType) activity")
            restorationHandler([rootViewController])
            return true
        default:
            return false
        }
    }
    
    // MARK: - Remote notifications
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
        let token = tokenParts.joined()
        log.default("RemoteNotifications device token: \(token)")
        deviceManager?.loopManager.settings.deviceToken = deviceToken
        AnalyticsManager.shared.didReceiveRemoteToken("\(token)")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("Failed to register for remote notifications: \(error)")
    }
    
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let notification = userInfo as? [String: AnyObject] else {
            completionHandler(.failed)
            return
        }
      
        deviceManager?.handleRemoteNotification(notification)
        completionHandler(.noData)
    }
    
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        log.default("applicationProtectedDataDidBecomeAvailable")
        
        if deviceManager == nil {
            finishLaunch()
        }
    }

}


extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case NotificationManager.Action.retryBolus.rawValue:
            if  let units = response.notification.request.content.userInfo[NotificationManager.UserInfoKey.bolusAmount.rawValue] as? Double,
                let startDate = response.notification.request.content.userInfo[NotificationManager.UserInfoKey.bolusStartDate.rawValue] as? Date,
                startDate.timeIntervalSinceNow >= TimeInterval(minutes: -5)
            {
                AnalyticsManager.shared.didRetryBolus()

                deviceManager?.enactBolus(units: units, at: startDate) { (_) in
                    completionHandler()
                }
                return
            }
        default:
            break
        }
        
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.badge, .sound, .alert])
    }
    
}
