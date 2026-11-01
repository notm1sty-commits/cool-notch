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
        /// «Сейчас играет»: одна живая всплывашка, которая берёт трек из устоявшегося снимка.
        case nowPlaying
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
    /// Название приложения для уведомлений — показывается сверху, как на iPhone, вместе со временем.
    var source: String?
    var date = Date()
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
        case .notes: return "Быстрые заметки"
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
    private(set) var fx3D = true
    private(set) var fxJelly = true
    private(set) var glassTint: Double = 0.6

    /// Свечение контура: меняется счётчик — пробегает новая волна.

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
            self.showLowBattery(level: self.battery.level)
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
        nowPlaying.onTrackChange = { [weak self] _ in
            self?.announceNowPlaying()
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
        observeNowPlaying()

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


    // MARK: Media deck

    /// Низкий заряд: 20 %, 10 % и 5 % — одна и та же всплывашка с процентом, с каждой ступенью
    /// строже: оранжевая подложка, затем красная и почти пустая батарея.
    func showLowBattery(level: Int) {
        let red = Color(red: 1, green: 0.27, blue: 0.23)
        if level <= 5 {
            post(NotchBanner(
                icon: .symbol("battery.0percent"),
                tint: red,
                title: "Критический заряд · \(level)%",
                subtitle: "Mac скоро выключится — подключи зарядку",
                duration: 7
            ))
        } else if level <= 10 {
            post(NotchBanner(
                icon: .symbol("battery.0percent"),
                tint: red,
                title: "Очень низкий заряд · \(level)%",
                subtitle: "Подключи зарядку",
                duration: 6
            ))
        } else {
            post(NotchBanner(
                icon: .symbol("battery.25percent"),
                tint: Color(red: 1, green: 0.62, blue: 0.04),
                title: "Низкий заряд · \(level)%",
                subtitle: "Самое время подключить зарядку",
                duration: 5
            ))
        }
    }

    /// «+» на полке: выбрать файлы в окне Finder, они лягут на полку (оттуда их можно перетащить куда угодно).
    func pickFilesForShelf() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Добавить на полку"
        panel.message = "Выбери файлы — они подождут на полке в чёлке"
        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self, response == .OK, !panel.urls.isEmpty else { return }
            withAnimation(Theme.content) { self.shelf.add(panel.urls) }
            // Показываем полку с новыми файлами; клик мимо чёлки её закроет.
            self.select(.shelf)
            self.open(pinned: true)
        }
    }

    /// «+» у AirDrop: выбрать файлы и сразу отправить их по AirDrop.
    func pickFilesForAirDrop() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Отправить по AirDrop"
        panel.message = "Выбери, что отправить по AirDrop"
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            ShelfStore.airDrop(panel.urls)
        }
    }

    /// Свайп по чёлке — сквозное перелистывание: на «Главной» сначала карточки плеера,
    /// а за последней (или перед первой) — соседние разделы: Главная → Полка → Буфер → Заметки.
    func swipe(next: Bool) {
        let step = next ? 1 : -1
        if tab == .home {
            let target = deckIndex + step
            if target >= 0, target < nowPlaying.items.count {
                selectDeck(target)
                swipeFeedback()
                return
            }
        }
        let tabs = NotchTab.allCases
        guard let index = tabs.firstIndex(of: tab), tabs.indices.contains(index + step) else { return }
        withAnimation(Theme.content) { select(tabs[index + step]) }
        swipeFeedback()
    }

    private func swipeFeedback() {
        if Pref.bool(Pref.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

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
        case .charging: return 84
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

    /// Сколько занимает содержимое текущей всплывашки (оно меряет себя само, см. BannerContentHeight).
    var bannerContentHeight: CGFloat?
    /// Когда появилась текущая всплывашка — пока она проявляется, наведение её не раскрывает.
    @ObservationIgnored private var bannerShownAt = Date.distantPast

    /// Естественная ширина строки текущей всплывашки (меряет себя сама, см. BannerIdealWidth).
    var bannerContentWidth: CGFloat?

    /// Всплывашка обнимает содержимое: строка + по 20 pt с боков, без пустого чёрного по краям.
    /// Не уже выреза с запасом и не шире раскрытой чёлки (длинный текст обрежется многоточием).
    private var bannerWidth: CGFloat {
        // Карточка наушников: ширина по числу колец заряда — без замеров, чтобы не «сжималась»,
        // пока заряд ещё грузится.
        if case .airpods(_, let levels)? = banner?.kind {
            let rings = [levels?.left, levels?.right, levels?.caseLevel, levels?.left == nil ? levels?.single : nil]
                .compactMap { $0 }.count
            let batteries = rings == 0 ? 20 : CGFloat(rings) * 30 + CGFloat(rings - 1) * 12
            // 16 + значок 44 + 12 + текст ~150 + 10 + кольца + 16
            return max(notchSize.width + 24, 248 + batteries)
        }
        // Не уже выреза (с небольшим запасом), чтобы короткое название не давало широких полей.
        let minimum = notchSize.width + 24
        let maximum = openSize.width - 40
        let fallback: CGFloat = 380
        let natural = (bannerContentWidth ?? fallback) + BannerContentHeight.sideGap * 2
        return min(max(natural, minimum), maximum)
    }

    var bannerSize: CGSize {
        // Пока содержимое не измерено — близкая оценка, потом форма подстроится точно.
        let estimate: CGFloat
        if case .airpods? = banner?.kind {
            estimate = 70
        } else {
            estimate = 70 + (banner?.expanded == true ? 16 : 0) + (banner?.source != nil ? 14 : 0)
        }
        return CGSize(width: bannerWidth, height: notchSize.height + (bannerContentHeight ?? estimate))
    }

    var openSize: CGSize {
        // Высота подогнана под содержимое плеера (обложка, текст, прогресс, кнопки) без пустых полей.
        CGSize(width: max(672, notchSize.width + 480), height: notchSize.height + Theme.playerHeight + 42)
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

        // Курсор на всплывашке: держим её (можно прочитать и нажать), а если курсор задержался —
        // раскрываем чёлку, как обычно. Быстрый клик успевает раньше и открывает уведомление.
        if banner != nil, !isOpen, !fileDrag {
            bannerTask?.cancel()
            bannerTask = nil
            guard openTask == nil else { return }
            // Лок: раскрываем не раньше, чем закончится анимация появления всплывашки.
            let appearDone = bannerShownAt.addingTimeInterval(0.9).timeIntervalSinceNow
            let delay = max(0.5, Pref.double(Pref.hoverDelay), appearDone)
            openTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.openTask = nil
                self?.open()
            }
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

    // MARK: Now playing banner

    /// Трек, который показывает всплывашка «Сейчас играет». Обновляется только когда данные
    /// «устоялись» (~0,35 с без изменений), и всё сразу — название, исполнитель и обложка.
    /// Поэтому при быстром переключении треков всплывашка не собирает кусочки разных треков.
    struct NowPlayingSnapshot: Equatable {
        var title: String
        /// Исполнитель, а если его нет — альбом.
        var detail: String
        var artwork: NSImage?
        var isVideo: Bool
        var appName: String
        var appColor: NSColor

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.artwork === rhs.artwork
                && lhs.isVideo == rhs.isVideo && lhs.appName == rhs.appName && lhs.appColor == rhs.appColor
        }
    }

    private(set) var nowPlayingSnapshot: NowPlayingSnapshot?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var announceTask: Task<Void, Never>?

    private func currentSnapshot() -> NowPlayingSnapshot? {
        guard let track = nowPlaying.track else { return nil }
        let bundleID = nowPlaying.source?.bundleID ?? ""
        return NowPlayingSnapshot(
            title: track.title,
            detail: track.artist.isEmpty ? track.album : track.artist,
            artwork: nowPlaying.artwork,
            isVideo: nowPlaying.items.first?.isVideo == true,
            appName: nowPlaying.sourceName,
            appColor: AppColorCache.color(for: bundleID, icon: nowPlaying.sourceIcon)
        )
    }

    private func observeNowPlaying() {
        withObservationTracking {
            _ = nowPlaying.track
            _ = nowPlaying.artwork
            _ = nowPlaying.sourceName
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.nowPlayingChanged()
                self?.observeNowPlaying()
            }
        }
    }

    private func nowPlayingChanged() {
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            let fresh = self.currentSnapshot()
            if fresh != self.nowPlayingSnapshot { self.nowPlayingSnapshot = fresh }
        }
    }

    /// Новый трек: показать «Сейчас играет» — или, если она уже на экране (быстро листают треки),
    /// просто обновить её и продлить, а не выпускать новую следом.
    private func announceNowPlaying() {
        guard Pref.bool(Pref.trackBanners), !isOpen else { return }
        announceTask?.cancel()
        announceTask = Task { @MainActor [weak self] in
            // Плееры присылают трек по кусочкам (название, потом исполнитель, потом обложка) — ждём.
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled, !self.isOpen else { return }
            self.snapshotTask?.cancel()
            self.nowPlayingSnapshot = self.currentSnapshot()
            if self.banner?.kind == .nowPlaying {
                self.extendBanner(by: 3.2)
                return
            }
            if self.bannerQueue.contains(where: { $0.kind == .nowPlaying }) { return }
            self.post(NotchBanner(
                icon: .artwork,
                tint: .white,
                title: self.nowPlayingSnapshot?.title ?? "",
                duration: 3.2,
                action: .openSource,
                kind: .nowPlaying
            ))
        }
    }

    private func extendBanner(by seconds: TimeInterval) {
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.dismissBanner()
        }
    }

    private func show(_ newBanner: NotchBanner) {
        bannerContentHeight = nil
        bannerContentWidth = nil
        bannerShownAt = Date()
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

    /// Для демо-режима: «навести» курсор без мыши.
    func demoHover(_ hovering: Bool) {
        if isHovering != hovering { isHovering = hovering }
    }

    func flashCharging() {
        isChargingFlash = true
        pulse += 1
        chargingTask?.cancel()
        chargingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3.5)) } catch { return }
            self?.isChargingFlash = false
        }
    }

    /// Нажатие на уведомление в чёлке.
    func performBannerAction(_ banner: NotchBanner) {
        // Кликнули — не раскрываем чёлку следом.
        openTask?.cancel()
        openTask = nil
        dismissBanner()
        switch banner.action {
        case .openNotch:
            open(pinned: true)
        case .openSource:
            nowPlaying.openSourceApp()
        case .installUpdate:
            updates.install()
            UserDefaults.standard.set(SettingsPage.updates.rawValue, forKey: "settingsPage")
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
        var text = [notification.subtitle, notification.body].filter { !$0.isEmpty }.joined(separator: " — ")
        // Совсем без текста (приложение спрятало содержимое) — всё равно показываем, от кого.
        if text.isEmpty && !appName.isEmpty { text = "Новое уведомление" }
        guard !title.isEmpty || !text.isEmpty else { return }
        post(NotchBanner(
            icon: .app(notification.bundleID),
            tint: .white,
            title: title.isEmpty ? text : title,
            subtitle: title.isEmpty ? nil : (text.isEmpty ? appName : text),
            duration: 5,
            action: .openApp(notification.bundleID),
            expanded: text.count > 44,
            source: appName.isEmpty ? nil : appName,
            date: notification.date
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
        } else if device.isWireless {
            // Любые беспроводные наушники и колонки — одна карточка; заряд, если устройство его сообщает.
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
            // Заряда нет — убираем ожидание, карточка просто скажет «Подключено».
            self?.updateBanner(card.id) { $0.kind = .airpods(name: name, levels: levels ?? AirPodsLevels()) }
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

/// Цвет приложения для подписи «Сейчас играет · Приложение». По умолчанию — средний цвет
/// иконки, посчитанный один раз и запомненный в настройках. Пользователь может задать свой
/// цвет в настройках («Плеер» → «Цвета приложений») или сбросить всё.
@MainActor
enum AppColorCache {
    private static let key = "appIconColors"
    private static let overridesKey = "appColorOverrides"
    private static var memory: [String: NSColor] = [:]

    static func color(for bundleID: String, icon: NSImage?) -> NSColor {
        if let custom = stored(overridesKey)[bundleID] { return custom }
        if let cached = memory[bundleID] { return cached }
        if let saved = stored(key)[bundleID] {
            memory[bundleID] = saved
            return saved
        }
        guard !bundleID.isEmpty else { return .white }
        let image = icon ?? appIcon(bundleID)
        guard let color = image?.averageAccentColor?.usingColorSpace(.sRGB) else { return .white }
        memory[bundleID] = color
        save(color, for: bundleID, in: key)
        return color
    }

    /// Приложения, для которых цвет уже известен, — для списка в настройках.
    static var knownApps: [String] {
        Array(Set(stored(key).keys).union(stored(overridesKey).keys)).sorted { displayName($0) < displayName($1) }
    }

    static func isCustom(_ bundleID: String) -> Bool {
        stored(overridesKey)[bundleID] != nil
    }

    static func setCustom(_ color: NSColor, for bundleID: String) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return }
        save(srgb, for: bundleID, in: overridesKey)
    }

    static func clearCustom(for bundleID: String) {
        var all = UserDefaults.standard.dictionary(forKey: overridesKey) ?? [:]
        all[bundleID] = nil
        UserDefaults.standard.set(all, forKey: overridesKey)
    }

    /// «Сбросить цвета плееров»: забываем и посчитанные, и заданные вручную — посчитаются заново.
    static func resetAll() {
        memory.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: overridesKey)
    }

    static func displayName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID
    }

    static func appIcon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private static func stored(_ key: String) -> [String: NSColor] {
        let raw = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        var result: [String: NSColor] = [:]
        for (bundleID, value) in raw {
            guard let rgb = value as? [Double], rgb.count == 3 else { continue }
            result[bundleID] = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        }
        return result
    }

    private static func save(_ color: NSColor, for bundleID: String, in key: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[bundleID] = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
        UserDefaults.standard.set(all, forKey: key)
    }
}
