//
//  AppDelegate.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/19/26.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    let container = AppContainer()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        container.start()
        return true
    }
}
