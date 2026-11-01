import AppKit
import SwiftUI

/// Прозрачная панель поверх строки меню, в которой живёт чёлка.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Хостинг SwiftUI, который реагирует на первый же клик (без «активации» окна).
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
    /// Экран со встроенной чёлкой, иначе — основной.
    static var notchScreen: NSScreen? {
        screens.first { $0.safeAreaInsets.top > 0 } ?? main ?? screens.first
    }

    var hasNotch: Bool { safeAreaInsets.top > 0 }

    /// Размер аппаратной чёлки (или «виртуальной», если её нет).
    var notchSize: CGSize {
        let top = safeAreaInsets.top
        if top > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            return CGSize(width: max(width, 120), height: top)
        }
        let menuBar = frame.maxY - visibleFrame.maxY
        return CGSize(width: 190, height: menuBar > 20 ? menuBar : 30)
    }
}
