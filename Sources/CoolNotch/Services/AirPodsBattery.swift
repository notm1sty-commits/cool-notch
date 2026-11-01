import Foundation

/// Заряд наушников Apple (левый, правый, футляр). macOS показывает его в «Информации о системе»,
/// оттуда же берём и мы — через `system_profiler`, без особых разрешений.
struct AirPodsLevels: Sendable, Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var single: Int?

    var isEmpty: Bool { left == nil && right == nil && caseLevel == nil && single == nil }
}

enum AirPodsBattery {
    static func fetch(deviceName: String, completion: @escaping @MainActor (AirPodsLevels?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let levels = read(deviceName: deviceName)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(levels) }
            }
        }
    }

    private static func read(deviceName: String) -> AirPodsLevels? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }

        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let matches = name == deviceName || name.localizedCaseInsensitiveContains("airpods")
                    guard matches else { continue }
                    let levels = AirPodsLevels(
                        left: percent(info["device_batteryLevelLeft"]),
                        right: percent(info["device_batteryLevelRight"]),
                        caseLevel: percent(info["device_batteryLevelCase"]),
                        single: percent(info["device_batteryLevelMain"])
                    )
                    if !levels.isEmpty { return levels }
                }
            }
        }
        return nil
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return nil }
        return Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }
}
