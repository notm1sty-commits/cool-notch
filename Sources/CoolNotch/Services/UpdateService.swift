import AppKit
import Observation

/// Обновление «в один клик»: смотрит последний релиз на GitHub, скачивает zip,
/// подменяет приложение на месте и перезапускает его. Переустанавливать руками не нужно.
@MainActor
@Observable
final class UpdateService {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    struct Release: Equatable {
        let version: String
        let build: Int
        let notes: String
        let zipURL: URL
        let pageURL: URL?
    }

    static let repository = "notm1sty-commits/cool-notch"

    private(set) var state: State = .idle
    private(set) var latest: Release?
    private(set) var lastCheck: Date?

    @ObservationIgnored var onUpdateFound: ((Release) -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var downloader: Downloader?
    @ObservationIgnored private var announcedBuild = 0

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var hasUpdate: Bool {
        guard let latest else { return false }
        return latest.build > currentBuild
    }

    func start() {
        // Первая проверка — через минуту после запуска, дальше раз в 6 часов.
        timer = Timer.coalesced(interval: 6 * 3600, tolerance: 600) { [weak self] in
            self?.autoCheck()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.autoCheck()
        }
    }

    private func autoCheck() {
        guard Pref.bool(Pref.autoCheckUpdates), !isBusy, !SystemState.screensAsleep else { return }
        check()
    }

    func check() {
        guard !isBusy else { return }
        state = .checking
        Task {
            do {
                guard let release = try await fetchLatest() else {
                    // Релизов ещё нет — это не ошибка, просто обновляться пока не на что.
                    latest = nil
                    lastCheck = Date()
                    state = .upToDate
                    return
                }
                latest = release
                lastCheck = Date()
                if release.build > currentBuild {
                    state = .available
                    if release.build > announcedBuild {
                        announcedBuild = release.build
                        onUpdateFound?(release)
                    }
                } else {
                    state = .upToDate
                }
            } catch {
                lastCheck = Date()
                state = .failed(Self.describe(error))
            }
        }
    }

    /// Скачивает и ставит обновление, затем перезапускает приложение.
    func install() {
        guard let release = latest, !isBusy else { return }
        let destination = Bundle.main.bundleURL
        if destination.path.contains("/AppTranslocation/") {
            state = .failed("Перенеси Cool Notch в папку «Программы» и запусти снова — macOS запускает его из временной копии.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            state = .failed("Нет прав на запись в \(destination.deletingLastPathComponent().path).")
            return
        }

        state = .downloading(0)
        let downloader = Downloader { [weak self] progress in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(progress)
            }
        }
        self.downloader = downloader
        Task {
            do {
                let zip = try await downloader.download(release.zipURL)
                state = .installing
                let app = try await Self.unpack(zip)
                try Self.relaunch(replacing: destination, with: app)
            } catch {
                state = .failed(Self.describe(error))
            }
            self.downloader = nil
        }
    }

    func openReleasePage() {
        let url = latest?.pageURL ?? URL(string: "https://github.com/\(Self.repository)/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - GitHub

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }

        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL?
        let prerelease: Bool?
        let draft: Bool?
        let assets: [Asset]
    }

    /// Последний релиз. С «тестовыми сборками» учитываются и предварительные релизы из разработки.
    private func fetchLatest() async throws -> Release? {
        let beta = Pref.bool(Pref.betaUpdates)
        let path = beta ? "releases?per_page=20" : "releases/latest"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/\(path)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CoolNotch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 404 { return nil }
            throw UpdateError.message(http.statusCode == 403 ? "GitHub временно ограничил запросы — попробуй позже." : "GitHub ответил \(http.statusCode).")
        }
        let releases = beta
            ? try JSONDecoder().decode([APIRelease].self, from: data).filter { !($0.draft ?? false) }
            : [try JSONDecoder().decode(APIRelease.self, from: data)]
        return releases.compactMap(Self.makeRelease).max { $0.build < $1.build }
    }

    private static func makeRelease(_ api: APIRelease) -> Release? {
        guard let zip = api.assets.first(where: { $0.name.hasSuffix(".zip") }) else { return nil }
        let build = Self.buildNumber(in: api.tag_name) ?? Self.buildNumber(in: api.name ?? "") ?? 0
        let versionText = Self.version(in: api.name ?? "") ?? api.tag_name
        return Release(
            version: (api.prerelease ?? false) ? "\(versionText) (тестовая)" : versionText,
            build: build,
            notes: api.body ?? "",
            zipURL: zip.browser_download_url,
            pageURL: api.html_url
        )
    }

    /// `build-42` или «… (сборка 42)».
    private static func buildNumber(in text: String) -> Int? {
        guard let range = text.range(of: #"(build|сборка)[- ]?(\d+)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let digits = text[range].filter(\.isNumber)
        return Int(digits)
    }

    private static func version(in text: String) -> String? {
        guard let range = text.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    // MARK: - Install

    private static func unpack(_ zip: URL) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CoolNotchUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard let app = items.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.message("В архиве нет приложения.")
        }
        // Скачанное через URLSession не помечается карантином, но на всякий случай снимаем.
        try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.message("Архив содержит другое приложение.")
        }
        return app
    }

    /// Отдельный процесс дожидается выхода приложения, подменяет бандл и запускает новую версию.
    private static func relaunch(replacing destination: URL, with app: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        DEST=\(shellQuote(destination.path))
        NEW=\(shellQuote(app.path))
        BACKUP="$DEST.old-$$"
        mv "$DEST" "$BACKUP" || exit 1
        if /usr/bin/ditto "$NEW" "$DEST"; then
          rm -rf "$BACKUP"
        else
          rm -rf "$DEST"; mv "$BACKUP" "$DEST"
        fi
        /usr/bin/open "$DEST"
        rm -rf \(shellQuote(app.deletingLastPathComponent().path))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.message("Не удалось распаковать обновление."))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private enum UpdateError: Error {
        case message(String)
    }

    private static func describe(_ error: Error) -> String {
        if case UpdateError.message(let text) = error { return text }
        if (error as NSError).domain == NSURLErrorDomain { return "Нет связи с GitHub." }
        return error.localizedDescription
    }
}

/// Загрузка с прогрессом.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(progress: @escaping (Double) -> Void) {
        self.progress = progress
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Файл живёт только до выхода из метода — переносим.
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("CoolNotch-\(UUID().uuidString).zip")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.moveItem(at: location, to: target)
            continuation?.resume(returning: target)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}
