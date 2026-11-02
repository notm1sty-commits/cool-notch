import AppKit
import Observation
import SwiftUI

struct NowPlayingTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
}

enum PlayerSource: Hashable {
    case music
    case spotify
    case browser(BrowserKind)
    /// Системный «Что играет» через помощник MediaBridge (любой плеер). Параметр — bundle id плеера.
    case system(String)

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .browser(let kind): return kind.bundleID
        case .system(let bundleID): return bundleID
        }
    }

    /// Браузер, если источник — вкладка (в том числе через системный «Что играет»).
    var browserKind: BrowserKind? {
        switch self {
        case .browser(let kind): return kind
        case .system(let bundleID): return BrowserKind.allCases.first { $0.bundleID == bundleID }
        case .music, .spotify: return nil
        }
    }
}

/// Плеер, который не сообщает название трека (например, приложение Яндекс Музыка),
/// но которым можно управлять медиаклавишами.
struct ExternalPlayer: Equatable {
    let name: String
    let bundleID: String
    let icon: NSImage?
}

/// Карточка в карусели плеера: всё, что сейчас играет или стоит на паузе.
struct MediaItem: Identifiable, Equatable {
    let id: PlayerSource
    var title: String
    var subtitle: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var isPlaying: Bool
    var artwork: NSImage?
    var backdrop: NSImage?
    var accent: NSColor
    var sourceLabel: String
    var sourceIcon: NSImage?
    var isVideo: Bool
    /// Скорость воспроизведения (1 — обычная, 2 — видео на 2x).
    var rate: Double = 1
    /// Повтор; nil — плеер его не поддерживает (кнопки нет).
    var repeatMode: RepeatMode?

    func position(at date: Date) -> Double {
        guard isPlaying else { return elapsed }
        let value = elapsed + date.timeIntervalSince(timestamp) * rate
        return duration > 0 ? min(value, duration) : value
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.duration == rhs.duration && lhs.elapsed == rhs.elapsed && lhs.timestamp == rhs.timestamp
            && lhs.isPlaying == rhs.isPlaying && lhs.artwork === rhs.artwork && lhs.backdrop === rhs.backdrop
            && lhs.sourceLabel == rhs.sourceLabel && lhs.isVideo == rhs.isVideo && lhs.rate == rhs.rate
            && lhs.repeatMode == rhs.repeatMode
    }
}

/// Режим повтора — те же номера, что у системного «Что играет».
enum RepeatMode: Int, Sendable {
    case off = 1
    case one = 2
    case all = 3

    /// Порядок по нажатию: выкл → весь альбом/плейлист → один трек → выкл.
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbol: String { self == .one ? "repeat.1" : "repeat" }

    var help: String {
        switch self {
        case .off: return "Повтор выключен — нажми, чтобы повторять альбом или плейлист"
        case .all: return "Повтор альбома/плейлиста — нажми, чтобы повторять один трек"
        case .one: return "Повтор одного трека — нажми, чтобы выключить"
        }
    }
}

/// Данные для демо-режима.
struct DemoMedia {
    var source: PlayerSource
    var title: String
    var subtitle: String
    var artwork: NSImage?
    var duration: Double
    var elapsed: Double
    var playing: Bool
    var url: String?
}

/// Один источник медиа (Музыка, Spotify, вкладка браузера, системный «Что играет»).
private struct MediaCandidate {
    var source: PlayerSource
    var track: NowPlayingTrack
    var isPlaying: Bool
    var elapsed: Double
    var elapsedTimestamp: Date
    /// Когда источник последний раз запустили, поставили на паузу или сменили трек.
    var lastActivity: Date
    var artworkKey: String
    var artwork: NSImage?
    var tabURL: String?
    var tabTitle: String?
    var pid: pid_t?
    /// Системный «Что играет» сообщает только одно приложение. Прежние источники мы помним
    /// (на паузе), чтобы между YouTube и музыкой можно было переключаться стрелками.
    var isLive = true
    /// Когда источник последний раз прислал данные.
    var lastUpdate = Date()
    /// Скорость воспроизведения: на 2x время в чёлке идёт вдвое быстрее.
    var rate: Double = 1
    /// Пришёл из списка всех клиентов «Что играет» (а не от выбранного системой плеера).
    var fromClients = false
    var repeatMode: RepeatMode?

    func position(at date: Date) -> Double {
        let value = elapsed + (isPlaying ? date.timeIntervalSince(elapsedTimestamp) * rate : 0)
        return track.duration > 0 ? min(value, track.duration) : value
    }
}

private struct ArtworkLook {
    let image: NSImage
    let accent: NSColor
    let backdrop: NSImage?
}

/// Команда, которую только что отдал пользователь: пока источник не подтвердил её,
/// не даём старым данным «переключить» карточку обратно (иначе она мигает).
private struct PendingPlayback {
    var playing: Bool
    var until: Date
}

private enum MediaCommand {
    case toggle, next, previous

    var appleScript: String {
        switch self {
        case .toggle: return "playpause"
        case .next: return "next track"
        case .previous: return "previous track"
        }
    }

    var bridgeCommand: String {
        switch self {
        case .toggle: return "toggle"
        case .next: return "next"
        case .previous: return "prev"
        }
    }

    var key: MediaKeys.Key {
        switch self {
        case .toggle: return .playPause
        case .next: return .next
        case .previous: return .previous
        }
    }

    var remote: MediaRemote.Command {
        switch self {
        case .toggle: return .togglePlayPause
        case .next: return .nextTrack
        case .previous: return .previousTrack
        }
    }
}

/// Следит за всем, что играет: музыка и видео из любых источников.
/// Показываем то, что запустили последним; если всё на паузе — то, что последним поставили на паузу.
@MainActor
@Observable
final class NowPlayingService {
    private(set) var track: NowPlayingTrack?
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    private(set) var accent: Color = .white
    private(set) var accentNSColor: NSColor = .white
    private(set) var source: PlayerSource?
    private(set) var sourceName = ""
    private(set) var sourceIcon: NSImage?
    private(set) var elapsed: Double = 0
    private(set) var elapsedTimestamp = Date()
    private(set) var rate: Double = 1
    private(set) var externalPlayer: ExternalPlayer?
    private(set) var canControlAnyPlayer = false
    private(set) var browserNeedsSetup = false
    /// Все источники для карусели: сначала играющее (последнее запущенное), затем стоящее на паузе.
    private(set) var items: [MediaItem] = []
    /// Что сейчас видит системный «Что играет» — для строки диагностики в настройках.
    private(set) var systemStatus = "Ждём данные…"
    /// Какие приложения вообще сообщают о воспроизведении (режим «все плееры»).
    private(set) var otherPlayersStatus: String?
    var readsAllPlayers: Bool { bridge.readsAllClients }

    @ObservationIgnored var onTrackChange: (@MainActor (NowPlayingTrack) -> Void)?
    /// Почему не получилось управлять карточкой — показывается прямо на ней.
    enum ControlIssue: Equatable {
        /// Браузер не пускает JavaScript — можно включить одной кнопкой.
        case browserJavaScript(BrowserKind)
        /// Включаем пункт в меню браузера.
        case enablingJavaScript
        /// Включить автоматически не вышло — подсказываем, где пункт меню.
        case browserJavaScriptManual(BrowserKind)
        /// macOS не разрешает Halo управлять этим браузером («Автоматизация»).
        case browserAutomation(BrowserKind)
        /// Не нашли вкладку с этим видео.
        case noTab
        /// Браузер ответил ошибкой — показываем её как есть.
        case failed(String)
        /// macOS отдаёт команды только «текущему» плееру, а у этого приложения нет своего управления.
        case notCurrent
    }

