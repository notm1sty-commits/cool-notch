import Foundation
import Observation

/// Секундомер с кругами. Время считается от момента запуска, а не тиками —
/// поэтому он точен и ничего не делает, пока на него не смотрят.
@MainActor
@Observable
final class StopwatchService {
    private(set) var isRunning = false
    /// Время до последней паузы.
    private(set) var accumulated: TimeInterval = 0
    private(set) var startedAt: Date?
    /// Отметки кругов — общее время на момент нажатия «Круг».
    private(set) var splits: [TimeInterval] = []

    var hasTime: Bool { isRunning || accumulated > 0 }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulated + (startedAt.map { date.timeIntervalSince($0) } ?? 0)
    }

    func toggle() {
        if isRunning {
            accumulated = elapsed()
            startedAt = nil
            isRunning = false
        } else {
            startedAt = Date()
            isRunning = true
        }
    }

    func lap() {
        guard isRunning else { return }
        splits.append(elapsed())
    }

    func reset() {
        isRunning = false
        startedAt = nil
        accumulated = 0
        splits = []
    }

    struct Lap: Identifiable {
        let number: Int
        let duration: TimeInterval
        var id: Int { number }
    }

    /// Длительность каждого круга, новые первыми.
    var laps: [Lap] {
        var result: [Lap] = []
        var previous: TimeInterval = 0
        for (index, split) in splits.enumerated() {
            result.append(Lap(number: index + 1, duration: split - previous))
            previous = split
        }
        return result.reversed()
    }

    /// «04:07,32» до часа, дальше «1:04:07».
    nonisolated static func format(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        let whole = Int(value)
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        let hundredths = Int((value - Double(whole)) * 100)
        return String(format: "%02d:%02d,%02d", m, s, hundredths)
    }
}
