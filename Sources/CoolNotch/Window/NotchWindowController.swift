import AppKit
import SwiftUI

/// Управляет окном чёлки: позиция на экране, наведение мыши, перетаскивание файлов.
@MainActor
final class NotchWindowController {
    static let windowSize = CGSize(width: 820, height: 360)

    private let viewModel: NotchViewModel
    private var panel: NotchPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?

    private var mouseIsDown = false
    private var dragStartChangeCount = 0
    private var isFileDragging = false

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        let panel = NotchPanel(contentRect: CGRect(origin: .zero, size: Self.windowSize))
        let root = NotchRootView()
            .environment(viewModel)
            .environment(\.colorScheme, .dark)
        let hosting = NotchHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel

        viewModel.onClose = { [weak self] in self?.resignKeyIfNeeded() }

        reposition()
        panel.orderFrontRegardless()
        installMonitors()

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panel?.orderFrontRegardless() }
        })
    }

    func reposition() {
        guard let panel, let screen = NSScreen.notchScreen else { return }
        let size = Self.windowSize
        let frame = CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        viewModel.windowFrame = frame
        viewModel.updateScreen(notchSize: screen.notchSize, hasNotch: screen.hasNotch)
    }

    // MARK: - Mouse tracking

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            Task { @MainActor in self?.handle(type, local: false) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type, local: true) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ type: NSEvent.EventType, local: Bool) {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            mouseIsDown = type == .leftMouseDown
            dragStartChangeCount = NSPasteboard(name: .drag).changeCount
            isFileDragging = false
            // Клик мимо открытой чёлки — закрываем.
            if !local, viewModel.isOpen, !viewModel.hoverZone.contains(NSEvent.mouseLocation) {
                viewModel.close()
            }
        case .leftMouseUp:
            mouseIsDown = false
            isFileDragging = false
            viewModel.isFileDragActive = false
        case .leftMouseDragged:
            let pasteboard = NSPasteboard(name: .drag)
            if !isFileDragging,
               pasteboard.changeCount != dragStartChangeCount,
               pasteboard.types?.contains(.fileURL) == true {
                isFileDragging = true
                viewModel.isFileDragActive = true
            }
        default:
            break
        }
        updateHover()
    }

    private func updateHover() {
        guard let panel else { return }
        let point = NSEvent.mouseLocation
        let inside = viewModel.hoverZone.contains(point)
        panel.ignoresMouseEvents = !inside

        if inside {
            // Когда тянут окно или выделяют что-то — не мешаем. Файлы — открываем полку.
            if mouseIsDown && !isFileDragging && !viewModel.isOpen { return }
            viewModel.pointerEntered(fileDrag: isFileDragging)
        } else {
            let editing = panel.isKeyWindow && viewModel.tab == .notes
            if !editing { viewModel.pointerExited() }
        }
        updatePolling()
    }

    /// Пока чёлка открыта, дополнительно опрашиваем мышь — надёжно ловим уход курсора.
    private func updatePolling() {
        if viewModel.isOpen || viewModel.isPointerInside {
            guard pollTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateHover() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Возвращаем клавиатурный фокус предыдущему приложению после закрытия.
    private func resignKeyIfNeeded() {
        guard let panel, panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }
}
