import AppKit
import Observation

/// Простой таймер обратного отсчёта.
@MainActor
@Observable
final class TimerService {
    enum State { case idle, running, paused }

    private(set) var state: State = .idle
    private(set) var total: TimeInterval = 0
    private(set) var remaining: TimeInterval = 0

    @ObservationIgnored var onFinish: (@MainActor () -> Void)?
    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private var ticker: Timer?

    var isActive: Bool { state != .idle }
    var progress: Double { total > 0 ? min(max(remaining / total, 0), 1) : 0 }
    var remainingText: String { Self.format(remaining) }

    func start(minutes: Int) {
        total = TimeInterval(minutes * 60)
        remaining = total
        endDate = Date().addingTimeInterval(total)
        state = .running
        startTicker()
    }

    func pause() {
        guard state == .running, let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil
        state = .paused
        stopTicker()
    }

    func resume() {
        guard state == .paused else { return }
        endDate = Date().addingTimeInterval(remaining)
        state = .running
        startTicker()
    }

    func toggle() {
        state == .running ? pause() : resume()
    }

    func addMinute() {
        total += 60
        remaining += 60
        if let endDate { self.endDate = endDate.addingTimeInterval(60) }
    }

    func stop() {
        stopTicker()
        state = .idle
        total = 0
        remaining = 0
        endDate = nil
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let endDate else { return }
        let left = max(0, endDate.timeIntervalSinceNow)
        // Обновляем раз в «видимую» долю секунды, чтобы не дёргать интерфейс зря.
        if abs(left - remaining) >= 0.2 || left == 0 { remaining = left }
        if left <= 0 {
            stop()
            if Pref.bool(Pref.timerSound) { NSSound(named: "Glass")?.play() }
            onFinish?()
        }
    }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded(.up))
        let h = value / 3600, m = (value % 3600) / 60, s = value % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
