import Foundation

/// Браузеры, из которых умеем читать «что играет» (через Media Session API страницы).
enum BrowserKind: String, CaseIterable, Sendable, Hashable {
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
    var url: String
    var tabTitle: String
}

struct BrowserFetchResult: Sendable {
    /// Лучшая (играющая) вкладка в каждом браузере.
    var media: [BrowserKind: BrowserMedia]
    var needsSetup: Bool
}

/// Читает трек или видео из вкладок Яндекс Музыки, YouTube, SoundCloud, VK и т. п.
/// Нужна однократная настройка браузера: «Разрешить JavaScript из Apple Events».
final class BrowserMediaSource: @unchecked Sendable {
    private let runner: AppleScriptRunner

    static let hosts = [
        "music.yandex",
        "youtube.com",
        "youtu.be",
        "soundcloud.com",
        "vk.com",
        "vkvideo.ru",
        "rutube.ru",
        "twitch.tv",
        "vimeo.com",
        "kinopoisk.ru",
        "open.spotify.com",
        "music.apple.com",
    ]

    // В строках JS только одинарные кавычки — их не нужно экранировать в AppleScript.
    private static let readJS = "(function(){try{var ms=navigator.mediaSession;var m=ms&&ms.metadata;var e=document.querySelector('video,audio');if(!m&&!e)return '';var art='';if(m&&m.artwork&&m.artwork.length){art=m.artwork[m.artwork.length-1].src;}var playing=(ms&&ms.playbackState==='playing')||(!!e&&!e.paused&&!e.ended);return JSON.stringify({title:(m&&m.title)||document.title||'',artist:(m&&m.artist)||'',album:(m&&m.album)||'',artwork:art||'',playing:!!playing,duration:(e&&isFinite(e.duration))?e.duration:0,position:e?e.currentTime:0,url:location.href,tabTitle:document.title||''});}catch(x){return '';}})()"

    private static let toggleJS = "(function(){var e=document.querySelector('video,audio');if(!e)return '';if(e.paused){e.play();}else{e.pause();}return 'ok';})()"

    init(runner: AppleScriptRunner) {
        self.runner = runner
    }

    func fetch(from kinds: [BrowserKind], completion: @escaping @MainActor (BrowserFetchResult) -> Void) {
        runner.perform({ _ in
            var best: [BrowserKind: BrowserMedia] = [:]
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
                    if best[kind] == nil || (media.playing && best[kind]?.playing == false) {
                        best[kind] = media
                    }
                }
            }
            return BrowserFetchResult(media: best, needsSetup: needsSetup)
        }, completion: completion)
    }

    func togglePlayback(in kind: BrowserKind) {
        runner.run(Self.script(for: kind, js: Self.toggleJS, collectAll: false))
    }

    func seek(in kind: BrowserKind, to seconds: Double) {
        let js = "(function(){var e=document.querySelector('video,audio');if(!e)return '';e.currentTime=\(String(format: "%.2f", seconds));return 'ok';})()"
        runner.run(Self.script(for: kind, js: js, collectAll: false))
    }

    /// Переключает браузер на вкладку с этим медиа (по адресу или заголовку) и выводит его вперёд.
    /// Нужно только разрешение «Автоматизация», без JavaScript.
    func focusTab(in kind: BrowserKind, title: String, url: String?) {
        let safeTitle = Self.escape(String(title.prefix(80)))
        let safeURL = Self.escape(url ?? "")
        let isSafari = kind == .safari
        let tabTitle = isSafari ? "name of t" : "title of t"
        let select = isSafari ? "set current tab of w to t" : "set active tab index of w to i"
        let script = """
        tell application id "\(kind.bundleID)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    set u to URL of t
                    set n to \(tabTitle)
                    if u is missing value then set u to ""
                    if n is missing value then set n to ""
                    if ("\(safeURL)" is not "" and u is "\(safeURL)") or ("\(safeTitle)" is not "" and n contains "\(safeTitle)") then
                        \(select)
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
            activate
        end tell
        """
        runner.run(script)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
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
