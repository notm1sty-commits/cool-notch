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

    /// Вызывается по окончании; параметр — сколько минут был таймер.
    @ObservationIgnored var onFinish: (@MainActor (Int) -> Void)?
    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private var ticker: Timer?

    var isActive: Bool { state != .idle }
    var progress: Double { total > 0 ? min(max(remaining / total, 0), 1) : 0 }
    var remainingText: String { Self.format(remaining) }

    func start(minutes: Int) {
        start(seconds: TimeInterval(minutes * 60))
    }

    func start(seconds: TimeInterval) {
        total = max(1, seconds)
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
        // Полсекунды хватает для плавного кольца; допуск даёт системе экономить пробуждения.
        ticker = Timer.coalesced(interval: 0.5, tolerance: 0.15) { [weak self] in
            self?.tick()
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let endDate else { return }
        let left = max(0, endDate.timeIntervalSinceNow)
        remaining = left
        if left <= 0 {
            let minutes = Int((total / 60).rounded())
            stop()
            if Pref.bool(Pref.timerSound) { NSSound(named: "Glass")?.play() }
            onFinish?(minutes)
        }
    }

    /// «90» → 90 минут, «1:30» → 1 мин 30 с, «1:30:00» → 1 ч 30 мин.
    nonisolated static func parse(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        let seconds: Int
        switch values.count {
        case 1: seconds = values[0] * 60
        case 2: seconds = values[0] * 60 + values[1]
        case 3: seconds = values[0] * 3600 + values[1] * 60 + values[2]
        default: return nil
        }
        return seconds > 0 ? min(seconds, 24 * 3600) : nil
    }

    nonisolated static func durationText(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        if value % 60 != 0 { return format(seconds) }
        let minutes = value / 60
        return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
    }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded(.up))
        let h = value / 3600, m = (value % 3600) / 60, s = value % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
