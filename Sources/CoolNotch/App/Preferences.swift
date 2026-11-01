import Foundation

/// Ключи настроек в UserDefaults.
enum Pref {
    static let hoverDelay = "hoverDelay"
    static let haptics = "haptics"
    static let showMusicActivity = "showMusicActivity"
    static let showChargingActivity = "showChargingActivity"
    static let showLowBattery = "showLowBattery"
    static let trackBanners = "trackBanners"
    static let deviceBanners = "deviceBanners"
    static let browserMusic = "browserMusic"
    static let systemNowPlaying = "systemNowPlaying"
    static let systemNotifications = "systemNotifications"
    static let notchStyle = "notchStyle"
    static let fxChromatic = "fxChromatic"
    static let fxEdgeGlow = "fxEdgeGlow"
    static let fx3D = "fx3D"
    static let fxJelly = "fxJelly"
    static let glassTint = "glassTint"
    static let screenshotsInHistory = "screenshotsInHistory"
    static let onboardingDone = "onboardingDone"
    static let autoCheckUpdates = "autoCheckUpdates"
    static let clipboardHistory = "clipboardHistory"
    static let openOnFileDrag = "openOnFileDrag"
    static let timerSound = "timerSound"
    static let notesText = "notesText"
    static let shelfPaths = "shelfPaths"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            hoverDelay: 0.1,
            haptics: true,
            showMusicActivity: true,
            showChargingActivity: true,
            showLowBattery: true,
            trackBanners: true,
            deviceBanners: true,
            browserMusic: false,
            systemNowPlaying: true,
            systemNotifications: true,
            notchStyle: "black",
            fxChromatic: true,
            fxEdgeGlow: true,
            fx3D: true,
            fxJelly: true,
            glassTint: 0.42,
            screenshotsInHistory: true,
            autoCheckUpdates: true,
            clipboardHistory: true,
            openOnFileDrag: true,
            timerSound: true,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func double(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
    static func set(_ value: Any?, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}