    private(set) var controlIssues: [PlayerSource: ControlIssue] = [:]
    /// Нажали «следующий/предыдущий» и ждём новый трек: источник → направление (+1 / −1).
    /// Карточка сразу показывает, что трек меняется, а не стоит как была.
    private(set) var switching: [PlayerSource: Int] = [:]
    /// Куда листали в последний раз — в ту сторону и уезжает старое название.
    private(set) var lastSkipDirection = 1
    @ObservationIgnored private var switchingFrom: [PlayerSource: String] = [:]
    /// Только что перемотали — пока плеер не подтвердил новую позицию, старую он не возвращает.
    @ObservationIgnored private var pendingSeek: [PlayerSource: (target: Double, at: Date)] = [:]
    /// Только что переключили повтор — пока плеер не подтвердил, показываем выбранный режим.
    @ObservationIgnored private var pendingRepeat: [PlayerSource: (mode: RepeatMode, until: Date)] = [:]
    @ObservationIgnored private var switchTimeouts: [PlayerSource: Task<Void, Never>] = [:]
    /// Почему последняя команда вкладке не сработала.
    @ObservationIgnored private var lastBrowserFailure: [PlayerSource: BrowserMediaSource.ControlResult] = [:]
    /// Какой трек мы уже объявляли для каждого источника: баннер только при настоящей смене
    /// трека, а не когда macOS переключает «главный» плеер туда-сюда.
    @ObservationIgnored private var announced: [PlayerSource: String] = [:]
    @ObservationIgnored private var lastAnnouncedTitle = ""
    @ObservationIgnored private var lastAnnouncedAt = Date.distantPast
    /// Какая картинка пришла с каким треком — чтобы распознать «залипшую» обложку.
    @ObservationIgnored private var artworkFingerprints: [PlayerSource: (hash: Int, track: String, album: String)] = [:]
    @ObservationIgnored private var pending: [PlayerSource: PendingPlayback] = [:]
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    private let runner: AppleScriptRunner
    private let browser: BrowserMediaSource
    private let mediaRemote: MediaRemote?
    private let bridge: MediaBridgeProcess
    @ObservationIgnored private var candidates: [PlayerSource: MediaCandidate] = [:]
    @ObservationIgnored private var displayedKey: String?
    @ObservationIgnored private var isDemo = false
    @ObservationIgnored private var distributedObservers: [DistributedObserver] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private let launchDate = Date()
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    /// Цвет и размытый фон для каждой обложки — считаются один раз и общие для свёрнутой
    /// и раскрытой чёлки. Кэш держит саму картинку, поэтому её адрес не может достаться
    /// новой обложке (раньше из-за этого цвет эквалайзера иногда был от другого трека).
    @ObservationIgnored private var looks: [ObjectIdentifier: ArtworkLook] = [:]
    /// Последний цвет обложки каждого источника — пока новая обложка догружается.
    @ObservationIgnored private var lastAccent: [PlayerSource: NSColor] = [:]

