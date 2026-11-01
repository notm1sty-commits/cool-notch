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

    func position(at date: Date) -> Double {
        guard isPlaying else { return elapsed }
        let value = elapsed + date.timeIntervalSince(timestamp)
        return duration > 0 ? min(value, duration) : value
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.duration == rhs.duration && lhs.elapsed == rhs.elapsed && lhs.timestamp == rhs.timestamp
            && lhs.isPlaying == rhs.isPlaying && lhs.artwork === rhs.artwork && lhs.backdrop === rhs.backdrop
            && lhs.sourceLabel == rhs.sourceLabel && lhs.isVideo == rhs.isVideo
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
    private(set) var externalPlayer: ExternalPlayer?
    private(set) var canControlAnyPlayer = false
    private(set) var browserNeedsSetup = false
    /// Все источники для карусели: сначала играющее (последнее запущенное), затем стоящее на паузе.
    private(set) var items: [MediaItem] = []

    @ObservationIgnored var onTrackChange: (@MainActor (NowPlayingTrack) -> Void)?

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
    @ObservationIgnored private var backdropCache: [ObjectIdentifier: NSImage] = [:]
    @ObservationIgnored private var accentCache: [ObjectIdentifier: NSColor] = [:]

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
        let value = elapsed + date.timeIntervalSince(elapsedTimestamp)
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

    /// Пауза/воспроизведение конкретной карточки. Запуск одной ставит остальные на паузу — как в системе.
    func toggle(_ item: MediaItem) {
        let willPlay = !item.isPlaying
        if willPlay {
            for other in items where other.isPlaying && other.id != item.id {
                pause(other.id)
            }
        }
        if var candidate = candidates[item.id] {
            let now = Date()
            candidate.elapsed = item.position(at: now)
            candidate.elapsedTimestamp = now
            candidate.isPlaying = willPlay
            candidate.lastActivity = now
            candidates[item.id] = candidate
            recompute()
        }
        if isDemo { return }
        send(.toggle, to: item.id)
    }

    /// Видео — ±10 секунд, музыка — следующий/предыдущий трек.
    func skip(_ item: MediaItem, forward: Bool) {
        if item.isVideo {
            let target = item.position(at: Date()) + (forward ? 10 : -10)
            seek(item, to: max(0, item.duration > 0 ? min(item.duration, target) : target))
        } else if !isDemo {
            send(forward ? .next : .previous, to: item.id)
        }
    }

    func seek(_ item: MediaItem, to seconds: Double) {
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
            browser.perform(.seek(seconds), in: kind, url: candidates[item.id]?.tabURL)
            scheduleRefresh()
        case .system:
            bridge.send("seek \(value)")
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
        if let pid = candidate?.pid, let app = NSRunningApplication(processIdentifier: pid) {
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

    func setDemoPlaying(_ source: PlayerSource, _ playing: Bool) {
        guard let item = items.first(where: { $0.id == source }), item.isPlaying != playing else { return }
        toggle(item)
    }

    // MARK: - Commands

    private func send(_ command: MediaCommand, to target: PlayerSource?) {
        switch target {
        case .music?, .spotify?:
            runner.run("tell application id \"\(target?.bundleID ?? "")\" to \(command.appleScript)")
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

    private func pause(_ target: PlayerSource) {
        if var candidate = candidates[target], candidate.isPlaying {
            let now = Date()
            candidate.elapsed += now.timeIntervalSince(candidate.elapsedTimestamp)
            candidate.elapsedTimestamp = now
            candidate.isPlaying = false
            candidates[target] = candidate
        }
        if isDemo { return }
        switch target {
        case .music, .spotify:
            runner.run("tell application id \"\(target.bundleID)\" to pause")
        case .system:
            bridge.send("pause")
        case .browser(let kind):
            browser.perform(.pause, in: kind, url: candidates[target]?.tabURL)
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
        pid: pid_t? = nil
    ) -> Bool {
        let now = Date()
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
        let systemBundles = Set(candidates.keys.compactMap { key -> String? in
            if case .system(let id) = key { return id }
            return nil
        })
        let visible = candidates.values.filter { candidate in
            if case .system = candidate.source { return true }
            return !systemBundles.contains(candidate.source.bundleID)
        }
        let latest: (MediaCandidate, MediaCandidate) -> Bool = { $0.lastActivity < $1.lastActivity }
        let chosen = visible.filter(\.isPlaying).max(by: latest) ?? visible.max(by: latest)

        let ordered = visible.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.lastActivity > rhs.lastActivity
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
            let info = chosen.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            let fallback = appInfo(for: chosen.source.bundleID)
            sourceName = info?.localizedName ?? fallback.name
            sourceIcon = info?.icon ?? fallback.icon
        }
        if isPlaying != chosen.isPlaying { isPlaying = chosen.isPlaying }
        if track != chosen.track { track = chosen.track }
        if elapsed != chosen.elapsed { elapsed = chosen.elapsed }
        if elapsedTimestamp != chosen.elapsedTimestamp { elapsedTimestamp = chosen.elapsedTimestamp }
        if artwork !== chosen.artwork { applyArtwork(chosen.artwork) }

        let key = "\(chosen.source.bundleID)|\(chosen.track.title)|\(chosen.track.artist)"
        if key != displayedKey {
            let hadTrack = displayedKey != nil
            displayedKey = key
            if chosen.isPlaying, hadTrack || Date().timeIntervalSince(launchDate) > 3 {
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
        let running = candidate.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
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

        var backdrop: NSImage?
        var accent = NSColor.white
        if let artwork = candidate.artwork {
            let key = ObjectIdentifier(artwork)
            if let cached = backdropCache[key] {
                backdrop = cached
            } else if let made = ArtworkProcessing.backdrop(from: artwork) {
                backdropCache[key] = made
                backdrop = made
            }
            if let cached = accentCache[key] {
                accent = cached
            } else {
                accent = artwork.vibrantAverageColor ?? .white
                accentCache[key] = accent
            }
            if backdropCache.count > 24 { backdropCache.removeAll(); accentCache.removeAll() }
        }

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
            isVideo: isVideo
        )
    }

    private func applyArtwork(_ image: NSImage?) {
        artwork = image
        let color = image?.vibrantAverageColor ?? .white
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
        let systemSeesBrowser = candidates.keys.contains { key in
            if case .system = key { return key.browserKind != nil }
            return false
        }
        if !systemSeesBrowser { pollBrowsers() }
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
                tabTitle: media.tabTitle
            )
            if needsArtwork { loadArtwork(for: source, url: media.artwork.isEmpty ? nil : media.artwork, key: key) }
        }
        recompute()
    }

    private func applyBridge(_ event: BridgeEvent) {
        guard !isDemo else { return }
        let systemSources = candidates.keys.filter { if case .system = $0 { return true } else { return false } }
        switch event {
        case .ready:
            break
        case .stopped:
            systemSources.forEach(removeCandidate)
        case .info(let info):
            guard !info.isEmpty else {
                systemSources.forEach(removeCandidate)
                return
            }
            let app = info.pid > 0 ? NSRunningApplication(processIdentifier: info.pid) : nil
            let source = PlayerSource.system(app?.bundleIdentifier ?? "")
            // Системный источник всегда один — убираем прежний, если сменилось приложение.
            for old in systemSources where old != source { candidates.removeValue(forKey: old) }

            let key = "system|\(info.title)|\(info.artist)|\(info.album)"
            let artworkChanged = upsert(
                source,
                track: NowPlayingTrack(title: info.title, artist: info.artist, album: info.album, duration: info.duration),
                playing: info.isPlaying,
                elapsed: info.elapsed,
                timestamp: info.timestamp > 0 ? Date(timeIntervalSince1970: info.timestamp) : Date(),
                artworkKey: key,
                pid: info.pid > 0 ? info.pid : nil
            )
            // Подтягиваем вкладку браузера, если её уже знаем из опроса.
            if let kind = source.browserKind, let tab = candidates[.browser(kind)], tab.track.title == info.title {
                candidates[source]?.tabURL = tab.tabURL
                candidates[source]?.tabTitle = tab.tabTitle
            }
            if let data = info.artwork {
                candidates[source]?.artwork = NSImage(data: data)
            } else if !info.hasArtwork {
                candidates[source]?.artwork = nil
            } else if artworkChanged {
                bridge.send("refresh")
            }
            recompute()
        }
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
                return {(player state as string), (name of t), (artist of t), (album of t), (duration of t), (player position)}
            end tell
            """
        case .spotify:
            return """
            tell application id "com.spotify.client"
                if player state is stopped then return {"stopped"}
                set t to current track
                return {(player state as string), (name of t), (artist of t), (album of t), ((duration of t) / 1000), (player position), (artwork url of t)}
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
    /// Средний цвет картинки, сделанный посочнее — для подсветки и эквалайзера.
    var vibrantAverageColor: NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let base = NSColor(
            srgbRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.12 { return NSColor(white: 0.92, alpha: 1) }
        return NSColor(hue: hue, saturation: max(saturation, 0.55), brightness: max(brightness, 0.85), alpha: 1)
    }
}
