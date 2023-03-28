// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0

import Foundation
import Shared
import Common
import MozillaAppServices

class NotificationsSettingsViewController: SettingsTableViewController, FeatureFlaggable {
    private lazy var engagementNotificationHelper = EngagementNotificationHelper()

    private lazy var syncNotifications: BoolNotificationSetting = {
        return BoolNotificationSetting(
            title: .Settings.Notifications.SyncNotificationsTitle,
            description: .Settings.Notifications.SyncNotificationsStatus,
            prefs: prefs,
            prefKey: PrefsKeys.Notifications.SyncNotifications,
            enabled: true
        ) { [weak self] value in
            guard let self = self else { return }

            Task {
                let shouldEnable = await self.notificationsChanged(value)
                self.syncNotifications.control.setOn(shouldEnable, animated: true)
                self.syncNotifications.writeBool(self.syncNotifications.control)

                // enable/disable sync notifications
                MZKeychainWrapper.sharedClientAppContainerKeychain.removeObject(
                    forKey: KeychainKey.apnsToken,
                    withAccessibility: MZKeychainItemAccessibility.afterFirstUnlock)
                NotificationCenter.default.post(name: .RegisterForPushNotifications, object: nil)
            }
        }
    }()

    private lazy var tipsAndFeaturesNotifications: BoolNotificationSetting = {
        return BoolNotificationSetting(
            title: .Settings.Notifications.TipsAndFeaturesNotificationsTitle,
            description: String(format: .Settings.Notifications.TipsAndFeaturesNotificationsStatus, AppName.shortName.rawValue),
            prefs: prefs,
            prefKey: PrefsKeys.Notifications.TipsAndFeaturesNotifications,
            enabled: true
        ) { [weak self] value in
            guard let self = self else { return }

            Task {
                let shouldEnable = await self.notificationsChanged(value)
                self.tipsAndFeaturesNotifications.control.setOn(shouldEnable, animated: true)
                self.tipsAndFeaturesNotifications.writeBool(self.tipsAndFeaturesNotifications.control)

                if shouldEnable {
                    // schedule engagement notifications if necessary
                    self.engagementNotificationHelper.schedule()
                } else {
                    // cancel all pending engagement notifications
                    self.engagementNotificationHelper.cancelAll()
                }
            }
        }
    }()

    private let prefs: Prefs
    private let hasAccount: Bool
    private var footerTitle = ""

    init(prefs: Prefs, hasAccount: Bool) {
        self.prefs = prefs
        self.hasAccount = hasAccount
        super.init(style: .grouped)
        self.title = .Settings.Notifications.Title
        self.addObservers()

        Task {
            await self.checkForSystemNotifications()
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func generateSettings() -> [SettingSection] {
        let childrenSection: [Setting]
        if hasAccount {
            childrenSection = [syncNotifications, tipsAndFeaturesNotifications]
        } else {
            childrenSection = [tipsAndFeaturesNotifications]
        }

        return [SettingSection(footerTitle: NSAttributedString(string: footerTitle), children: childrenSection)]
    }

    func checkForSystemNotifications() async {
        let settings = await NotificationManager().getNotificationSettings()

        switch settings.authorizationStatus {
        case .denied:
            self.footerTitle = String(format: .Settings.Notifications.systemNotificationsDisabledMessage,
                                      AppName.shortName.rawValue,
                                      AppName.shortName.rawValue)
        case .authorized, .provisional, .ephemeral, .notDetermined:
            fallthrough
        @unknown default:
            self.footerTitle = ""
        }

        self.settings = generateSettings()
        self.tableView.reloadData()
    }

    private func notificationsChanged(_ sendNotifications: Bool) async -> Bool {
        guard sendNotifications else { return false }

        let notificationManager = NotificationManager()
        let settings = await notificationManager.getNotificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await notificationManager.requestAuthorization()
            } catch {
                return false
            }
        case .denied:
            self.footerTitle = String(format: .Settings.Notifications.systemNotificationsDisabledMessage, AppName.shortName.rawValue, AppName.shortName.rawValue)
            self.settings = generateSettings()
            self.tableView.reloadData()
            await MainActor.run {
                self.present(accessDeniedAlert, animated: true, completion: nil)
            }
            return false
        @unknown default:
            return false
        }
    }

    var accessDeniedAlert: UIAlertController {
        let accessDenied = UIAlertController(
            title: .Settings.Notifications.TurnOnNotificationsTitle,
            message: String(format: .Settings.Notifications.TurnOnNotificationsMessage, AppName.shortName.rawValue),
            preferredStyle: .alert
        )
        let dismissAction = UIAlertAction(
            title: .CancelString,
            style: .default,
            handler: nil
        )
        accessDenied.addAction(dismissAction)
        let settingsAction = UIAlertAction(
            title: .OpenSettingsString,
            style: .default
        ) { _ in
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:])
        }
        accessDenied.addAction(settingsAction)
        return accessDenied
    }
}

extension NotificationsSettingsViewController: Notifiable {
    func addObservers() {
        setupNotifications(forObserver: self, observing: [UIApplication.willEnterForegroundNotification])
    }

    func handleNotifications(_ notification: Notification) {
        switch notification.name {
        case UIApplication.willEnterForegroundNotification:
            Task {
                await checkForSystemNotifications()
            }
        default: break
        }
    }
}
