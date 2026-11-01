import AppKit
import Observation
import SwiftUI

struct NowPlayingTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
}

enum PlayerSource: Equatable {
    case music
    case spotify
    case browser(BrowserKind)

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .browser(let kind): return kind.bundleID
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

private enum MediaCommand {
    case toggle, next, previous

    var appleScript: String {
        switch self {
        case .toggle: return "playpause"
        case .next: return "next track"
        case .previous: return "previous track"
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

/// Следит за тем, что играет: Музыка и Spotify (AppleScript), браузер (Media Session),
/// а также за плеерами без данных о треке — ими управляем медиаклавишами.
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

    @ObservationIgnored var onTrackChange: (@MainActor (NowPlayingTrack) -> Void)?

    private let runner: AppleScriptRunner
    private let browser: BrowserMediaSource
    private let mediaRemote: MediaRemote?
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var distributedObservers: [DistributedObserver] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private let launchDate = Date()
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    init() {
        runner = AppleScriptRunner()
        browser = BrowserMediaSource(runner: runner)
        mediaRemote = MediaRemote()
        canControlAnyPlayer = MediaKeys.isTrusted

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
        if track != nil {
            let now = Date()
            elapsed = position(at: now)
            elapsedTimestamp = now
            isPlaying.toggle()
        }
        perform(.toggle)
    }

    func next() { perform(.next) }
    func previous() { perform(.previous) }

    func seek(to seconds: Double) {
        elapsed = seconds
        elapsedTimestamp = Date()
        switch source {
        case .music?, .spotify?:
            runner.run("tell application id \"\(source?.bundleID ?? "")\" to set player position to \(String(format: "%.2f", seconds))")
            scheduleRefresh()
        case .browser(let kind)?:
            browser.seek(in: kind, to: seconds)
            scheduleRefresh()
        case nil:
            break
        }
    }

    func openSourceApp() {
        let id = source?.bundleID ?? externalPlayer?.bundleID ?? installedPlayers.first?.bundleID
        guard let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }

    func launch(_ player: PlayerSource) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
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

    // MARK: - Commands

    private func perform(_ command: MediaCommand) {
        switch source {
        case .music?, .spotify?:
            runner.run("tell application id \"\(source?.bundleID ?? "")\" to \(command.appleScript)")
        case .browser(let kind)?:
            if MediaKeys.isTrusted {
                MediaKeys.post(command.key)
            } else if command == .toggle {
                browser.togglePlayback(in: kind)
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

    private func scheduleRefresh() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.refreshAll()
        }
    }

    // MARK: - Refresh

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func refreshAll() {
        for player in [PlayerSource.spotify, .music] where isRunning(player.bundleID) {
            refresh(player)
        }
        pollBrowsers()
    }

    private func periodicRefresh() {
        guard !SystemState.screensAsleep else { return }
        let trusted = MediaKeys.isTrusted
        if trusted != canControlAnyPlayer { canControlAnyPlayer = trusted }

        switch source {
        case .music?, .spotify?:
            guard let source else { return }
            if !isRunning(source.bundleID) {
                clear()
                refreshAll()
            } else if isPlaying {
                refresh(source)  // синхронизируем позицию
            } else {
                pollBrowsers()   // вдруг музыка заиграла в браузере
            }
        case .browser?:
            pollBrowsers()
        case nil:
            // Без активного плеера не опрашиваем часто: Музыка и Spotify сами присылают уведомления.
            pollBrowsers()
        }
    }

    private func refresh(_ player: PlayerSource) {
        // Никогда не запускаем плеер сами: «tell application» открыл бы его.
        guard isRunning(player.bundleID) else {
            if source == player { clear() }
            return
        }
        runner.run(Self.stateScript(for: player), parse: { AppleScriptRunner.parseSnapshot($0) }) { [weak self] snapshot in
            self?.apply(snapshot, from: player)
        }
    }

    private func pollBrowsers() {
        guard Pref.bool(Pref.browserMusic) else {
            if case .browser? = source { clear() }
            return
        }
        let running = BrowserKind.allCases.filter { isRunning($0.bundleID) }
        guard !running.isEmpty else {
            if case .browser? = source { clear() }
            return
        }
        browser.fetch(from: running) { [weak self] result in
            self?.applyBrowser(result)
        }
    }

    private func applyBrowser(_ result: BrowserFetchResult) {
        if result.needsSetup != browserNeedsSetup { browserNeedsSetup = result.needsSetup }
        guard let media = result.media, let kind = result.kind else {
            if case .browser? = source { clear() }
            return
        }
        let snapshot = PlayerSnapshot(
            state: media.playing ? "playing" : "paused",
            title: media.title,
            artist: media.artist,
            album: media.album,
            duration: media.duration,
            position: media.position,
            artworkURL: media.artwork.isEmpty ? nil : media.artwork
        )
        apply(snapshot, from: .browser(kind))
    }

    private func apply(_ snapshot: PlayerSnapshot?, from player: PlayerSource) {
        guard let snapshot else { return }
        let playing = snapshot.state == "playing"

        // Не даём плееру на паузе перебить тот, что сейчас играет.
        if let source, source != player, isPlaying, !playing { return }

        if snapshot.state == "stopped" || snapshot.title.isEmpty {
            if source == player { clear() }
            return
        }

        if source != player {
            source = player
            let info = appInfo(for: player.bundleID)
            sourceName = info.name
            sourceIcon = info.icon
        }
        if isPlaying != playing { isPlaying = playing }

        let newTrack = NowPlayingTrack(
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            duration: snapshot.duration
        )
        if track != newTrack {
            let titleChanged = track?.title != newTrack.title || track?.artist != newTrack.artist
            track = newTrack
            if titleChanged, playing, Date().timeIntervalSince(launchDate) > 3 {
                onTrackChange?(newTrack)
            }
        }
        elapsed = snapshot.position
        elapsedTimestamp = Date()

        let key = "\(player.bundleID)|\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        if key != artworkKey {
            artworkKey = key
            loadArtwork(for: player, url: snapshot.artworkURL, key: key)
        }
    }

    private func appTerminated(_ bundleID: String?) {
        refreshExternalPlayer()
        guard let bundleID, bundleID == source?.bundleID else { return }
        clear()
        refreshAll()
    }

    private func clear() {
        guard source != nil || track != nil else { return }
        track = nil
        isPlaying = false
        source = nil
        sourceName = ""
        sourceIcon = nil
        artworkKey = nil
        setArtwork(nil)
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

    private func appInfo(for bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return ("", nil) }
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
            guard let url, let link = URL(string: url), link.scheme?.hasPrefix("http") == true else {
                setArtwork(nil)
                return
            }
            URLSession.shared.dataTask(with: link) { data, _, _ in
                let image = data.flatMap { NSImage(data: $0) }
                Task { @MainActor [weak self] in
                    guard let self, self.artworkKey == key else { return }
                    self.setArtwork(image)
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
                guard let self, self.artworkKey == key else { return }
                self.setArtwork(data.flatMap { NSImage(data: $0) })
            }
        }
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        let color = image?.vibrantAverageColor ?? .white
        accentNSColor = color
        accent = Color(nsColor: color)
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
        case .browser:
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
