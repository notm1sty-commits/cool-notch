import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// «Живая активность» в свёрнутой чёлке.
enum LiveActivity: Equatable {
    case music
    case timer
    case charging
    case lowBattery
    case timerDone
}

enum NotchTab: String, CaseIterable, Identifiable {
    case home, shelf, clipboard, notes

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .notes: return "note.text"
        }
    }

    var title: String {
        switch self {
        case .home: return "Главная"
        case .shelf: return "Полка"
        case .clipboard: return "Буфер обмена"
        case .notes: return "Заметка"
        }
    }
}

@MainActor
@Observable
final class NotchViewModel {
    // MARK: State

    private(set) var isOpen = false
    var tab: NotchTab = .home
    private(set) var notchSize = CGSize(width: 185, height: 32)
    private(set) var hasNotch = true
    var isDropTargeted = false
    var isFileDragActive = false
    private(set) var transient: LiveActivity?
    private(set) var pulse = 0
    @ObservationIgnored private(set) var isPointerInside = false

    // MARK: Services

    let nowPlaying: NowPlayingService
    let battery: BatteryService
    let shelf: ShelfStore
    let clipboard: ClipboardService
    let timer: TimerService

    // MARK: Plumbing

    @ObservationIgnored var windowFrame: CGRect = .zero
    @ObservationIgnored var onClose: (@MainActor () -> Void)?
    @ObservationIgnored var openSettings: (@MainActor () -> Void)?
    @ObservationIgnored private var isPinned = false
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private var transientTask: Task<Void, Never>?

    init() {
        nowPlaying = NowPlayingService()
        battery = BatteryService()
        shelf = ShelfStore()
        clipboard = ClipboardService()
        timer = TimerService()

        battery.onPluggedIn = { [weak self] in
            guard Pref.bool(Pref.showChargingActivity) else { return }
            self?.flash(.charging, for: 3.5)
        }
        battery.onLowBattery = { [weak self] in
            guard Pref.bool(Pref.showLowBattery) else { return }
            self?.flash(.lowBattery, for: 5)
        }
        timer.onFinish = { [weak self] in
            self?.flash(.timerDone, for: 8)
        }
    }

    // MARK: Geometry

    func updateScreen(notchSize: CGSize, hasNotch: Bool) {
        self.notchSize = notchSize
        self.hasNotch = hasNotch
    }

    var activity: LiveActivity? {
        if let transient { return transient }
        if timer.isActive { return .timer }
        if Pref.bool(Pref.showMusicActivity), nowPlaying.isPlaying, nowPlaying.track != nil { return .music }
        return nil
    }

    /// Ширина «ушка» слева и справа от выреза.
    var earWidth: CGFloat {
        guard let activity else { return 0 }
        switch activity {
        case .music: return notchSize.height + 8
        case .timer: return 62
        case .charging, .lowBattery: return 54
        case .timerDone: return 78
        }
    }

    var closedSize: CGSize {
        CGSize(width: notchSize.width + earWidth * 2, height: notchSize.height)
    }

    var openSize: CGSize {
        CGSize(width: max(620, notchSize.width + 420), height: notchSize.height + 160)
    }

    var shapeSize: CGSize { isOpen ? openSize : closedSize }
    var topRadius: CGFloat { isOpen ? 14 : 6 }
    var bottomRadius: CGFloat { isOpen ? 30 : 11 }

    /// Видимая форма чёлки в экранных координатах.
    var shapeRectInScreen: CGRect {
        let size = shapeSize
        let width = size.width + topRadius * 2
        return CGRect(
            x: windowFrame.midX - width / 2,
            y: windowFrame.maxY - size.height,
            width: width,
            height: size.height
        )
    }

    /// Зона, в которой курсор считается «над чёлкой».
    var hoverZone: CGRect {
        let rect = shapeRectInScreen
        if isOpen { return rect.insetBy(dx: -12, dy: -12) }
        // Сверху добавляем запас, чтобы срабатывало при упоре курсора в край экрана.
        return CGRect(x: rect.minX - 6, y: rect.minY - 4, width: rect.width + 12, height: rect.height + 12)
    }

    // MARK: Hover

    func pointerEntered(fileDrag: Bool) {
        isPointerInside = true
        isPinned = false
        closeTask?.cancel()
        closeTask = nil

        if fileDrag {
            guard Pref.bool(Pref.openOnFileDrag) else { return }
            if tab != .shelf { tab = .shelf }
            openTask?.cancel()
            openTask = nil
            open()
            return
        }

        guard !isOpen, openTask == nil else { return }
        let delay = max(0, Pref.double(Pref.hoverDelay))
        openTask = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.openTask = nil
            self?.open()
        }
    }

    func pointerExited() {
        isPointerInside = false
        openTask?.cancel()
        openTask = nil
        guard isOpen, !isPinned, closeTask == nil else { return }
        closeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.closeTask = nil
            self?.close()
        }
    }

    func open(pinned: Bool = false) {
        if pinned { isPinned = true }
        guard !isOpen else { return }
        isOpen = true
        if transient == .timerDone { clearTransient() }
        if Pref.bool(Pref.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    func close() {
        isPinned = false
        openTask?.cancel()
        openTask = nil
        closeTask?.cancel()
        closeTask = nil
        guard isOpen else { return }
        isOpen = false
        isDropTargeted = false
        onClose?()
    }

    // MARK: Transient activities

    func flash(_ activity: LiveActivity, for seconds: Double) {
        transient = activity
        pulse += 1
        transientTask?.cancel()
        transientTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.transient = nil
        }
    }

    func clearTransient() {
        transientTask?.cancel()
        transient = nil
    }

    // MARK: Drops

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        tab = .shelf
        FileDropLoader.loadURLs(from: providers) { [weak self] urls in
            self?.shelf.add(urls)
        }
        return true
    }

    func handleAirDrop(_ providers: [NSItemProvider]) -> Bool {
        FileDropLoader.loadURLs(from: providers) { urls in
            ShelfStore.airDrop(urls)
        }
        return true
    }
}

/// Достаёт файловые URL из перетаскиваемых объектов.
enum FileDropLoader {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []
        func add(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    static func loadURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let collector = Collector()
        let type = UTType.fileURL.identifier
        for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collector.add(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collector.urls
            MainActor.assumeIsolated { completion(urls) }
        }
    }
}
