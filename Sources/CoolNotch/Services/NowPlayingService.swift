import AppKit
import Observation
import SwiftUI

struct NowPlayingTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
}

enum PlayerSource: String {
    case music, spotify, system

    var bundleID: String? {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .system: return nil
        }
    }

    var appName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        case .system: return ""
        }
    }
}

/// Следит за тем, что играет в Музыке, Spotify (и в системе, где это разрешено).
@MainActor
@Observable
final class NowPlayingService {
    private(set) var track: NowPlayingTrack?
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    private(set) var accent: Color = .white
    private(set) var source: PlayerSource?
    private(set) var elapsed: Double = 0
    private(set) var elapsedTimestamp = Date()

    private let runner = AppleScriptRunner()
    private let mediaRemote = MediaRemote()
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var distributedObservers: [DistributedObserver] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTimer: Timer?

    init() {
        distributedObservers = [
            DistributedObserver(name: "com.apple.Music.playerInfo") { [weak self] in
                Task { @MainActor in self?.refresh(.music) }
            },
            DistributedObserver(name: "com.spotify.client.PlaybackStateChanged") { [weak self] in
                Task { @MainActor in self?.refresh(.spotify) }
            },
        ]

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.appTerminated(bundleID) }
        })

        if let mediaRemote {
            mediaRemote.registerForNotifications()
            observers.append(NotificationCenter.default.addObserver(
                forName: MediaRemote.infoDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshSystem() }
            })
        }

        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodicRefresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

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
        let now = Date()
        elapsed = position(at: now)
        elapsedTimestamp = now
        isPlaying.toggle()
        perform(appleScript: "playpause", fallback: .togglePlayPause)
    }

    func next() {
        perform(appleScript: "next track", fallback: .nextTrack)
    }

    func previous() {
        perform(appleScript: "previous track", fallback: .previousTrack)
    }

    func seek(to seconds: Double) {
        elapsed = seconds
        elapsedTimestamp = Date()
        switch source {
        case .music?, .spotify?:
            let app = source?.appName ?? ""
            runner.run("tell application \"\(app)\" to set player position to \(String(format: "%.2f", seconds))")
            scheduleRefresh()
        default:
            mediaRemote?.seek(to: seconds)
        }
    }

    func openSourceApp() {
        guard let id = source?.bundleID ?? installedPlayers.first?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }

    func launch(_ player: PlayerSource) {
        guard let id = player.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }

    var installedPlayers: [PlayerSource] {
        [PlayerSource.spotify, .music].filter { player in
            guard let id = player.bundleID else { return false }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
    }

    // MARK: - Commands

    private func perform(appleScript command: String, fallback: MediaRemote.Command) {
        switch source {
        case .music?, .spotify?:
            let app = source?.appName ?? ""
            runner.run("tell application \"\(app)\" to \(command)")
            scheduleRefresh()
        default:
            if mediaRemote?.send(fallback) != true, let player = runningPlayers.first {
                runner.run("tell application \"\(player.appName)\" to \(command)")
            }
            scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.refreshAll()
        }
    }

    // MARK: - Refresh

    private var runningPlayers: [PlayerSource] {
        [PlayerSource.spotify, .music].filter { isRunning($0) }
    }

    private func isRunning(_ player: PlayerSource) -> Bool {
        guard let id = player.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    private func refreshAll() {
        let running = runningPlayers
        for player in running { refresh(player) }
        if running.isEmpty { refreshSystem() }
    }

    private func periodicRefresh() {
        if let source, source != .system {
            if isRunning(source) { refresh(source) } else { clear() }
        } else {
            refreshAll()
        }
    }

    private func refresh(_ player: PlayerSource) {
        // Никогда не запускаем плеер сами: AppleScript «tell application» его бы открыл.
        guard isRunning(player) else {
            if source == player { clear() }
            return
        }
        runner.run(Self.stateScript(for: player), parse: AppleScriptRunner.parseSnapshot) { [weak self] snapshot in
            self?.apply(snapshot, from: player)
        }
    }

    private func refreshSystem() {
        guard let mediaRemote else { return }
        if let source, source != .system, isPlaying { return }
        mediaRemote.fetchInfo { [weak self] info in
            Task { @MainActor in self?.applySystem(info) }
        }
    }

    private func apply(_ snapshot: PlayerSnapshot?, from player: PlayerSource) {
        guard let snapshot else { return }
        let playing = snapshot.state == "playing"

        // Не даём поставленному на паузу плееру перебить тот, что сейчас играет.
        if let source, source != player, isPlaying, !playing { return }

        if snapshot.state == "stopped" || snapshot.title.isEmpty {
            if source == player { clear() }
            return
        }

        source = player
        isPlaying = playing
        let newTrack = NowPlayingTrack(
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            duration: snapshot.duration
        )
        if track != newTrack { track = newTrack }
        elapsed = snapshot.position
        elapsedTimestamp = Date()

        let key = "\(player.rawValue)|\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        if key != artworkKey {
            artworkKey = key
            loadArtwork(for: player, url: snapshot.artworkURL, key: key)
        }
    }

    private func applySystem(_ info: MediaRemote.Info?) {
        if let source, source != .system, isPlaying { return }
        guard let info else {
            if source == .system { clear() }
            return
        }
        source = .system
        isPlaying = info.isPlaying
        let newTrack = NowPlayingTrack(title: info.title, artist: info.artist, album: info.album, duration: info.duration)
        if track != newTrack { track = newTrack }
        elapsed = info.elapsed
        elapsedTimestamp = info.timestamp
        let key = "system|\(info.title)|\(info.artist)"
        if key != artworkKey {
            artworkKey = key
            setArtwork(info.artwork.flatMap { NSImage(data: $0) })
        }
    }

    private func appTerminated(_ bundleID: String?) {
        guard let bundleID, bundleID == source?.bundleID else { return }
        clear()
        refreshAll()
    }

    private func clear() {
        track = nil
        isPlaying = false
        source = nil
        artworkKey = nil
        setArtwork(nil)
    }

    // MARK: - Artwork

    private func loadArtwork(for player: PlayerSource, url: String?, key: String) {
        switch player {
        case .spotify:
            guard let url, let link = URL(string: url) else { setArtwork(nil); return }
            URLSession.shared.dataTask(with: link) { data, _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.artworkKey == key else { return }
                    self.setArtwork(data.flatMap { NSImage(data: $0) })
                }
            }.resume()
        case .music:
            let script = """
            tell application "Music"
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
        case .system:
            break
        }
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        accent = image?.vibrantAverageColor.map { Color(nsColor: $0) } ?? .white
    }

    // MARK: - Scripts

    private static func stateScript(for player: PlayerSource) -> String {
        switch player {
        case .music:
            return """
            tell application "Music"
                if player state is stopped then return {"stopped"}
                set t to current track
                return {(player state as string), (name of t), (artist of t), (album of t), (duration of t), (player position)}
            end tell
            """
        case .spotify:
            return """
            tell application "Spotify"
                if player state is stopped then return {"stopped"}
                set t to current track
                return {(player state as string), (name of t), (artist of t), (album of t), ((duration of t) / 1000), (player position), (artwork url of t)}
            end tell
            """
        case .system:
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
