import Foundation

/// Браузеры, из которых умеем читать «что играет» (через Media Session API страницы).
enum BrowserKind: String, CaseIterable, Sendable {
    case safari, chrome, yandex, edge, brave

    var bundleID: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .yandex: return "ru.yandex.desktop.yandex-browser"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        }
    }
}

struct BrowserMedia: Decodable, Sendable {
    var title: String
    var artist: String
    var album: String
    var artwork: String
    var playing: Bool
    var duration: Double
    var position: Double
}

struct BrowserFetchResult: Sendable {
    var kind: BrowserKind?
    var media: BrowserMedia?
    var needsSetup: Bool
}

/// Читает трек из вкладок Яндекс Музыки, YouTube, SoundCloud, VK и т. п.
/// Нужна однократная настройка браузера: «Разрешить JavaScript из Apple Events».
final class BrowserMediaSource: @unchecked Sendable {
    private let runner: AppleScriptRunner

    static let hosts = [
        "music.yandex",
        "music.youtube.com",
        "youtube.com/watch",
        "soundcloud.com",
        "vk.com/audio",
        "vk.com/music",
        "open.spotify.com",
    ]

    // В строках JS только одинарные кавычки — их не нужно экранировать в AppleScript.
    private static let readJS = "(function(){try{var ms=navigator.mediaSession;var m=ms&&ms.metadata;var e=document.querySelector('video,audio');if(!m&&!e)return '';var art='';if(m&&m.artwork&&m.artwork.length){art=m.artwork[m.artwork.length-1].src;}var playing=(ms&&ms.playbackState==='playing')||(!!e&&!e.paused&&!e.ended);return JSON.stringify({title:(m&&m.title)||document.title||'',artist:(m&&m.artist)||'',album:(m&&m.album)||'',artwork:art||'',playing:!!playing,duration:(e&&isFinite(e.duration))?e.duration:0,position:e?e.currentTime:0});}catch(x){return '';}})()"

    private static let toggleJS = "(function(){var e=document.querySelector('video,audio');if(!e)return '';if(e.paused){e.play();}else{e.pause();}return 'ok';})()"

    init(runner: AppleScriptRunner) {
        self.runner = runner
    }

    func fetch(from kinds: [BrowserKind], completion: @escaping @MainActor (BrowserFetchResult) -> Void) {
        runner.perform({ _ in
            var best: (kind: BrowserKind, media: BrowserMedia)?
            var needsSetup = false
            let decoder = JSONDecoder()
            for kind in kinds {
                let result = AppleScriptRunner.execute(Self.script(for: kind, js: Self.readJS, collectAll: true))
                if let error = result.error {
                    if error.localizedCaseInsensitiveContains("javascript") { needsSetup = true }
                    continue
                }
                guard let text = result.descriptor?.stringValue, !text.isEmpty else { continue }
                for line in text.split(whereSeparator: \.isNewline) {
                    guard let media = try? decoder.decode(BrowserMedia.self, from: Data(line.utf8)),
                          !media.title.isEmpty else { continue }
                    if best == nil || (media.playing && best?.media.playing == false) {
                        best = (kind, media)
                    }
                }
            }
            return BrowserFetchResult(kind: best?.kind, media: best?.media, needsSetup: needsSetup)
        }, completion: completion)
    }

    func togglePlayback(in kind: BrowserKind) {
        runner.run(Self.script(for: kind, js: Self.toggleJS, collectAll: false))
    }

    func seek(in kind: BrowserKind, to seconds: Double) {
        let js = "(function(){var e=document.querySelector('video,audio');if(!e)return '';e.currentTime=\(String(format: "%.2f", seconds));return 'ok';})()"
        runner.run(Self.script(for: kind, js: js, collectAll: false))
    }

    /// Обходит вкладки с музыкальными сайтами и выполняет в них JS.
    /// collectAll: собрать ответы всех вкладок; иначе — остановиться на первой, где JS вернул «ok».
    private static func script(for kind: BrowserKind, js: String, collectAll: Bool) -> String {
        let condition = hosts.map { "u contains \"\($0)\"" }.joined(separator: " or ")
        let command = kind == .safari ? "do JavaScript \"\(js)\" in t" : "execute t javascript \"\(js)\""
        let onResult = collectAll
            ? "if r is not missing value and r is not \"\" then set out to out & r & linefeed"
            : "if r is \"ok\" then return \"ok\""
        return """
        tell application id "\(kind.bundleID)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if u is not missing value then
                        if \(condition) then
                            with timeout of 2 seconds
                                set r to \(command)
                            end timeout
                            \(onResult)
                        end if
                    end if
                end repeat
            end repeat
            return out
        end tell
        """
    }
}
