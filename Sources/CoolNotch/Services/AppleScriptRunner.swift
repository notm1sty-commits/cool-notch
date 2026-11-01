import AppKit

/// Снимок состояния плеера.
struct PlayerSnapshot: Sendable {
    var state: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var artworkURL: String?
    /// Повтор как его называет плеер: Музыка — off/one/all, Spotify — true/false.
    var repeatMode: String?
}

/// Выполняет AppleScript на отдельной очереди, чтобы не тормозить интерфейс.
final class AppleScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cool-notch.applescript", qos: .utility)

    func run(_ source: String) {
        queue.async {
            _ = Self.execute(source)
        }
    }

    func run<T: Sendable>(
        _ source: String,
        parse: @escaping @Sendable (NSAppleEventDescriptor) -> T?,
        completion: @escaping @MainActor (T?) -> Void
    ) {
        perform({ _ in
            let result = Self.execute(source)
            return result.descriptor.flatMap(parse)
        }, completion: completion)
    }

    /// Выполняет произвольную работу на очереди AppleScript и возвращает результат на главный поток.
    func perform<T: Sendable>(
        _ work: @escaping @Sendable (AppleScriptRunner) -> T,
        completion: @escaping @MainActor (T) -> Void
    ) {
        queue.async {
            let value = work(self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(value) }
            }
        }
    }

    /// Как `execute`, но с номером ошибки — чтобы понять, что именно не так
    /// (-1743 — нет разрешения «Автоматизация», выключенный JavaScript в браузере и т. д.).
    static func executeDetailed(_ source: String) -> (descriptor: NSAppleEventDescriptor?, code: Int?, message: String?) {
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            return (nil, error[NSAppleScript.errorNumber] as? Int, error[NSAppleScript.errorMessage] as? String)
        }
        return (descriptor, nil, nil)
    }

    /// Синхронное выполнение. Вызывать только внутри `perform`.
    static func execute(_ source: String) -> (descriptor: NSAppleEventDescriptor?, error: String?) {
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            return (nil, error["NSAppleScriptErrorMessage"] as? String ?? "AppleScript error")
        }
        return (descriptor, nil)
    }

    static func parseSnapshot(_ d: NSAppleEventDescriptor) -> PlayerSnapshot? {
        let count = d.numberOfItems
        guard count >= 1 else { return nil }
        let state = d.atIndex(1)?.stringValue ?? "stopped"
        guard count >= 6 else {
            return PlayerSnapshot(state: state, title: "", artist: "", album: "", duration: 0, position: 0)
        }
        func text(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func number(_ i: Int) -> Double { d.atIndex(i)?.doubleValue ?? 0 }
        return PlayerSnapshot(
            state: state,
            title: text(2),
            artist: text(3),
            album: text(4),
            duration: number(5),
            position: number(6),
            artworkURL: count >= 7 ? d.atIndex(7)?.stringValue.flatMap { $0.isEmpty ? nil : $0 } : nil,
            repeatMode: count >= 8 ? d.atIndex(8)?.stringValue : nil
        )
    }
}
