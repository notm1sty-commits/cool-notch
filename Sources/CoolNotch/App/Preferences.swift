import Foundation

/// Ключи настроек в UserDefaults.
enum Pref {
    static let hoverDelay = "hoverDelay"
    static let haptics = "haptics"
    static let showMusicActivity = "showMusicActivity"
    static let showChargingActivity = "showChargingActivity"
    static let showLowBattery = "showLowBattery"
    static let clipboardHistory = "clipboardHistory"
    static let openOnFileDrag = "openOnFileDrag"
    static let timerSound = "timerSound"
    static let notesText = "notesText"
    static let shelfPaths = "shelfPaths"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            hoverDelay: 0.12,
            haptics: true,
            showMusicActivity: true,
            showChargingActivity: true,
            showLowBattery: true,
            clipboardHistory: true,
            openOnFileDrag: true,
            timerSound: true,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func double(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
}
