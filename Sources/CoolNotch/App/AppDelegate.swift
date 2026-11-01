import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var viewModel: NotchViewModel?
    private var windowController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        SystemState.start()

        let viewModel = NotchViewModel()
        viewModel.openSettings = { [weak self] in self?.showSettings() }
        self.viewModel = viewModel

        let controller = NotchWindowController(viewModel: viewModel)
        controller.show()
        windowController = controller

        setupStatusItem()
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

    // MARK: - Settings

    func showSettings() {
        viewModel?.close()
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Cool Notch — настройки"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