    init() {
        runner = AppleScriptRunner()
        browser = BrowserMediaSource(runner: runner)
        mediaRemote = MediaRemote()
        bridge = MediaBridgeProcess()
        canControlAnyPlayer = MediaKeys.isTrusted

        bridge.onEvent = { [weak self] event in
            self?.applyBridge(event)
        }
        if Pref.bool(Pref.systemNowPlaying) { bridge.start() }

        distributedObservers = [
            DistributedObserver(name: "com.apple.Music.playerInfo") { [weak self] in
                Task { @MainActor in self?.refresh(.music) }
            },
            DistributedObserver(name: "com.spotify.client.PlaybackStateChanged") { [weak self] in
                Task { @MainActor in self?.refresh(.spotify) }
            },
        ]

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.appTerminated(bundleID) }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshExternalPlayer() }
        })

        pollTimer = Timer.coalesced(interval: 5, tolerance: 0.3) { [weak self] in
            self?.periodicRefresh()
        }

        refreshExternalPlayer()
        refreshAll()
    }

    // MARK: - Public

    func position(at date: Date) -> Double {
        let duration = track?.duration ?? 0
        guard isPlaying else { return elapsed }
        let value = elapsed + date.timeIntervalSince(elapsedTimestamp) * rate
        return duration > 0 ? min(value, duration) : value
    }

    func togglePlayPause() {
        if let item = items.first { toggle(item) } else { send(.toggle, to: nil) }
    }

    func next() { if let item = items.first { skip(item, forward: true) } else { send(.next, to: nil) } }
    func previous() { if let item = items.first { skip(item, forward: false) } else { send(.previous, to: nil) } }

    func seek(to seconds: Double) {
        if let item = items.first { seek(item, to: seconds) }
    }

    /// Переходит к источнику главной карточки.
    func openSourceApp() {
        if let item = items.first {
            open(item)
        } else if let id = externalPlayer?.bundleID ?? installedPlayers.first?.bundleID {
            openApp(bundleID: id)
        }
    }

    // MARK: - Per-item commands

    /// Пауза/воспроизведение конкретной карточки. Запуск одной ставит остальные на паузу — как в системе,
    /// но только когда она действительно запустилась. Если управлять не получилось, карточка
    /// возвращается в прежнее состояние и объясняет почему (а не «играет» с бегущим временем).
    func toggle(_ item: MediaItem) {
        let willPlay = !item.isPlaying
        let now = Date()
        if isDemo {
            if willPlay {
                for other in items where other.isPlaying && other.id != item.id { markLocal(other.id, playing: false, at: now) }
            }
            markLocal(item.id, playing: willPlay, at: now)
            recompute()
            return
        }

        guard willPlay else {
            markLocal(item.id, playing: false, at: now)
            recompute()
            setPlayback(item.id, playing: false) { [weak self] succeeded in
                guard let self, !succeeded else { return }
                self.commandFailed(item, revertTo: true)
            }
            return
        }

        // Сначала ставим на паузу то, что играет, — пока системная команда ещё попадает именно в него.
        // Если сначала запустить видео, macOS может сделать главным уже его, и «пауза» музыке
        // остановила бы само видео (отсюда и метания «играет музыка / играет видео»).
        let others = items.filter { $0.isPlaying && $0.id != item.id }
        for other in others {
            markLocal(other.id, playing: false, at: now)
            setPlayback(other.id, playing: false)
        }
        markLocal(item.id, playing: true, at: now)
        recompute()

        let start = { [weak self] in
            guard let self else { return }
            self.setPlayback(item.id, playing: true) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    self.controlIssues[item.id] = nil
                    return
                }
                // Не вышло — возвращаем как было: то, что играло, снова играет.
                for other in others {
                    self.markLocal(other.id, playing: true, at: Date())
                    self.setPlayback(other.id, playing: true)
                }
                self.commandFailed(item, revertTo: false)
            }
        }
        if others.isEmpty {
            start()
        } else {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                start()
            }
        }
    }

    /// Команда не дошла: откатываем состояние и показываем причину на карточке.
    private func commandFailed(_ item: MediaItem, revertTo playing: Bool) {
        pending[item.id] = nil
        if var candidate = candidates[item.id] {
            candidate.isPlaying = playing
            candidate.elapsedTimestamp = Date()
            candidates[item.id] = candidate
        }
        if let kind = item.id.browserKind {
            switch lastBrowserFailure[item.id] {
            case .notAuthorized?: controlIssues[item.id] = .browserAutomation(kind)
            case .noTab?: controlIssues[item.id] = .noTab
            case .failed(let message)?: controlIssues[item.id] = .failed(message)
            default: controlIssues[item.id] = .browserJavaScript(kind)
            }
        } else {
            controlIssues[item.id] = .notCurrent
        }
        recompute()
    }

    /// Включает в браузере «Разрешить JavaScript из Apple Events» через его меню (нужны
    /// «Универсальный доступ» и разрешение управлять System Events). После этого видео
    /// во вкладках управляется из чёлки, даже когда «текущий» плеер в системе другой.
    func enableBrowserJavaScript(for item: MediaItem) {
        guard let kind = item.id.browserKind else { return }
        let previous = NSWorkspace.shared.frontmostApplication
        controlIssues[item.id] = .enablingJavaScript
        let script = """
        tell application id "\(kind.bundleID)" to activate
        delay 0.4
        tell application "System Events"
            set p to first application process whose bundle identifier is "\(kind.bundleID)"
            repeat with barItem in menu bar items of menu bar 1 of p
                try
                    repeat with entry in menu items of menu 1 of barItem
                        try
                            set n to name of entry
                            if n is not missing value and n contains "JavaScript" and n contains "Apple" then
                                if (value of attribute "AXMenuItemMarkChar" of entry) is missing value then click entry
                                return "ok"
                            end if
                            repeat with sub in menu items of menu 1 of entry
                                set n2 to name of sub
                                if n2 is not missing value and n2 contains "JavaScript" and n2 contains "Apple" then
                                    if (value of attribute "AXMenuItemMarkChar" of sub) is missing value then click sub
                                    return "ok"
                                end if
                            end repeat
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return "notfound"
        """
        runner.run(script, parse: { $0.stringValue }) { [weak self] result in
            guard let self else { return }
            if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previous.activate()
            }
            guard result == "ok" else {
                self.controlIssues[item.id] = .browserJavaScriptManual(kind)
                return
            }
            // Получилось — сразу выполняем то, что пользователь хотел: запускаем видео.
            for (source, issue) in self.controlIssues where issue == .enablingJavaScript || issue == .browserJavaScript(kind) {
                self.controlIssues[source] = nil
            }
            if let fresh = self.items.first(where: { $0.id == item.id }), !fresh.isPlaying {
                self.toggle(fresh)
            }
        }
    }

    // MARK: - Dismissing a source

    /// Источники, которые убрали крестиком: когда и на каком треке.
    @ObservationIgnored private var dismissed: [PlayerSource: (at: Date, track: String)] = [:]

    /// Крестик на карточке: убрать источник из чёлки. Он вернётся, когда снова заиграет или
    /// сменит трек. Если это «главный» плеер системы (например, Telegram с голосовым), ещё и
    /// останавливаем его — тогда macOS обычно возвращает главным прежний плеер, и им снова
    /// можно управлять из чёлки.
    func dismiss(_ item: MediaItem) {
        guard let candidate = candidates[item.id] else { return }
        dismissed[item.id] = (Date(), Self.trackIdentity(candidate.track))
        controlIssues[item.id] = nil
        if !isDemo, case .system = item.id, candidate.isLive {
            bridge.send("stop")
            scheduleRefresh()
        }
        recompute()
    }

    private func isDismissed(_ candidate: MediaCandidate) -> Bool {
        guard let mark = dismissed[candidate.source] else { return false }
        // Заиграл снова или сменил трек после крестика — показываем опять.
        let startedAgain = candidate.isPlaying && candidate.lastActivity > mark.at.addingTimeInterval(1)
        let otherTrack = Self.trackIdentity(candidate.track) != mark.track
        if startedAgain || otherTrack {
            dismissed[candidate.source] = nil
            return false
        }
        return true
    }

    /// Сразу показываем результат нажатия, не дожидаясь плеера.
    private func markLocal(_ source: PlayerSource, playing: Bool, at now: Date) {
        guard var candidate = candidates[source] else { return }
        candidate.elapsed = candidate.position(at: now)
        candidate.elapsedTimestamp = now
        candidate.isPlaying = playing
        candidate.lastActivity = now
        candidates[source] = candidate
        pending[source] = PendingPlayback(playing: playing, until: now.addingTimeInterval(2.5))
    }

    /// Явная команда play/pause конкретному источнику.
    private func setPlayback(_ source: PlayerSource, playing: Bool, completion: (@MainActor (Bool) -> Void)? = nil) {
        let candidate = candidates[source]
        let bundleID = source.bundleID
        defer { scheduleRefresh() }
        // Музыка и Spotify понимают AppleScript — это точнее системного «Что играет».
        if bundleID == PlayerSource.music.bundleID || bundleID == PlayerSource.spotify.bundleID {
            runner.run("tell application id \"\(bundleID)\" to \(playing ? "play" : "pause")")
            completion?(true)
            return
        }
        // Текущий системный источник — через MediaRemote.
        if case .system = source, candidate?.isLive != false {
            bridge.send(playing ? "play" : "pause")
            completion?(true)
            return
        }
        // Вкладка браузера — через JavaScript в нужной вкладке.
        if let kind = source.browserKind {
            browser.perform(playing ? .play : .pause, in: kind, url: candidate?.tabURL) { [weak self] result in
                self?.lastBrowserFailure[source] = result == .ok ? nil : result
                completion?(result == .ok)
            }
            return
        }
        completion?(false)
    }

    /// Видео — ±10 секунд, музыка — следующий/предыдущий трек.
    func skip(_ item: MediaItem, forward: Bool) {
        if item.isVideo {
            let target = item.position(at: Date()) + (forward ? 10 : -10)
            seek(item, to: max(0, item.duration > 0 ? min(item.duration, target) : target))
        } else if !isDemo {
            beginSwitch(item.id, direction: forward ? 1 : -1)
            send(forward ? .next : .previous, to: item.id)
            burstRefresh(item.id)
        }
    }

    /// Переключить повтор: выкл → альбом/плейлист → один трек. Spotify по AppleScript умеет только вкл/выкл.
    func cycleRepeat(_ item: MediaItem) {
        guard let current = item.repeatMode else { return }
        var mode = current.next
        if item.id == .spotify, mode == .one { mode = .off }
        pendingRepeat[item.id] = (mode, Date().addingTimeInterval(2.5))
        candidates[item.id]?.repeatMode = mode
        recompute()
        switch item.id {
        case .music:
            let name = mode == .off ? "off" : mode == .one ? "one" : "all"
            runner.run("tell application id \"com.apple.Music\" to set song repeat to \(name)")
        case .spotify:
            runner.run("tell application id \"com.spotify.client\" to set repeating to \(mode != .off)")
        case .system:
            bridge.send("repeat \(mode.rawValue)")
        case .browser:
            break
        }
        scheduleRefresh()
    }

    /// Что сообщил плеер о повторе — с учётом только что нажатого (плеер подтверждает не сразу).
    private func reportedRepeat(_ reported: RepeatMode?, for source: PlayerSource) -> RepeatMode? {
        if let pending = pendingRepeat[source] {
            if pending.until > Date(), reported != pending.mode { return pending.mode }
            pendingRepeat[source] = nil
        }
        return reported
    }

    /// Карточка сразу «отпускает» текущий трек; как только придёт новый (или через 1,8 с) — обычный вид.
    private func beginSwitch(_ source: PlayerSource, direction: Int) {
        lastSkipDirection = direction
        switchingFrom[source] = candidates[source].map { Self.trackIdentity($0.track) } ?? ""
        switching[source] = direction
        switchTimeouts[source]?.cancel()
        switchTimeouts[source] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.endSwitch(source)
        }
    }

    private func endSwitch(_ source: PlayerSource) {
        switchTimeouts[source]?.cancel()
        switchTimeouts[source] = nil
        switchingFrom[source] = nil
        if switching[source] != nil { switching[source] = nil }
    }

    /// Сразу после переключения трека чаще спрашиваем плеер — только эти полторы секунды.
    private func burstRefresh(_ source: PlayerSource) {
        switch source {
        case .music, .spotify:
            for delay in [120, 300, 650] {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(delay))
                    self?.refresh(source)
                }
            }
        case .browser:
            bridge.send("burst")
            for delay in [350, 900] {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(delay))
                    self?.pollBrowsers()
                }
            }
        case .system:
            bridge.send("burst")
        }
    }

    func seek(_ item: MediaItem, to seconds: Double) {
        let previous = candidates[item.id].map { ($0.elapsed, $0.elapsedTimestamp) }
        pendingSeek[item.id] = (seconds, Date())
        if var candidate = candidates[item.id] {
            candidate.elapsed = seconds
            candidate.elapsedTimestamp = Date()
            candidates[item.id] = candidate
            recompute()
        }
        if isDemo { return }
        let value = String(format: "%.2f", seconds)
        switch item.id {
        case .music, .spotify:
            runner.run("tell application id \"\(item.id.bundleID)\" to set player position to \(value)")
            scheduleRefresh()
        case .browser(let kind):
            seekInBrowser(item, kind: kind, to: seconds, previous: previous)
        case .system:
            if candidates[item.id]?.isLive != false {
                bridge.send("seek \(value)")
            } else if let kind = item.id.browserKind {
                seekInBrowser(item, kind: kind, to: seconds, previous: previous)
            } else {
                commandFailed(item, revertTo: item.isPlaying)
            }
        }
    }

    private func seekInBrowser(_ item: MediaItem, kind: BrowserKind, to seconds: Double, previous: (Double, Date)?) {
        browser.perform(.seek(seconds), in: kind, url: candidates[item.id]?.tabURL) { [weak self] result in
            guard let self else { return }
            self.lastBrowserFailure[item.id] = result == .ok ? nil : result
            if result == .ok {
                self.controlIssues[item.id] = nil
                self.scheduleRefresh()
            } else {
                self.pendingSeek[item.id] = nil
                if let previous, var candidate = self.candidates[item.id] {
                    candidate.elapsed = previous.0
                    candidate.elapsedTimestamp = previous.1
                    self.candidates[item.id] = candidate
                }
                self.commandFailed(item, revertTo: item.isPlaying)
            }
        }
    }

    /// Переход к источнику: плеер — на передний план, видео в браузере — на нужную вкладку.
    func open(_ item: MediaItem) {
        if isDemo { return }
        let candidate = candidates[item.id]
        if let kind = item.id.browserKind {
            browser.focusTab(in: kind, title: candidate?.tabTitle ?? item.title, url: candidate?.tabURL)
            return
        }
        // Основное приложение по bundle ID (звук мог прийти от вспомогательного процесса), затем по PID.
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.id.bundleID).first
            ?? candidate?.pid.flatMap({ NSRunningApplication(processIdentifier: $0) }) {
            app.activate()
            return
        }
        openApp(bundleID: item.id.bundleID)
    }

    func launch(_ player: PlayerSource) {
        openApp(bundleID: player.bundleID)
    }

    var installedPlayers: [PlayerSource] {
        [PlayerSource.spotify, .music].filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    func displayName(for player: PlayerSource) -> String {
        appInfo(for: player.bundleID).name
    }

    /// Запросить «Универсальный доступ» для медиаклавиш.
    func requestControlAccess() {
        MediaKeys.requestAccess()
        Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if MediaKeys.isTrusted {
                    self.canControlAnyPlayer = true
                    return
                }
            }
        }
    }

    // MARK: - Demo

    func showDemo(_ demo: [DemoMedia]) {
        isDemo = true
        bridge.stop()
        let now = Date()
        candidates = [:]
        for (index, media) in demo.enumerated() {
            var candidate = MediaCandidate(
                source: media.source,
                track: NowPlayingTrack(title: media.title, artist: media.subtitle, album: "", duration: media.duration),
                isPlaying: media.playing,
                elapsed: media.elapsed,
                elapsedTimestamp: now,
                lastActivity: now.addingTimeInterval(-Double(index) * 60),
                artworkKey: "demo|\(media.title)",
                artwork: media.artwork
            )
            candidate.tabURL = media.url
            candidates[media.source] = candidate
        }
        recompute()
    }

    /// Выход из демо: забываем показные карточки и снова слушаем настоящие плееры.
    func endDemo() {
        guard isDemo else { return }
        isDemo = false
        candidates = [:]
        pending = [:]
        controlIssues = [:]
        displayedKey = nil
        recompute()
        if Pref.bool(Pref.systemNowPlaying) { bridge.start() }
        refreshAll()
    }

    func setDemoPlaying(_ source: PlayerSource, _ playing: Bool) {
        guard let item = items.first(where: { $0.id == source }), item.isPlaying != playing else { return }
        toggle(item)
    }

    // MARK: - Commands

    private func send(_ command: MediaCommand, to target: PlayerSource?) {
        switch target {
        case .music?, .spotify?:
            runner.run("tell application id \"\(target?.bundleID ?? "")\" to \(command.appleScript)")
        case .system(let bundleID)? where candidates[target!]?.isLive == false:
            sendToRemembered(command, bundleID: bundleID, tabURL: candidates[target!]?.tabURL)
        case .system?:
            bridge.send(command.bridgeCommand)
        case .browser(let kind)?:
            if command == .toggle {
                browser.perform(.toggle, in: kind, url: target.flatMap { candidates[$0]?.tabURL })
            } else if MediaKeys.isTrusted {
                MediaKeys.post(command.key)
            } else {
                requestControlAccess()
            }
        case nil:
            if MediaKeys.isTrusted {
                MediaKeys.post(command.key)
            } else {
                mediaRemote?.send(command.remote)
                if externalPlayer != nil { requestControlAccess() }
            }
        }
        scheduleRefresh()
    }

    /// Команда источнику, который сейчас не «главный» в системе: адресуем его напрямую.
    private func sendToRemembered(_ command: MediaCommand, bundleID: String, tabURL: String?) {
        if let kind = BrowserKind.allCases.first(where: { $0.bundleID == bundleID }) {
            if command == .toggle {
                browser.perform(.toggle, in: kind, url: tabURL)
            } else {
                browser.focusTab(in: kind, title: "", url: tabURL)
            }
        } else if bundleID == PlayerSource.music.bundleID || bundleID == PlayerSource.spotify.bundleID {
            runner.run("tell application id \"\(bundleID)\" to \(command.appleScript)")
        } else {
            // Приложение без скриптов: выводим его вперёд — дальше система сама сделает его главным.
            openApp(bundleID: bundleID)
        }
    }

    private func scheduleRefresh() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.refreshAll()
        }
    }

    // MARK: - Choosing what to show

    private func upsert(
        _ source: PlayerSource,
        track newTrack: NowPlayingTrack,
        playing: Bool,
        elapsed position: Double,
        timestamp: Date,
        artworkKey: String,
        tabURL: String? = nil,
        tabTitle: String? = nil,
        pid: pid_t? = nil,
        rate: Double? = nil
    ) -> Bool {
        let now = Date()
        var playing = playing
        var position = position
        var timestamp = timestamp
        if let hold = pending[source] {
            if hold.until < now || hold.playing == playing {
                pending[source] = nil
            } else if let current = candidates[source] {
                // Плеер ещё не успел выполнить команду — оставляем то, что нажал пользователь.
                playing = hold.playing
                position = current.elapsed
                timestamp = current.elapsedTimestamp
            }
        }
        // Позиция: плееры часто присылают её с небольшим расхождением или (сразу после перемотки)
        // ещё старую. Мелкие расхождения не трогаем — ползунок не дёргается; старую позицию после
        // перемотки не принимаем, пока плеер не подтвердит новую (или не пройдёт 3 секунды).
        if let existing = candidates[source], existing.track.title == newTrack.title {
            let rate = existing.rate > 0 ? existing.rate : 1
            let reportedNow = position + (playing ? now.timeIntervalSince(timestamp) * rate : 0)
            let currentNow = existing.position(at: now)
            if let seek = pendingSeek[source] {
                let expected = seek.target + (playing ? now.timeIntervalSince(seek.at) * rate : 0)
                if abs(reportedNow - expected) > 1.5, now.timeIntervalSince(seek.at) < 3 {
                    position = existing.elapsed
                    timestamp = existing.elapsedTimestamp
                } else {
                    pendingSeek[source] = nil
                }
            } else if existing.isPlaying == playing, abs(reportedNow - currentNow) < 0.75 {
                position = existing.elapsed
                timestamp = existing.elapsedTimestamp
            }
        } else {
            pendingSeek[source] = nil
        }
        var candidate = candidates[source] ?? MediaCandidate(
            source: source,
            track: newTrack,
            isPlaying: playing,
            elapsed: position,
            elapsedTimestamp: timestamp,
            lastActivity: now,
            artworkKey: ""
        )
        if candidate.isPlaying != playing || candidate.track.title != newTrack.title || candidate.track.artist != newTrack.artist {
            candidate.lastActivity = now
        }
        candidate.track = newTrack
        candidate.lastUpdate = now
        // Пока играет, скорость > 0; на паузе система присылает 0 — тогда оставляем прежнюю.
        if let rate, rate > 0 { candidate.rate = rate }
        candidate.isPlaying = playing
        candidate.elapsed = position
        candidate.elapsedTimestamp = timestamp
        if let tabURL { candidate.tabURL = tabURL }
        if let tabTitle { candidate.tabTitle = tabTitle }
        if let pid { candidate.pid = pid }
        let artworkChanged = candidate.artworkKey != artworkKey
        if artworkChanged {
            candidate.artworkKey = artworkKey
            candidate.artwork = nil
        }
        candidates[source] = candidate
        return artworkChanged
    }

    private func removeCandidate(_ source: PlayerSource) {
        controlIssues[source] = nil
        guard candidates.removeValue(forKey: source) != nil else { return }
        recompute()
    }

    private func setArtwork(_ image: NSImage?, for source: PlayerSource, key: String) {
        guard var candidate = candidates[source], candidate.artworkKey == key else { return }
        candidate.artwork = image
        candidates[source] = candidate
        recompute()
    }

    /// Выбирает, что показать, и обновляет наблюдаемые свойства (только если что-то изменилось).
    private func recompute() {
        // Системный «Что играет» уже знает про Музыку/Spotify — не показываем их дважды.
        // Запомненный системный источник уступает точному (вкладка браузера, AppleScript).
        let liveSystemBundles = Set(candidates.values.compactMap { candidate -> String? in
            if case .system(let id) = candidate.source, candidate.isLive { return id }
            return nil
        })
        let directBundles = Set(candidates.keys.compactMap { key -> String? in
            if case .system = key { return nil }
            return key.bundleID
        })
        var visible = candidates.values.filter { candidate in
            if isDismissed(candidate) { return false }
            if case .system(let id) = candidate.source {
                return candidate.isLive || !directBundles.contains(id)
            }
            return !liveSystemBundles.contains(candidate.source.bundleID)
        }
        // Один и тот же трек из списка всех плееров и от главного плеера — одна карточка.
        let liveTracks = Set(visible.filter { !$0.fromClients || $0.isLive }.map { Self.trackIdentity($0.track) })
        visible.removeAll { $0.fromClients && !$0.isLive && liveTracks.contains(Self.trackIdentity($0.track)) }
        let latest: (MediaCandidate, MediaCandidate) -> Bool = { $0.lastActivity < $1.lastActivity }
        let chosen = visible.filter(\.isPlaying).max(by: latest) ?? visible.max(by: latest)

        let ordered = visible.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.lastActivity > rhs.lastActivity
        }
        // Пришёл новый трек у источника, который листали, — снимаем «переключение» в том же
        // обновлении, что и новые данные: старое название уезжает, новое въезжает одним движением.
        for (source, from) in switchingFrom {
            if let candidate = candidates[source], Self.trackIdentity(candidate.track) != from {
                endSwitch(source)
            }
        }
        let newItems = ordered.map(makeItem)
        if newItems != items { items = newItems }

        guard let chosen else {
            if source != nil || track != nil {
                source = nil
                track = nil
                isPlaying = false
                sourceName = ""
                sourceIcon = nil
                displayedKey = nil
                applyArtwork(nil)
            }
            return
        }

        if source != chosen.source {
            source = chosen.source
            let info = NSRunningApplication.runningApplications(withBundleIdentifier: chosen.source.bundleID).first
                ?? chosen.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            let fallback = appInfo(for: chosen.source.bundleID)
            sourceName = info?.localizedName ?? fallback.name
            sourceIcon = info?.icon ?? fallback.icon
        }
        if isPlaying != chosen.isPlaying { isPlaying = chosen.isPlaying }
        if track != chosen.track { track = chosen.track }
        if elapsed != chosen.elapsed { elapsed = chosen.elapsed }
        if elapsedTimestamp != chosen.elapsedTimestamp { elapsedTimestamp = chosen.elapsedTimestamp }
        if rate != chosen.rate { rate = chosen.rate }
        if artwork !== chosen.artwork { applyArtwork(chosen.artwork) }

        let key = "\(chosen.source.bundleID)|\(chosen.track.title)|\(chosen.track.artist)"
        if key != displayedKey {
            let hadTrack = displayedKey != nil
            displayedKey = key
            // Объявляем трек, только если у этого источника он действительно сменился.
            // Когда macOS перекидывает «главный» плеер между уже знакомыми треками — молчим.
            let isNew = announced[chosen.source] != key
            announced[chosen.source] = key
            // Плееры часто присылают новый трек в два приёма (сначала название, потом исполнитель):
            // то же название в течение 10 секунд второй раз не объявляем.
            let title = chosen.track.title.lowercased()
            let repeated = title == lastAnnouncedTitle && Date().timeIntervalSince(lastAnnouncedAt) < 10
            if isNew, !repeated, chosen.isPlaying, hadTrack || Date().timeIntervalSince(launchDate) > 3 {
                lastAnnouncedTitle = title
                lastAnnouncedAt = Date()
                onTrackChange?(chosen.track)
            }
        }
    }

    private static let sites: [(match: String, name: String, video: Bool)] = [
        ("music.yandex", "Яндекс Музыка", false),
        ("music.youtube.com", "YouTube Music", false),
        ("youtube.com", "YouTube", true),
        ("youtu.be", "YouTube", true),
        ("soundcloud.com", "SoundCloud", false),
        ("vkvideo.ru", "VK Видео", true),
        ("vk.com/video", "VK Видео", true),
        ("vk.com", "VK", false),
        ("rutube.ru", "Rutube", true),
        ("twitch.tv", "Twitch", true),
        ("vimeo.com", "Vimeo", true),
        ("kinopoisk.ru", "Кинопоиск", true),
        ("open.spotify.com", "Spotify", false),
        ("music.apple.com", "Apple Music", false),
    ]

    private func makeItem(_ candidate: MediaCandidate) -> MediaItem {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: candidate.source.bundleID).first
            ?? candidate.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        let info = appInfo(for: candidate.source.bundleID)
        let appName = running?.localizedName ?? (info.name.isEmpty ? "Плеер" : info.name)
        let icon = running?.icon ?? info.icon

        var label = appName
        var isVideo = false
        if candidate.source.browserKind != nil {
            let url = candidate.tabURL?.lowercased() ?? ""
            if let site = Self.sites.first(where: { !url.isEmpty && url.contains($0.match) }) {
                label = "\(site.name) · \(appName)"
                isVideo = site.video
            } else if let artwork = candidate.artwork, artwork.size.height > 0 {
                // Не знаем сайт — угадываем по форме превью: широкое — значит видео.
                isVideo = artwork.size.width / artwork.size.height > 1.25
            }
        }

        let look = candidate.artwork.map(look(for:))
        let backdrop = look?.backdrop
        // Новый трек часто приходит без обложки, и она догружается чуть позже. Чтобы цвет не прыгал
        // в белый и обратно, держим прежний цвет этого источника, пока не придёт новая обложка.
        let accent = look?.accent ?? lastAccent[candidate.source] ?? .white
        if let look { lastAccent[candidate.source] = look.accent }

        let subtitle = [candidate.track.artist, candidate.track.album].filter { !$0.isEmpty }.joined(separator: " — ")
        return MediaItem(
            id: candidate.source,
            title: candidate.track.title,
            subtitle: subtitle,
            duration: candidate.track.duration,
            elapsed: candidate.elapsed,
            timestamp: candidate.elapsedTimestamp,
            isPlaying: candidate.isPlaying,
            artwork: candidate.artwork,
            backdrop: backdrop,
            accent: accent,
            sourceLabel: label,
            sourceIcon: icon,
            isVideo: isVideo,
            rate: candidate.rate,
            repeatMode: isVideo ? nil : candidate.repeatMode
        )
    }

    private func look(for image: NSImage) -> ArtworkLook {
        let key = ObjectIdentifier(image)
        if let cached = looks[key], cached.image === image { return cached }
        if looks.count > 24 { looks.removeAll() }
        let look = ArtworkLook(
            image: image,
            accent: image.averageAccentColor ?? .white,
            backdrop: ArtworkProcessing.backdrop(from: image)
        )
        looks[key] = look
        return look
    }

    private func applyArtwork(_ image: NSImage?) {
        artwork = image
        // Без обложки (догружается) оставляем прежний цвет — эквалайзер не мигает белым.
        guard let image else { return }
        let color = look(for: image).accent
        if color != accentNSColor {
            accentNSColor = color
            accent = Color(nsColor: color)
        }
    }

    // MARK: - Refresh

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private var bridgeHasTrack: Bool {
        candidates.keys.contains { if case .system = $0 { return true } else { return false } }
    }

    private func refreshAll() {
        guard !isDemo else { return }
        if bridgeHasTrack { bridge.send("refresh") }
        for player in [PlayerSource.spotify, .music] {
            if isRunning(player.bundleID) {
                refresh(player)
            } else {
                removeCandidate(player)
            }
        }
        pollBrowsers()
    }

    private func periodicRefresh() {
        guard !SystemState.screensAsleep, !isDemo else { return }
        let trusted = MediaKeys.isTrusted
        if trusted != canControlAnyPlayer { canControlAnyPlayer = trusted }

        // Включаем/выключаем системный «Что играет» по настройке.
        let wantsBridge = Pref.bool(Pref.systemNowPlaying)
        if wantsBridge, !bridge.isEnabled {
            bridge.start()
        } else if !wantsBridge, bridge.isEnabled {
            bridge.stop()
        }

        // Музыку и Spotify опрашиваем только пока они играют (позиция); остальное — по уведомлениям.
        for player in [PlayerSource.spotify, .music] {
            if !isRunning(player.bundleID) {
                removeCandidate(player)
            } else if candidates[player]?.isPlaying == true {
                refresh(player)
            }
        }
        // Браузер не умеет присылать уведомления, поэтому опрашиваем его (если включено).
        // Если системный «Что играет» уже видит браузер — вкладки опрашивать не нужно.
        let systemSeesBrowser = candidates.values.contains { candidate in
            if case .system = candidate.source { return candidate.isLive && candidate.source.browserKind != nil }
            return false
        }
        if !systemSeesBrowser { pollBrowsers() }

        // Запомненные источники держим полчаса после последней активности.
        let stale = candidates.values.filter { !$0.isLive && Date().timeIntervalSince($0.lastActivity) > 30 * 60 }
        stale.map(\.source).forEach(removeCandidate)
    }

    private func refresh(_ player: PlayerSource) {
        // Никогда не запускаем плеер сами: «tell application» открыл бы его.
        guard !isDemo else { return }
        guard isRunning(player.bundleID) else {
            removeCandidate(player)
            return
        }
        runner.run(Self.stateScript(for: player), parse: { AppleScriptRunner.parseSnapshot($0) }) { [weak self] snapshot in
            self?.applySnapshot(snapshot, from: player)
        }
    }

    private func applySnapshot(_ snapshot: PlayerSnapshot?, from player: PlayerSource) {
        guard !isDemo, let snapshot else { return }
        guard snapshot.state != "stopped", !snapshot.title.isEmpty else {
            removeCandidate(player)
            return
        }
        let key = "\(player.bundleID)|\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        let needsArtwork = upsert(
            player,
            track: NowPlayingTrack(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, duration: snapshot.duration),
            playing: snapshot.state == "playing",
            elapsed: snapshot.position,
            timestamp: Date(),
            artworkKey: key
        )
        let repeatMode: RepeatMode?
        switch snapshot.repeatMode?.lowercased() {
        case "one"?: repeatMode = .one
        case "all"?, "true"?: repeatMode = .all
        case "off"?, "false"?: repeatMode = .off
        default: repeatMode = nil
        }
        let confirmedRepeat = reportedRepeat(repeatMode, for: player)
        candidates[player]?.repeatMode = confirmedRepeat
        recompute()
        if needsArtwork { loadArtwork(for: player, url: snapshot.artworkURL, key: key) }
    }

    private func pollBrowsers() {
        guard !isDemo else { return }
        let browserSources = candidates.keys.filter { if case .browser = $0 { return true } else { return false } }
        guard Pref.bool(Pref.browserMusic) else {
            browserSources.forEach(removeCandidate)
            return
        }
        let running = BrowserKind.allCases.filter { isRunning($0.bundleID) }
        guard !running.isEmpty else {
            browserSources.forEach(removeCandidate)
            return
        }
        browser.fetch(from: running) { [weak self] result in
            self?.applyBrowser(result)
        }
    }

    private func applyBrowser(_ result: BrowserFetchResult) {
        guard !isDemo else { return }
        if result.needsSetup != browserNeedsSetup { browserNeedsSetup = result.needsSetup }
        for kind in BrowserKind.allCases {
            let source = PlayerSource.browser(kind)
            guard let media = result.media[kind] else {
                removeCandidate(source)
                continue
            }
            let key = "\(kind.rawValue)|\(media.url)|\(media.title)"
            let needsArtwork = upsert(
                source,
                track: NowPlayingTrack(title: media.title, artist: media.artist, album: media.album, duration: media.duration),
                playing: media.playing,
                elapsed: media.position,
                timestamp: Date(),
                artworkKey: key,
                tabURL: media.url,
                tabTitle: media.tabTitle,
                rate: media.rate
            )
            if needsArtwork { loadArtwork(for: source, url: media.artwork.isEmpty ? nil : media.artwork, key: key) }
        }
        recompute()
    }

    /// Плеер иногда присылает новое название вместе со старой картинкой (музыку сменило видео,
    /// а обложка ещё от трека). Если картинка байт в байт как у прошлого трека, а альбом другой —
    /// это устаревшая обложка: показываем заглушку, пока не придёт настоящая. Треки одного альбома
    /// с общей обложкой это не задевает.
    private func freshArtwork(_ data: Data, for source: PlayerSource, album: String, trackKey: String) -> NSImage? {
        let hash = data.hashValue
        if let previous = artworkFingerprints[source], previous.hash == hash,
           previous.track != trackKey, previous.album != album {
            return nil
        }
        // Та же картинка того же трека пришла ещё раз (например, после перемотки) — оставляем
        // прежнюю: новая копия заставила бы обложку заново проявляться.
        if let previous = artworkFingerprints[source], previous.hash == hash, previous.track == trackKey,
           let current = candidates[source]?.artwork {
            return current
        }
        // Та же картинка уже принадлежит треку другого плеера (видео получило обложку музыки).
        let borrowed = artworkFingerprints.contains { other, fingerprint in
            other != source && fingerprint.hash == hash && fingerprint.album != album
        }
        if borrowed { return nil }
        artworkFingerprints[source] = (hash, trackKey, album)
        return NSImage(data: data)
    }

    /// Все плееры, которые сообщают о воспроизведении, — не только выбранный системой.
    /// Так видно, например, Яндекс Музыку, даже когда «главным» macOS считает браузер.
    private func applyClients(_ clients: [BridgeClientInfo]) {
        var seen = Set<PlayerSource>()
        var changed = false
        for client in clients {
            // Тот же способ, что и для главного плеера: вспомогательный процесс → основное приложение.
            // Иначе одно приложение могло прийти под двумя идентификаторами и стать двумя карточками.
            var bundleID = (client.pid > 0 ? Self.appIdentity(pid: client.pid)?.bundleID : nil) ?? client.bundleID
            if bundleID.hasPrefix("com.apple.WebKit") { bundleID = BrowserKind.safari.bundleID }
            guard bundleID != Bundle.main.bundleIdentifier else { continue }
            let source = PlayerSource.system(bundleID)
            seen.insert(source)
            // Выбранный системой плеер приходит отдельным, более точным сообщением.
            if candidates[source]?.isLive == true { continue }
            let key = "client|\(client.title)|\(client.artist)|\(client.album)"
            let isNew = candidates[source] == nil
            let artworkChanged = upsert(
                source,
                track: NowPlayingTrack(title: client.title, artist: client.artist, album: client.album, duration: client.duration),
                playing: client.rate > 0,
                elapsed: client.elapsed,
                timestamp: client.timestamp > 0 ? Date(timeIntervalSince1970: client.timestamp) : Date(),
                artworkKey: key,
                pid: client.pid > 0 ? client.pid : nil,
                rate: client.rate
            )
            if isNew { candidates[source]?.isLive = false }
            candidates[source]?.fromClients = true
            let clientRepeat = reportedRepeat(client.repeatMode.flatMap(RepeatMode.init(rawValue:)), for: source)
            candidates[source]?.repeatMode = clientRepeat
            if let data = client.artwork {
                // Сначала считаем картинку, потом записываем: freshArtwork сам читает candidates,
                // а запись «candidates[...]?.artwork = …» начинает изменение раньше, чем вычисляет
                // правую часть, — одновременный доступ Swift завершает аварийно.
                let image = freshArtwork(data, for: source, album: client.album, trackKey: key)
                candidates[source]?.artwork = image
            } else if !client.hasArtwork, artworkChanged {
                // Обложки нет у нового трека — убираем; у того же трека она пропадает лишь на миг
                // (перемотка), тогда оставляем прежнюю.
                candidates[source]?.artwork = nil
            } else if artworkChanged {
                candidates[source]?.artwork = nil
            }
            changed = true
        }
        // Клиент пропал из списка (плеер закрыли или он перестал сообщать о треке) — убираем.
        let gone = candidates.values.filter { $0.fromClients && !$0.isLive && !seen.contains($0.source) }.map(\.source)
        for source in gone {
            candidates.removeValue(forKey: source)
            controlIssues[source] = nil
            changed = true
        }
        let names = clients.map { client in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: client.bundleID)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? client.bundleID
        }
        otherPlayersStatus = names.isEmpty ? "никого" : names.joined(separator: ", ")
        if changed { recompute() }
    }

    private func applyBridge(_ event: BridgeEvent) {
        guard !isDemo else { return }
        let systemSources = candidates.keys.filter { if case .system = $0 { return true } else { return false } }
        switch event {
        case .clients(let clients):
            applyClients(clients)
        case .ready:
            systemStatus = "Помощник запущен, ждём трек…"
        case .stopped:
            let reason = bridge.lastError.map { ": \($0)" } ?? ""
            systemStatus = "Помощник остановлен (перезапусков: \(bridge.restarts))\(reason)"
            systemSources.forEach(removeCandidate)
        case .info(let info):
            if info.isEmpty {
                systemStatus = "macOS сообщает: сейчас ничего не играет"
            } else {
                let identity = Self.appIdentity(pid: info.pid)
                let who = identity.map { "\($0.name) (\($0.bundleID))" } ?? "PID \(info.pid)"
                systemStatus = "\(who): \(info.title)\(info.isPlaying ? "" : " — пауза")"
            }
            guard !info.isEmpty else {
                // Источник закрылся (вкладка, плеер) — убираем только живой, запомненные оставляем.
                systemSources.filter { candidates[$0]?.isLive != false }.forEach(removeCandidate)
                return
            }
            var bundleID = Self.appIdentity(pid: info.pid)?.bundleID ?? ""
            // Звук из Safari иногда приходит от процесса WebKit — это всё равно Safari.
            if bundleID.hasPrefix("com.apple.WebKit") { bundleID = BrowserKind.safari.bundleID }
            let source = PlayerSource.system(bundleID)
            // Система сообщает только одно приложение. Прежнее не выкидываем, а запоминаем.
            // Состояние не трогаем сразу: macOS иногда «прыгает» между двумя плеерами, и
            // мгновенная пауза заставляла карточки мигать. Если источник так и не вернулся —
            // через пару секунд считаем его на паузе (см. settleRemembered).
            var switched = false
            for old in systemSources where old != source {
                guard var previous = candidates[old], previous.isLive else { continue }
                previous.isLive = false
                candidates[old] = previous
                switched = true
            }
            candidates[source]?.isLive = true
            controlIssues[source] = nil
            if switched { scheduleSettle() }

            let key = "system|\(info.title)|\(info.artist)|\(info.album)"
            let artworkChanged = upsert(
                source,
                track: NowPlayingTrack(title: info.title, artist: info.artist, album: info.album, duration: info.duration),
                playing: info.isPlaying,
                elapsed: info.elapsed,
                timestamp: info.timestamp > 0 ? Date(timeIntervalSince1970: info.timestamp) : Date(),
                artworkKey: key,
                pid: info.pid > 0 ? info.pid : nil,
                rate: info.rate
            )
            // Браузерные вкладки повтор не поддерживают — кнопку для них не показываем.
            let reported = source.browserKind == nil ? info.repeatMode.flatMap(RepeatMode.init(rawValue:)) : nil
            let confirmedRepeat = reportedRepeat(reported, for: source)
            candidates[source]?.repeatMode = confirmedRepeat
            // Подтягиваем вкладку браузера, если её уже знаем из опроса.
            if let kind = source.browserKind, let tab = candidates[.browser(kind)], tab.track.title == info.title {
                candidates[source]?.tabURL = tab.tabURL
                candidates[source]?.tabTitle = tab.tabTitle
            }
            if let data = info.artwork {
                // См. выше: сначала картинка, потом запись — без одновременного доступа к candidates.
                let image = freshArtwork(data, for: source, album: info.album, trackKey: key)
                candidates[source]?.artwork = image
            } else if !info.hasArtwork, artworkChanged {
                // Пропала обложка у того же трека (бывает на миг при перемотке) — оставляем прежнюю.
                candidates[source]?.artwork = nil
            } else if artworkChanged {
                bridge.send("refresh")
            }
            recompute()
        }
    }

    private static func trackIdentity(_ track: NowPlayingTrack) -> String {
        "\(track.title.lowercased())|\(track.artist.lowercased())"
    }

    /// Приложение, которому принадлежит процесс. Звук часто идёт от вспомогательного процесса
    /// (у Electron-приложений вроде Яндекс Музыки — «… Helper.app» внутри основного), поэтому
    /// поднимаемся до самого внешнего .app — это и есть плеер, который нужно показать и открыть.
    static func appIdentity(pid: Int32) -> (bundleID: String, name: String)? {
        guard pid > 0 else { return nil }
        var path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path
        if path == nil {
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                path = String(cString: buffer)
            }
        }
        guard let path else { return nil }
        let outer: String
        if let range = path.range(of: ".app/") {
            outer = String(path[..<range.lowerBound]) + ".app"
        } else if path.hasSuffix(".app") {
            outer = path
        } else {
            let app = NSRunningApplication(processIdentifier: pid)
            guard let bundleID = app?.bundleIdentifier else { return nil }
            return (bundleID, app?.localizedName ?? bundleID)
        }
        let url = URL(fileURLWithPath: outer)
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: outer).replacingOccurrences(of: ".app", with: "")
        return (bundleID, name)
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12.5))
            guard !Task.isCancelled else { return }
            self?.settleRemembered()
        }
    }

    /// Запомненный источник, от которого давно нет вестей, показываем на паузе.
    private func settleRemembered() {
        let now = Date()
        var changed = false
        for (source, candidate) in candidates where !candidate.isLive && candidate.isPlaying {
            guard now.timeIntervalSince(candidate.lastUpdate) > 12 else { continue }
            var paused = candidate
            paused.elapsed = paused.position(at: now)
            paused.elapsedTimestamp = now
            paused.isPlaying = false
            candidates[source] = paused
            changed = true
        }
        if changed { recompute() }
    }

    private func appTerminated(_ bundleID: String?) {
        refreshExternalPlayer()
        guard let bundleID else { return }
        let gone = candidates.keys.filter { $0.bundleID == bundleID }
        gone.forEach(removeCandidate)
    }

    /// Ищем запущенные плееры, которые не сообщают трек (Яндекс Музыка и т. п.).
    private func refreshExternalPlayer() {
        let app = NSWorkspace.shared.runningApplications.first { app in
            let id = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            return (id.contains("yandex") && id.contains("music"))
                || name.contains("яндекс музыка")
                || name.contains("yandex music")
        }
        let player = app.map {
            ExternalPlayer(name: $0.localizedName ?? "Яндекс Музыка", bundleID: $0.bundleIdentifier ?? "", icon: $0.icon)
        }
        if player != externalPlayer { externalPlayer = player }
    }

    private func openApp(bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }

    private func appInfo(for bundleID: String) -> (name: String, icon: NSImage?) {
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return ("", nil)
        }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        if let cached = iconCache[bundleID] { return (name, cached) }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return (name, icon)
    }

    // MARK: - Artwork

    private func loadArtwork(for player: PlayerSource, url: String?, key: String) {
        switch player {
        case .spotify, .browser:
            guard let url, let link = URL(string: url), link.scheme?.hasPrefix("http") == true else { return }
            URLSession.shared.dataTask(with: link) { data, _, _ in
                let image = data.flatMap { NSImage(data: $0) }
                Task { @MainActor [weak self] in
                    self?.setArtwork(image, for: player, key: key)
                }
            }.resume()
        case .music:
            let script = """
            tell application id "com.apple.Music"
                try
                    return raw data of artwork 1 of current track
                on error
                    return data of artwork 1 of current track
                end try
            end tell
            """
            runner.run(script, parse: { $0.data }) { [weak self] data in
                self?.setArtwork(data.flatMap { NSImage(data: $0) }, for: player, key: key)
            }
        case .system:
            break
        }
    }

    // MARK: - Scripts

    private static func stateScript(for player: PlayerSource) -> String {
        switch player {
        case .music:
            return """
            tell application id "com.apple.Music"
                if player state is stopped then return {"stopped"}
                set t to current track
                return {(player state as string), (name of t), (artist of t), (album of t), (duration of t), (player position), "", (song repeat as string)}
            end tell
            """
        case .spotify:
            return """
            tell application id "com.spotify.client"
                if player state is stopped then return {"stopped"}
                set t to current track
                return {(player state as string), (name of t), (artist of t), (album of t), ((duration of t) / 1000), (player position), (artwork url of t), (repeating as string)}
            end tell
            """
        case .browser, .system:
            return ""
        }
    }
}

