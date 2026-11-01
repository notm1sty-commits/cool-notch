import AppKit

/// Снимок состояния плеера, полученный через AppleScript.
struct PlayerSnapshot: Sendable {
    var state: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var artworkURL: String?
}

/// Выполняет AppleScript на отдельной очереди, чтобы не тормозить интерфейс.
final class AppleScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cool-notch.applescript", qos: .userInitiated)

    func run(_ source: String) {
        queue.async {
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    func run<T: Sendable>(
        _ source: String,
        parse: @escaping @Sendable (NSAppleEventDescriptor) -> T?,
        completion: @escaping @MainActor (T?) -> Void
    ) {
        queue.async {
            var error: NSDictionary?
            let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let value: T? = (error == nil) ? descriptor.flatMap(parse) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(value) }
            }
        }
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
            artworkURL: count >= 7 ? d.atIndex(7)?.stringValue : nil
        )
    }
}
