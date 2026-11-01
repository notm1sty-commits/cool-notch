import AppKit

// Пишем в пайп помощника MediaBridge: если он завершился, ошибка записи не должна ронять приложение.
signal(SIGPIPE, SIG_IGN)

// Точка входа: обычное AppKit-приложение без иконки в Dock (accessory).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
