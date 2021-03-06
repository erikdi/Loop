//
//  AppDelegate.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/15/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import UIKit
import UserNotifications
import CarbKit
import InsulinKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    private(set) lazy var deviceManager = DeviceDataManager()

    private(set) lazy var foodManager = FoodManager()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        NSLog("GitVersionInformation \(GitVersionInformation().dict)")

        window?.tintColor = UIColor.tintColor

        NotificationManager.authorize(delegate: self)

        // Enable local logging of NSLog for later debugging.
        /*
        var paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let documentsDirectory = paths[0]
        let fileName = "\(Date()).log"
        let logFilePath = (documentsDirectory as NSString).appendingPathComponent(fileName)
        // Disabled out of file size concerns for now
        freopen(logFilePath.cString(using: String.Encoding.ascii)!, "a+", stderr)
        */
        
        let bundle = Bundle(for: type(of: self))
        DiagnosticLogger.shared = DiagnosticLogger(subsystem: bundle.bundleIdentifier!, version: bundle.shortVersionString)
        DiagnosticLogger.shared?.forCategory("AppDelegate").info(#function)
        DiagnosticLogger.shared?.loopManager = deviceManager.loopManager

        AnalyticsManager.shared.application(application, didFinishLaunchingWithOptions: launchOptions)
        AnalyticsManager.shared.loopManager = deviceManager.loopManager
        
        StatisticsManager.shared.loopManager = deviceManager.loopManager

        if  let navVC = window?.rootViewController as? UINavigationController,
            let statusVC = navVC.viewControllers.first as? StatusTableViewController {
            statusVC.deviceManager = deviceManager
            statusVC.foodManager = foodManager
        }

        application.setMinimumBackgroundFetchInterval(300.0)
        
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
        deviceManager.updateTimerTickPreference()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func applicationShouldRequestHealthAuthorization(_ application: UIApplication) {

    }

    // MARK: - 3D Touch

    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
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

                deviceManager.enactBolus(units: units, at: startDate) { (_) in
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


// Watchdog for resetting Bluetooth if needed.
extension AppDelegate {
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NSLog("background-fetch")
        deviceManager.maybeToggleBluetooth("background-fetch")
        
        guard let url = URL(string: "http://www.example.com") else { return }
        URLSession.shared.dataTask(with: url) { (data, response, err) in
            guard let data = data else { return }
            NSLog("AppDelegate Download success \(data)")
            }.resume()
        
        completionHandler(UIBackgroundFetchResult.newData)
    }
    
}
