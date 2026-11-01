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

    /// У приложения в строке меню нет меню «Правка», поэтому ⌘X/⌘C/⌘V/⌘A/⌘Z в полях ввода
    /// никуда не доходили. Отправляем их полю напрямую. Клавиши — по коду, чтобы работало
    /// и в русской раскладке (там ⌘V — это «⌘М»).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            let action: Selector?
            switch event.keyCode {
            case 7: action = #selector(NSText.cut(_:))
            case 8: action = #selector(NSText.copy(_:))
            case 9: action = flags.contains(.shift) ? nil : #selector(NSText.paste(_:))
            case 0: action = #selector(NSText.selectAll(_:))
            case 6: action = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
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
