import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// «Живая активность» по бокам от выреза в свёрнутой чёлке.
enum LiveActivity: Equatable {
    case music
    case timer
    case charging
}

/// Уведомление, которое «выезжает» из чёлки и через пару секунд прячется обратно.
struct NotchBanner: Identifiable, Equatable {
    enum Icon: Equatable {
        case symbol(String)
        case artwork
    }

    let id = UUID()
    var icon: Icon
    var tint: Color
    var title: String
    var subtitle: String?
    var duration: TimeInterval = 4
}

enum NotchTab: String, CaseIterable, Identifiable {
    case home, shelf, clipboard, notes

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "music.note.house.fill"
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

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

enum NotchPresentation: Equatable {
    case closed
    case banner(NotchBanner)
    case open
}

@MainActor
@Observable
final class NotchViewModel {
    // MARK: State

    private(set) var isOpen = false
    private(set) var tab: NotchTab = .home
    private(set) var tabDirection: CGFloat = 1
    private(set) var notchSize = CGSize(width: 185, height: 32)
    private(set) var hasNotch = true
    private(set) var isHovering = false
    private(set) var banner: NotchBanner?
    private(set) var isChargingFlash = false
    private(set) var pulse = 0
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    var isDropTargeted = false

    // MARK: Services

    let nowPlaying: NowPlayingService
    let battery: BatteryService
    let shelf: ShelfStore
    let clipboard: ClipboardService
    let timer: TimerService
    let audio: AudioOutputMonitor

    // MARK: Plumbing

    @ObservationIgnored var windowFrame: CGRect = .zero
    @ObservationIgnored var onClose: (@MainActor () -> Void)?
    @ObservationIgnored var openSettings: (@MainActor () -> Void)?
    @ObservationIgnored private var isPinned = false
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private var chargingTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var bannerQueue: [NotchBanner] = []
    @ObservationIgnored private var powerObserver: NSObjectProtocol?