/// Подписка на системные (distributed) уведомления, которая работает и когда приложение неактивно.
final class DistributedObserver: NSObject {
    private let handler: () -> Void

    init(name: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(fire(_:)),
            name: Notification.Name(name),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func fire(_ note: Notification) {
        handler()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

extension NSImage {
    /// Усреднённый цвет обложки для эквалайзера и подсветки. Оттенок честный (без «накрутки»
    /// насыщенности, из-за которой тёплые обложки становились красными), только чуть светлее,
    /// чтобы на чёрном было видно. Серые обложки дают мягкий белый.
    var averageAccentColor: NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        // Среднее по пикселям; почти чёрные и почти белые (фон, поля) весят меньше.
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255, g = Double(pixels[index + 1]) / 255, b = Double(pixels[index + 2]) / 255
            let maxValue = max(r, g, b), minValue = min(r, g, b)
            let chroma = maxValue - minValue
            let weight = 0.25 + chroma + (maxValue < 0.12 || minValue > 0.92 ? 0 : 0.35)
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
        }
        guard total > 0 else { return nil }
        let base = NSColor(srgbRed: red / total, green: green / total, blue: blue / total, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.14 { return NSColor(white: 0.9, alpha: 1) }
        return NSColor(
            hue: hue,
            saturation: min(saturation * 1.1, 0.75),
            brightness: max(brightness, 0.82),
            alpha: 1
        )
    }
}
