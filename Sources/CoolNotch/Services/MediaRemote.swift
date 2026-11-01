import Foundation

/// Команды воспроизведения через приватный MediaRemote.framework — запасной путь,
/// когда нет разрешения «Универсальный доступ» для медиаклавиш.
final class MediaRemote {
    enum Command: UInt32 {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private typealias SendCommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private let sendCommandFn: SendCommandFn?

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
            return nil
        }
        sendCommandFn = dlsym(handle, "MRMediaRemoteSendCommand").map { unsafeBitCast($0, to: SendCommandFn.self) }
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        sendCommandFn?(command.rawValue, nil) ?? false
    }
}