    init() {
        nowPlaying = NowPlayingService()
        battery = BatteryService()
        shelf = ShelfStore()
        clipboard = ClipboardService()
        timer = TimerService()
        audio = AudioOutputMonitor()

        battery.onPluggedIn = { [weak self] in
            guard Pref.bool(Pref.showChargingActivity) else { return }
            self?.flashCharging()
        }
        battery.onLowBattery = { [weak self] in
            guard let self, Pref.bool(Pref.showLowBattery) else { return }
            self.post(NotchBanner(
                icon: .symbol("battery.25percent"),
                tint: .red,
                title: "Низкий заряд",
                subtitle: "Осталось \(self.battery.level)% — пора на зарядку",
                duration: 5
            ))
        }
        timer.onFinish = { [weak self] minutes in
            self?.post(NotchBanner(
                icon: .symbol("bell.fill"),
                tint: .orange,
                title: "Таймер завершён",
                subtitle: minutes > 0 ? "Прошло \(minutes) мин" : nil,
                duration: 6
            ))
        }
        nowPlaying.onTrackChange = { [weak self] track in
            guard let self, Pref.bool(Pref.trackBanners), !self.isOpen else { return }
            self.post(NotchBanner(
                icon: .artwork,
                tint: self.nowPlaying.accent,
                title: track.title,
                subtitle: track.artist.isEmpty ? nil : track.artist,
                duration: 3.2
            ))
        }
        audio.onChange = { [weak self] device, previous in
            self?.audioDeviceChanged(device, previous: previous)
        }

        powerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let value = SystemState.isLowPowerMode
                if value != self.lowPower { self.lowPower = value }
            }
        }
    }

    // MARK: Geometry

    func updateScreen(notchSize: CGSize, hasNotch: Bool) {
        if self.notchSize != notchSize { self.notchSize = notchSize }
        if self.hasNotch != hasNotch { self.hasNotch = hasNotch }
    }

    var presentation: NotchPresentation {
        if isOpen { return .open }
        if let banner { return .banner(banner) }
        return .closed
    }

    var activity: LiveActivity? {
        if isChargingFlash { return .charging }
        if timer.isActive { return .timer }
        if Pref.bool(Pref.showMusicActivity), nowPlaying.isPlaying, nowPlaying.track != nil { return .music }
        return nil
    }

    /// Ширина «ушка» слева и справа от выреза.
    var earWidth: CGFloat {
        guard let activity else { return 0 }
        switch activity {
        case .music: return notchSize.height + 6
        case .timer: return 64
        case .charging: return 56
        }
    }

    var closedSize: CGSize {
        var size = CGSize(width: notchSize.width + earWidth * 2, height: notchSize.height)
        if isHovering {
            // Лёгкое «предвкушение»: чёлка чуть подрастает под курсором.
            size.width += 18
            size.height += 4
        }
        return size
    }

    var bannerSize: CGSize {
        CGSize(width: max(notchSize.width + 240, 420), height: notchSize.height + 56)
    }

    var openSize: CGSize {
        CGSize(width: max(640, notchSize.width + 450), height: notchSize.height + 176)
    }

    var shapeSize: CGSize {
        switch presentation {
        case .open: return openSize
        case .banner: return bannerSize
        case .closed: return closedSize
        }
    }

    var topRadius: CGFloat {
        switch presentation {
        case .open: return 14
        case .banner: return 10
        case .closed: return 6
        }
    }

    var bottomRadius: CGFloat {
        switch presentation {
        case .open: return Theme.openRadius
        case .banner: return 26
        case .closed: return isHovering ? 14 : 11
        }
    }

    /// Видимая форма чёлки в экранных координатах.
    var shapeRectInScreen: CGRect {
        let size = shapeSize
        let width = size.width + topRadius * 2
        return CGRect(x: windowFrame.midX - width / 2, y: windowFrame.maxY - size.height, width: width, height: size.height)
    }

    /// Зона, в которой курсор считается «над чёлкой».
    var hoverZone: CGRect {
        let rect = shapeRectInScreen
        if isOpen { return rect.insetBy(dx: -12, dy: -12) }
        return CGRect(x: rect.minX - 6, y: rect.minY - 4, width: rect.width + 12, height: rect.height + 12)
    }

    // MARK: Tabs

    func select(_ newTab: NotchTab) {
        guard newTab != tab else { return }
        tabDirection = newTab.index > tab.index ? 1 : -1
        tab = newTab
    }

    // MARK: Hover

    func pointerEntered(fileDrag: Bool) {
        if !isHovering { isHovering = true }
        isPinned = false
        closeTask?.cancel()
        closeTask = nil

        if fileDrag {
            guard Pref.bool(Pref.openOnFileDrag) else { return }
            select(.shelf)
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
        if isHovering { isHovering = false }
        if openTask != nil {
            openTask?.cancel()
            openTask = nil
        }
        guard isOpen, !isPinned, closeTask == nil else { return }
        closeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.closeTask = nil
            self?.close()
        }
    }

    func open(pinned: Bool = false) {
        if pinned { isPinned = true }
        guard !isOpen else { return }
        bannerTask?.cancel()
        bannerQueue.removeAll()
        banner = nil
        isOpen = true
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

    // MARK: Banners & activities

    func post(_ newBanner: NotchBanner) {
        guard !isOpen else { return }
        if banner == nil {
            show(newBanner)
        } else {
            bannerQueue.append(newBanner)
            if bannerQueue.count > 3 { bannerQueue.removeFirst() }
        }
    }

    private func show(_ newBanner: NotchBanner) {
        banner = newBanner
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(newBanner.duration)) } catch { return }
            self?.dismissBanner()
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        banner = nil
        guard !bannerQueue.isEmpty else { return }
        let next = bannerQueue.removeFirst()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.banner == nil, !self.isOpen else { return }
            self.show(next)
        }
    }

    private func flashCharging() {
        isChargingFlash = true
        pulse += 1
        chargingTask?.cancel()
        chargingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3.5)) } catch { return }
            self?.isChargingFlash = false
        }
    }

    private func audioDeviceChanged(_ device: AudioOutputDevice, previous: AudioOutputDevice?) {
        guard Pref.bool(Pref.deviceBanners) else { return }
        if device.isBuiltIn {
            // Наушники отключились — звук вернулся на динамики Mac.
            guard let previous, !previous.isBuiltIn else { return }
            post(NotchBanner(
                icon: .symbol(previous.symbol),
                tint: .white,
                title: previous.name,
                subtitle: "Отключено · звук через динамики Mac"
            ))
        } else {
            post(NotchBanner(
                icon: .symbol(device.symbol),
                tint: device.isWireless ? Color(red: 0.35, green: 0.68, blue: 1) : .white,
                title: device.name,
                subtitle: device.isWireless ? "Подключено" : "Звук переключён сюда"
            ))
        }
    }

    // MARK: Drops

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        select(.shelf)
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
