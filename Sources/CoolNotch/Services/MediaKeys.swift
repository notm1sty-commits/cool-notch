import AppKit
import ApplicationServices

/// Управление любым плеером (Яндекс Музыка, браузер и т. д.) через системные медиаклавиши ⏯ ⏭ ⏮.
/// Чтобы macOS пропускала такие нажатия, нужно разрешение «Универсальный доступ».
@MainActor
enum MediaKeys {
    enum Key: Int {
        case playPause = 16
        case next = 17
        case previous = 18
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос на «Универсальный доступ».
    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func post(_ key: Key) {
        for isDown in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xA00 : 0xB00)
            let data1 = (key.rawValue << 16) | ((isDown ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
