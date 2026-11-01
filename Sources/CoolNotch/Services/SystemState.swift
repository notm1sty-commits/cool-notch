import AppKit

/// Состояние системы, влияющее на расход энергии: спит ли экран, включён ли режим энергосбережения.
@MainActor
enum SystemState {
    private(set) static var screensAsleep = false
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { screensAsleep = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { screensAsleep = false }
        })
    }

    static var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}

extension Timer {
    /// Таймер в общем режиме run loop с допуском — система может группировать пробуждения и экономить батарею.
    @discardableResult
    static func coalesced(interval: TimeInterval, tolerance: Double = 0.25, _ block: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { block() }
        }
        timer.tolerance = interval * tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
