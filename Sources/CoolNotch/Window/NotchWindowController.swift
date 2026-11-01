import AppKit
import SwiftUI

/// Управляет окном чёлки: позиция на экране, наведение мыши, перетаскивание файлов.
@MainActor
final class NotchWindowController {
    static let windowSize = CGSize(width: 820, height: 360)

    private let viewModel: NotchViewModel
    private let chrome = NotchChrome()
    private var previousApp: NSRunningApplication?
    private var panel: NotchPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?

    /// Зажата ли левая кнопка прямо сейчас. Спрашиваем систему, а не запоминаем по событиям:
    /// кнопки окон, переключатели и ползунки «съедают» отпускание кнопки, и чёлка думала,
    /// что кнопка всё ещё зажата, — и не раскрывалась, пока не кликнешь.
    private var mouseIsDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }
    private var dragStartChangeCount = 0
    private var isFileDragging = false
    /// Накопленный горизонтальный сдвиг двумя/тремя пальцами — для переключения карточек.
    private var swipeAccumulator: CGFloat = 0
    private var swipeFired = false

    private let isDemo: Bool

    init(viewModel: NotchViewModel, demo: Bool = false) {
        self.viewModel = viewModel
        self.isDemo = demo
    }

    /// В демо-режиме рисуем всё в двойном масштабе — запись выглядит как на Retina-экране.
    private var scale: CGFloat { isDemo ? 2 : 1 }
    private var windowSize: CGSize { CGSize(width: Self.windowSize.width * scale, height: Self.windowSize.height * scale) }

    func show() {
        let panel = NotchPanel(contentRect: CGRect(origin: .zero, size: windowSize))
        let root = NotchRootView()
            .scaleEffect(scale, anchor: .top)
            .environment(viewModel)
            .environment(\.colorScheme, .dark)
        let hosting = NotchHostingView(rootView: root)
        hosting.sizingOptions = []

        let container = NotchRootContainer(frame: CGRect(origin: .zero, size: windowSize))
        container.wantsLayer = true
        chrome.scale = scale
        chrome.install(in: container, content: hosting)
        panel.contentView = container
        self.panel = panel

        viewModel.motion.host = container
        viewModel.motion.onFrame = { [weak self] frame in
            self?.chrome.render(frame)
        }
        viewModel.onRequestKeyboard = { [weak self] in
            self?.takeKeyboard()
        }

        viewModel.onClose = { [weak self] in self?.resignKeyIfNeeded() }

        reposition()
        chrome.apply(viewModel.chromeState, animated: false)
        chrome.render(viewModel.motion.current)
        observeChromeState()
        panel.orderFrontRegardless()
        if !isDemo { installMonitors() }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        })
        // Пока активен сам Cool Notch (например, только что закрыли настройки), глобальный
        // монитор мыши молчит — тогда следим за курсором опросом.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updatePolling() }
            })
        }
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
        let size = windowSize
        let frame = CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        viewModel.windowFrame = frame
        if isDemo {
            // На машине без выреза рисуем чёлку как у 14-дюймового MacBook Pro.
            viewModel.updateScreen(notchSize: CGSize(width: 185, height: 32), hasNotch: true)
            print("DEMO_WINDOW \(Int(frame.minX)) \(Int(screen.frame.maxY - frame.maxY)) \(Int(frame.width)) \(Int(frame.height)) \(screen.backingScaleFactor) \(Int(screen.frame.width)) \(Int(screen.frame.height))")
            fflush(stdout)
        } else {
            viewModel.updateScreen(notchSize: screen.notchSize, hasNotch: screen.hasNotch)
        }
        chrome.render(viewModel.motion.current)
    }

    // MARK: - Mouse tracking

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            // Монитор вызывается на главном потоке — обходимся без лишних Task на каждое движение мыши.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handle(type, local: false) }
            } else {
                Task { @MainActor in self?.handle(type, local: false) }
            }
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
        // Свайп по чёлке влево/вправо листает то, что играет (музыка, видео…).
        if let swipes = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleSwipe(event) ?? event }
        }) {
            monitors.append(swipes)
        }
    }

    private func handle(_ type: NSEvent.EventType, local: Bool) {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            dragStartChangeCount = NSPasteboard(name: .drag).changeCount
            isFileDragging = false
            // Клик мимо открытой чёлки — закрываем.
            if !local, viewModel.isOpen, !viewModel.hoverZone.contains(NSEvent.mouseLocation) {
                viewModel.close()
            }
        case .leftMouseUp:
            isFileDragging = false
        case .leftMouseDragged:
            let pasteboard = NSPasteboard(name: .drag)
            if !isFileDragging,
               pasteboard.changeCount != dragStartChangeCount,
               pasteboard.types?.contains(.fileURL) == true {
                isFileDragging = true
            }
        default:
            break
        }
        updateHover()
    }

    /// Трёхпальцевый свайп (если он не занят переключением рабочих столов) или горизонтальная
    /// прокрутка двумя пальцами над открытой чёлкой на вкладке «Главная».
    private func handleSwipe(_ event: NSEvent) -> NSEvent? {
        guard viewModel.isOpen, viewModel.tab == .home,
              viewModel.hoverZone.contains(NSEvent.mouseLocation) else { return event }
        if event.type == .swipe {
            guard event.deltaX != 0 else { return event }
            viewModel.swipeDeck(next: event.deltaX > 0)
            return nil
        }
        guard event.hasPreciseScrollingDeltas else { return event }  // только трекпад
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        switch event.phase {
        case .began:
            swipeAccumulator = 0
            swipeFired = false
        case .changed:
            guard !swipeFired, horizontal else { break }
            swipeAccumulator += event.scrollingDeltaX
            if abs(swipeAccumulator) > 45 {
                swipeFired = true
                // Пальцы влево — следующая карточка, как перелистывание на iPhone.
                let fingersLeft = event.isDirectionInvertedFromDevice ? swipeAccumulator < 0 : swipeAccumulator > 0
                viewModel.swipeDeck(next: fingersLeft)
            }
        case .ended, .cancelled:
            swipeAccumulator = 0
        default:
            break
        }
        return horizontal ? nil : event
    }

    private func updateHover() {
        guard let panel else { return }
        let point = NSEvent.mouseLocation
        let inside = viewModel.hoverZone.contains(point)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        if inside {
            // Когда тянут окно или выделяют что-то — не мешаем. Файлы — открываем полку.
            if mouseIsDown && !isFileDragging && !viewModel.isOpen { return }
            viewModel.pointerEntered(fileDrag: isFileDragging)
        } else {
            let editing = viewModel.isTyping || (panel.isKeyWindow && viewModel.tab == .notes)
            if !editing { viewModel.pointerExited() }
        }
        updatePolling()
    }

    /// Пока чёлка открыта, дополнительно опрашиваем мышь — надёжно ловим уход курсора.
    private func updatePolling() {
        if viewModel.isOpen || viewModel.isHovering || NSApp.isActive {
            guard pollTimer == nil else { return }
            pollTimer = Timer.coalesced(interval: 1.0 / 12.0, tolerance: 0.2) { [weak self] in
                self?.updateHover()
            }
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Следим за состоянием оболочки (стекло, тень, эффекты) и передаём его в Core Animation.
    private func observeChromeState() {
        withObservationTracking {
            _ = viewModel.chromeState
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.chrome.apply(self.viewModel.chromeState, animated: true)
                self.observeChromeState()
            }
        }
    }

    /// Чтобы печатать в чёлке (заметка, время таймера), окно должно принимать клавиатуру.
    private func takeKeyboard() {
        guard let panel else { return }
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Возвращаем клавиатурный фокус предыдущему приложению после закрытия.
    private func resignKeyIfNeeded() {
        guard let panel, panel.isKeyWindow || NSApp.isActive else { return }
        panel.makeFirstResponder(nil)
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        } else {
            NSApp.deactivate()
        }
        previousApp = nil
    }
}
