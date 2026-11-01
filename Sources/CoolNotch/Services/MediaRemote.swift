import Foundation

/// Тонкая обёртка над приватным MediaRemote.framework.
/// Команды (play/pause/next) работают с любым плеером, включая браузер.
/// Чтение «что играет» Apple закрыла в macOS 15.4+, поэтому это лишь запасной вариант.
final class MediaRemote {
    enum Command: UInt32 {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    struct Info: Sendable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var elapsed: Double
        var isPlaying: Bool
        var timestamp: Date
        var artwork: Data?
    }

    private typealias SendCommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SetElapsedFn = @convention(c) (Double) -> Void

    private let sendCommandFn: SendCommandFn?
    private let getInfoFn: GetInfoFn?
    private let registerFn: RegisterFn?
    private let setElapsedFn: SetElapsedFn?

    static let infoDidChange = Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
            return nil
        }
        sendCommandFn = dlsym(handle, "MRMediaRemoteSendCommand").map { unsafeBitCast($0, to: SendCommandFn.self) }
        getInfoFn = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo").map { unsafeBitCast($0, to: GetInfoFn.self) }
        registerFn = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications").map { unsafeBitCast($0, to: RegisterFn.self) }
        setElapsedFn = dlsym(handle, "MRMediaRemoteSetElapsedTime").map { unsafeBitCast($0, to: SetElapsedFn.self) }
    }

    func registerForNotifications() {
        registerFn?(DispatchQueue.main)
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        sendCommandFn?(command.rawValue, nil) ?? false
    }

    func seek(to seconds: Double) {
        setElapsedFn?(seconds)
    }

    func fetchInfo(_ completion: @escaping (Info?) -> Void) {
        guard let getInfoFn else { completion(nil); return }
        getInfoFn(DispatchQueue.main) { raw in
            let dict = (raw as? [String: Any]) ?? [:]
            let title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            guard !title.isEmpty else { completion(nil); return }
            let rate = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            completion(Info(
                title: title,
                artist: dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
                album: dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
                duration: dict["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0,
                elapsed: dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0,
                isPlaying: rate > 0,
                timestamp: dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date(),
                artwork: dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
            ))
        }
    }
}
