import Foundation
import IOKit.ps
import Observation

/// Заряд батареи и состояние питания через IOKit.
@MainActor
@Observable
final class BatteryService {
    private(set) var level = 100
    private(set) var isCharging = false
    private(set) var isPluggedIn = false
    private(set) var hasBattery = false
    private(set) var minutesToFull: Int?

    @ObservationIgnored var onPluggedIn: (@MainActor () -> Void)?
    @ObservationIgnored var onLowBattery: (@MainActor () -> Void)?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var didLoadOnce = false
    @ObservationIgnored private var lastWarnedLevel: Int?

    init() {
        update()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.update() }
        }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
    }

    /// Для демо-режима (на машине без батареи).
    func applyDemo(level: Int, charging: Bool) {
        hasBattery = true
        self.level = level
        isCharging = charging
        isPluggedIn = charging
    }

    var symbolName: String {
        if isCharging || isPluggedIn { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    func update() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let newLevel = Int((Double(current) / Double(maximum) * 100).rounded())
            let plugged = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let toFull = description[kIOPSTimeToFullChargeKey] as? Int

            let wasPlugged = isPluggedIn
            hasBattery = true
            level = newLevel
            isPluggedIn = plugged
            isCharging = charging
            minutesToFull = (toFull ?? -1) > 0 ? toFull : nil

            if didLoadOnce, plugged, !wasPlugged {
                lastWarnedLevel = nil
                onPluggedIn?()
            }
            if !plugged, newLevel <= 20 {
                let threshold = newLevel <= 10 ? 10 : 20
                if lastWarnedLevel != threshold {
                    lastWarnedLevel = threshold
                    if didLoadOnce { onLowBattery?() }
                }
            }
            break
        }
        didLoadOnce = true
    }
}
