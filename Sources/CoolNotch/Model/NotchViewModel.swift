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
        /// Иконка приложения по bundle id.
        case app(String)
    }

    enum Action: Equatable {
        case openNotch
        /// Перейти к источнику музыки/видео (плеер или вкладка браузера).
        case openSource
        case openApp(String)
        /// Скачать и поставить обновление.
        case installUpdate
    }

    enum Kind: Equatable {
        case standard
        /// Большая карточка «наушники подключены» с зарядом.
        case airpods(name: String, levels: AirPodsLevels?)
    }

    let id = UUID()
    var icon: Icon
    var tint: Color
    var title: String
    var subtitle: String?
    var duration: TimeInterval = 4
    var action: Action = .openNotch
    /// Две строки текста (для уведомлений с длинным текстом).
    var expanded = false
    var kind: Kind = .standard
    /// Пробежать свечением по контуру при появлении.
    var glows = false
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

    // Оформление (зеркало настроек, чтобы интерфейс сразу реагировал)
    private(set) var glassStyle = true
    private(set) var fxEdgeGlow = true
    private(set) var fx3D = true
    private(set) var fxJelly = true
    private(set) var glassTint: Double = 0.6

    /// Свечение контура: меняется счётчик — пробегает новая волна.
    private(set) var glowTrigger = 0
    private(set) var glowGreen = false

    /// Какая карточка карусели плеера сейчас выбрана.
    private(set) var deckIndex = 0

    /// Геометрия чёлки на пружинной физике.
    let motion: NotchMotion

    // MARK: Services

    let nowPlaying: NowPlayingService
    let battery: BatteryService
    let shelf: ShelfStore
    let clipboard: ClipboardService
    let notes: NotesStore
    let timer: TimerService
    let audio: AudioOutputMonitor
    let notifications: NotificationMirror
    let updates: UpdateService

    // MARK: Plumbing

    @ObservationIgnored var windowFrame: CGRect = .zero
    @ObservationIgnored var onClose: (@MainActor () -> Void)?
    @ObservationIgnored var openSettings: (@MainActor () -> Void)?
    /// Разовые эффекты оболочки (свечение, блик) — их рисует Core Animation.
    @ObservationIgnored var onChromeEvent: (@MainActor (ChromeEvent) -> Void)?
    /// Попросить окно принять ввод с клавиатуры (заметки, таймер).
    @ObservationIgnored var onRequestKeyboard: (@MainActor () -> Void)?
    @ObservationIgnored private var isPinned = false
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private var chargingTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var bannerQueue: [NotchBanner] = []
    @ObservationIgnored private var powerObserver: NSObjectProtocol?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var lastPresentationKind = 0
    @ObservationIgnored private var lastHovering = false
    @ObservationIgnored private var browserHintShown: Set<BrowserKind> = []

    init() {
        motion = NotchMotion()
        nowPlaying = NowPlayingService()
        battery = BatteryService()
        shelf = ShelfStore()
        clipboard = ClipboardService()
        notes = NotesStore()
        timer = TimerService()
        audio = AudioOutputMonitor()
        notifications = NotificationMirror()
        updates = UpdateService()

        updates.onUpdateFound = { [weak self] release in
            self?.post(NotchBanner(
                icon: .symbol("arrow.down.circle.fill"),
                tint: .green,
                title: "Доступно обновление \(release.version)",
                subtitle: "Нажми, чтобы установить — приложение перезапустится само",
                duration: 7,
                action: .installUpdate
            ))
        }

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
        nowPlaying.onBrowserControlUnavailable = { [weak self] kind in
            guard let self, !self.browserHintShown.contains(kind) else { return }
            self.browserHintShown.insert(kind)
            let menu = kind == .safari
                ? "меню «Разработка» → «Разрешить JavaScript из Apple Events»"
                : "меню «Вид» → «Разработчикам» → «Разрешить JavaScript из Apple Events»"
            self.post(NotchBanner(
                icon: .app(kind.bundleID),
                tint: .white,
                title: "Открыл вкладку — нажми там ⏯",
                subtitle: "Чтобы управлять видео прямо из чёлки, пока играет музыка, включи в браузере \(menu).",
                duration: 8,
                expanded: true
            ))
        }
        nowPlaying.onTrackChange = { [weak self] track in
            guard let self, Pref.bool(Pref.trackBanners), !self.isOpen else { return }
            self.post(NotchBanner(
                icon: .artwork,
                tint: self.nowPlaying.accent,
                title: track.title,
                subtitle: track.artist.isEmpty ? self.nowPlaying.sourceName : track.artist,
                duration: 3.2,
                action: .openSource
            ))
        }
        audio.onChange = { [weak self] device, previous in
            self?.audioDeviceChanged(device, previous: previous)
        }
        notifications.onNotification = { [weak self] notification in
            self?.showSystemNotification(notification)
        }
        notifications.update(enabled: Pref.bool(Pref.systemNotifications))
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.notifications.update(enabled: Pref.bool(Pref.systemNotifications))
                self.reloadPrefs()
            }
        }
        reloadPrefs()
        motion.jump(to: targetGeometry)
        observeGeometry()

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

    // MARK: Appearance

    func reloadPrefs() {
        let glass = UserDefaults.standard.string(forKey: Pref.notchStyle) != "black"
        if glass != glassStyle { glassStyle = glass }
        let edge = Pref.bool(Pref.fxEdgeGlow)
        if edge != fxEdgeGlow { fxEdgeGlow = edge }
        let depth = Pref.bool(Pref.fx3D)
        if depth != fx3D { fx3D = depth }
        let jelly = Pref.bool(Pref.fxJelly)
        if jelly != fxJelly { fxJelly = jelly }
        let tint = min(max(Pref.double(Pref.glassTint), 0.05), 0.9)
        if tint != glassTint { glassTint = tint }
    }

    /// Что сейчас должна показывать «оболочка» на Core Animation.
    var chromeState: ChromeState {
        let reduced = lowPower || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return ChromeState(
            lifted: presentation != .closed,
            open: isOpen,
            glassStyle: glassStyle,
            glassTint: CGFloat(glassTint),
            edgeEffects: fxEdgeGlow && !reduced,
            jelly: fxJelly && !reduced,
            notchSize: notchSize
        )
    }

    func requestKeyboard() {
        onRequestKeyboard?()
    }

    /// Пока пользователь печатает (заметка, время таймера), чёлка не сворачивается от ухода курсора.
    @ObservationIgnored private(set) var isTyping = false

    func beginTyping() {
        isTyping = true
        onRequestKeyboard?()
    }

    func endTyping() {
        isTyping = false
    }

    /// Стекло видно, когда чёлка раскрыта или показывает уведомление.
    var isGlassActive: Bool {
        glassStyle && presentation != .closed
    }

    func glow(green: Bool) {
        glowGreen = green
        glowTrigger += 1
        onChromeEvent?(.glow(green: green))
    }

    // MARK: Media deck

    func selectDeck(_ index: Int) {
        let clamped = min(max(index, 0), max(nowPlaying.items.count - 1, 0))
        if clamped != deckIndex { deckIndex = clamped }
    }

    // MARK: Geometry

    var targetGeometry: NotchMotion.Geometry {
        let size = shapeSize
        return NotchMotion.Geometry(width: size.width, height: size.height, bottomRadius: bottomRadius, shoulder: topRadius)
    }

    /// Следим за целевой геометрией и запускаем пружины с подходящим «характером».
    private func observeGeometry() {
        withObservationTracking {
            _ = targetGeometry
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.geometryChanged()
                self.observeGeometry()
            }
        }
    }

    private func geometryChanged() {
        let kind: Int
        switch presentation {
        case .closed: kind = 0
        case .banner: kind = 1
        case .open: kind = 2
        }
        let feel: NotchMotion.Feel
        if kind == 2, lastPresentationKind != 2 {
            feel = .open
        } else if lastPresentationKind == 2, kind != 2 {
            feel = .close
        } else if kind == 0, isHovering != lastHovering {
            feel = .hover
        } else {
            feel = .morph
        }
        lastPresentationKind = kind
        lastHovering = isHovering
        let reduced = lowPower || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        motion.animate(to: targetGeometry, feel: feel, reduced: reduced)
    }

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
        if case .airpods? = banner?.kind {
            return CGSize(width: max(notchSize.width + 250, 440), height: notchSize.height + 150)
        }
        let extra: CGFloat = banner?.expanded == true ? 18 : 0
        return CGSize(width: max(notchSize.width + 270, 456), height: notchSize.height + 62 + extra)
    }

    var openSize: CGSize {
        // Высота подогнана под содержимое плеера (обложка, текст, прогресс, кнопки) без пустых полей.
        CGSize(width: max(672, notchSize.width + 480), height: notchSize.height + 180)
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
        case .banner:
            if case .airpods? = banner?.kind { return 36 }
            return 28
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

        // Курсор на уведомлении — держим его, чтобы можно было прочитать и нажать.
        if banner != nil, !isOpen, !fileDrag {
            bannerTask?.cancel()
            bannerTask = nil
            openTask?.cancel()
            openTask = nil
            return
        }

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
        if banner != nil, bannerTask == nil {
            bannerTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                self?.dismissBanner()
            }
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
        deckIndex = 0
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
        isTyping = false
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
        if newBanner.glows { glow(green: false) }
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

    /// Для демо-режима: «навести» курсор без мыши.
    func demoHover(_ hovering: Bool) {
        if isHovering != hovering { isHovering = hovering }
    }

    func flashCharging() {
        isChargingFlash = true
        pulse += 1
        glow(green: true)
        chargingTask?.cancel()
        chargingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3.5)) } catch { return }
            self?.isChargingFlash = false
        }
    }

    /// Нажатие на уведомление в чёлке.
    func performBannerAction(_ banner: NotchBanner) {
        dismissBanner()
        switch banner.action {
        case .openNotch:
            open(pinned: true)
        case .openSource:
            nowPlaying.openSourceApp()
        case .installUpdate:
            updates.install()
            openSettings?()
        case .openApp(let bundleID):
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            }
        }
    }

    private func showSystemNotification(_ notification: SystemNotification) {
        let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notification.bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? ""
        let title = notification.title.isEmpty ? appName : notification.title
        let text = [notification.subtitle, notification.body].filter { !$0.isEmpty }.joined(separator: " — ")
        guard !title.isEmpty || !text.isEmpty else { return }
        post(NotchBanner(
            icon: .app(notification.bundleID),
            tint: .white,
            title: title.isEmpty ? text : title,
            subtitle: title.isEmpty ? nil : (text.isEmpty ? appName : text),
            duration: 5,
            action: .openApp(notification.bundleID),
            expanded: text.count > 44,
            glows: true
        ))
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
        } else if device.name.localizedCaseInsensitiveContains("airpods") || device.name.localizedCaseInsensitiveContains("beats") {
            showAirPods(name: device.name)
        } else {
            post(NotchBanner(
                icon: .symbol(device.symbol),
                tint: device.isWireless ? Color(red: 0.35, green: 0.68, blue: 1) : .white,
                title: device.name,
                subtitle: device.isWireless ? "Подключено" : "Звук переключён сюда"
            ))
        }
    }

    /// Карточка наушников: сразу показываем, заряд подставляем, как только macOS его отдаст.
    func showAirPods(name: String, levels: AirPodsLevels? = nil) {
        let card = NotchBanner(
            icon: .symbol("airpodspro"),
            tint: .white,
            title: name,
            subtitle: "Подключено к этому Mac",
            duration: 5,
            kind: .airpods(name: name, levels: levels),
            glows: true
        )
        post(card)
        guard levels == nil else { return }
        AirPodsBattery.fetch(deviceName: name) { [weak self] levels in
            guard let self, let levels else { return }
            self.updateBanner(card.id) { $0.kind = .airpods(name: name, levels: levels) }
        }
    }

    private func updateBanner(_ id: UUID, _ change: (inout NotchBanner) -> Void) {
        if var current = banner, current.id == id {
            change(&current)
            banner = current
        } else if let index = bannerQueue.firstIndex(where: { $0.id == id }) {
            change(&bannerQueue[index])
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
