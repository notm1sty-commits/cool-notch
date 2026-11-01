import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var viewModel: NotchViewModel?
    private var windowController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var demoDirector: DemoDirector?
    private var onboardingWindow: NSWindow?
    /// Приложение, в котором был пользователь до открытия наших окон: вернём ему фокус.
    private var appBeforeWindows: NSRunningApplication?
    private var windowObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        SystemState.start()

        let viewModel = NotchViewModel()
        viewModel.openSettings = { [weak self] in self?.showSettings() }
        self.viewModel = viewModel

        let isDemo = CommandLine.arguments.contains("--demo")
        let controller = NotchWindowController(viewModel: viewModel, demo: isDemo)
        controller.show()
        windowController = controller

        setupStatusItem()
        if !isDemo {
            viewModel.updates.start()
            if !Pref.bool(Pref.onboardingDone) || CommandLine.arguments.contains("--onboarding") {
                // Чуть позже запуска: к этому моменту чёлка уже на месте и приложение готово принять фокус.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showOnboarding() }
            }
        }
        if isDemo {
            let director = DemoDirector(viewModel: viewModel)
            demoDirector = director
            director.run()
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Cool Notch") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "◉"
            }
        }

        let menu = NSMenu()
        menu.addItem(makeItem("Открыть чёлку", #selector(openNotch), ""))
        menu.addItem(makeItem("Настройки…", #selector(showSettingsAction), ","))
        menu.addItem(makeItem("Разрешения…", #selector(showOnboardingAction), ""))
        menu.addItem(makeItem("Проверить обновления…", #selector(checkUpdates), ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Очистить полку", #selector(clearShelf), ""))
        menu.addItem(makeItem("Очистить историю буфера", #selector(clearClipboard), ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Выйти из Cool Notch", #selector(quit), "q"))
        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openNotch() { viewModel?.open(pinned: true) }
    @objc private func showSettingsAction() { showSettings() }
    @objc private func clearShelf() { viewModel?.shelf.clear() }
    @objc private func clearClipboard() { viewModel?.clipboard.clear() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showOnboardingAction() { showOnboarding() }
    @objc private func checkUpdates() {
        viewModel?.updates.check()
        showSettings()
    }

    // MARK: - Settings

    func showSettings() {
        viewModel?.close()
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                notifications: viewModel?.notifications,
                updates: viewModel?.updates,
                nowPlaying: viewModel?.nowPlaying,
                clipboard: viewModel?.clipboard
            ))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Cool Notch — настройки"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            watchClose(of: window)
            settingsWindow = window
        }
        rememberFrontApp()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func rememberFrontApp() {
        guard !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        appBeforeWindows = front
    }

    private func watchClose(of window: NSWindow) {
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in self?.windowClosed(window) }
        })
    }

    /// Закрыли настройки или окно разрешений. Если других наших окон нет, отдаём фокус обратно:
    /// иначе Cool Notch остаётся активным без окон, и macOS перестаёт сообщать о движении мыши.
    private func windowClosed(_ closing: NSWindow?) {
        let stillOpen = [settingsWindow, onboardingWindow].compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
        guard stillOpen.isEmpty else { return }
        if let app = appBeforeWindows, !app.isTerminated {
            app.activate()
        } else {
            NSApp.deactivate()
        }
        appBeforeWindows = nil
    }

    // MARK: - Onboarding

    /// При первом запуске сразу просим все разрешения в одном окне.
    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                onFinish: { [weak self] in
                    Pref.set(true, Pref.onboardingDone)
                    self?.onboardingWindow?.close()
                    self?.viewModel?.clipboard.updateScreenshotWatching()
                    self?.viewModel?.notifications.update(enabled: Pref.bool(Pref.systemNotifications))
                    self?.viewModel?.open(pinned: false)
                },
                bringToFront: { [weak self] in
                    self?.onboardingWindow?.orderFrontRegardless()
                }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Добро пожаловать в Cool Notch"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            watchClose(of: window)
            onboardingWindow = window
        }
        guard let window = onboardingWindow else { return }
        // У приложения без иконки в Dock macOS не всегда отдаёт фокус при запуске, и окно
        // оказывалось под другими. Поэтому поднимаем его над всеми, а через пару секунд
        // возвращаем обычный уровень, чтобы не закрывать Системные настройки.
        window.level = .floating
        rememberFrontApp()
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak window] in
            window?.level = .normal
        }
    }
}
