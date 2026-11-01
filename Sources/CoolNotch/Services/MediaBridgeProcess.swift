import Foundation

/// Данные о треке от системного «Что играет».
struct BridgeInfo: Sendable {
    var isEmpty: Bool
    var title = ""
    var artist = ""
    var album = ""
    var duration = 0.0
    var elapsed = 0.0
    var rate = 0.0
    var timestamp = 0.0
    var isPlaying = false
    var pid: Int32 = 0
    var artwork: Data?
    var hasArtwork = false
    /// Повтор: 1 — выкл, 2 — один трек, 3 — всё; nil — плеер не сообщает.
    var repeatMode: Int?
}

/// Плеер, который не выбран системой, но тоже сообщает, что играет.
struct BridgeClientInfo: Sendable {
    var bundleID: String
    var pid: Int32
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var rate: Double
    var timestamp: Double
    var artwork: Data?
    var hasArtwork: Bool
    var repeatMode: Int?
}

enum BridgeEvent: Sendable {
    case ready
    case info(BridgeInfo)
    /// Все приложения, которые сообщают о воспроизведении (не только выбранное системой).
    case clients([BridgeClientInfo])
    case stopped
}

/// Запускает помощник MediaBridge внутри системного /usr/bin/perl (см. Helpers/MediaBridge)
/// и получает от него системный «Что играет» — так видны любые плееры, включая Яндекс Музыку.
@MainActor
final class MediaBridgeProcess {
    var onEvent: (@MainActor (BridgeEvent) -> Void)?
    private(set) var isRunning = false
    /// Включён ли помощник (даже если сейчас перезапускается или сдался после сбоев).
    private(set) var isEnabled = false
    /// Последняя строка ошибки от perl — для диагностики в настройках.
    private(set) var lastError: String?
    /// Сколько раз подряд пришлось перезапускать помощник.
    var restarts: Int { restartCount }
    /// Читает ли помощник всех клиентов «Что играет». Выключается сам, если в этом режиме он падал.
    var readsAllClients: Bool { !UserDefaults.standard.bool(forKey: Self.allClientsDisabledKey) }
    static let allClientsDisabledKey = "bridgeAllClientsDisabled"
    private var launchedAt = Date()
    private var launchedWithAllClients = false

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputPipe: Pipe?
    private var restartCount = 0

    static let libraryName = "libCoolNotchMediaBridge.dylib"

    /// Есть ли помощник в сборке (при `swift run` его нет).
    static var isAvailable: Bool { resources != nil }

    private static var resources: (script: URL, library: URL)? {
        guard let script = Bundle.main.url(forResource: "media-bridge", withExtension: "pl"),
              let library = Bundle.main.privateFrameworksURL?.appendingPathComponent(libraryName),
              FileManager.default.fileExists(atPath: library.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else { return nil }
        return (script, library)
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        restartCount = 0
        launch()
    }

    func stop() {
        isEnabled = false
        try? inputHandle?.close()
        process?.terminate()
    }

    func send(_ command: String) {
        guard isRunning, let inputHandle else { return }
        do {
            try inputHandle.write(contentsOf: Data((command + "\n").utf8))
        } catch {
            // Помощник уже завершился — перезапуск произойдёт сам.
        }
    }

    private func launch() {
        guard isEnabled, process == nil, let resources = Self.resources else { return }
        // Файлы из скачанного архива помечены карантином — снимаем его со своих же файлов,
        // иначе perl может отказаться загружать библиотеку.
        removexattr(resources.library.path, "com.apple.quarantine", 0)
        removexattr(resources.script.path, "com.apple.quarantine", 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.script.path, resources.library.path]
        // Режим «все плееры» — через закрытые функции MediaRemote. Если помощник в нём упадёт,
        // processExited() выключит режим, и дальше всё работает как раньше (только выбранный плеер).
        var environment = ProcessInfo.processInfo.environment
        launchedWithAllClients = readsAllClients
        if launchedWithAllClients { environment["COOLNOTCH_ALL_CLIENTS"] = "1" }
        process.environment = environment
        launchedAt = Date()
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            guard let text, !text.isEmpty else { return }
            Task { @MainActor in self?.lastError = String(text.prefix(200)) }
        }

        let reader = BridgeLineReader { [weak self] event in
            self?.received(event)
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            reader.consume(data)
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processExited() }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return
        }
        self.process = process
        self.inputHandle = input.fileHandleForWriting
        self.outputPipe = output
        isRunning = true
    }

    private func received(_ event: BridgeEvent) {
        restartCount = 0
        onEvent?(event)
    }

    private func processExited() {
        isRunning = false
        process = nil
        inputHandle = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        onEvent?(.stopped)

        // Упал вскоре после запуска в режиме «все плееры» — выключаем этот режим навсегда.
        if isEnabled, launchedWithAllClients, Date().timeIntervalSince(launchedAt) < 20 {
            UserDefaults.standard.set(true, forKey: Self.allClientsDisabledKey)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.launch()
            }
            return
        }

        // Упал — пробуем перезапустить с нарастающей паузой, но не бесконечно.
        guard isEnabled, restartCount < 4 else { return }
        restartCount += 1
        let delay = Double(restartCount * restartCount) * 2
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.launch()
        }
    }
}

/// Читает построчный JSON из пайпа (в фоне) и отдаёт события на главный поток.
private final class BridgeLineReader: @unchecked Sendable {
    private struct Message: Decodable {
        var type: String
        var empty: Bool?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var timestamp: Double?
        var playing: Bool?
        var pid: Int32?
        var artwork: String?
        var hasArtwork: Bool?
        var repeatMode: Int?
        var items: [Client]?
    }

    private struct Client: Decodable {
        var bundle: String
        var pid: Int32?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var timestamp: Double?
        var artwork: String?
        var hasArtwork: Bool?
        var repeatMode: Int?
    }

    private var buffer = Data()
    private let decoder = JSONDecoder()
    private let deliver: @MainActor (BridgeEvent) -> Void

    init(deliver: @escaping @MainActor (BridgeEvent) -> Void) {
        self.deliver = deliver
    }

    func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = try? decoder.decode(Message.self, from: line),
                  let event = Self.event(from: message) else { continue }
            let deliver = self.deliver
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(event) }
            }
        }
    }

    private static func event(from message: Message) -> BridgeEvent? {
        switch message.type {
        case "ready":
            return .ready
        case "clients":
            return .clients((message.items ?? []).map { client in
                BridgeClientInfo(
                    bundleID: client.bundle,
                    pid: client.pid ?? 0,
                    title: client.title ?? "",
                    artist: client.artist ?? "",
                    album: client.album ?? "",
                    duration: client.duration ?? 0,
                    elapsed: client.elapsed ?? 0,
                    rate: client.rate ?? 0,
                    timestamp: client.timestamp ?? 0,
                    artwork: client.artwork.flatMap { Data(base64Encoded: $0) },
                    hasArtwork: client.hasArtwork ?? false,
                    repeatMode: client.repeatMode
                )
            })
        case "info":
            if message.empty ?? true { return .info(BridgeInfo(isEmpty: true)) }
            return .info(BridgeInfo(
                isEmpty: false,
                title: message.title ?? "",
                artist: message.artist ?? "",
                album: message.album ?? "",
                duration: message.duration ?? 0,
                elapsed: message.elapsed ?? 0,
                rate: message.rate ?? 0,
                timestamp: message.timestamp ?? 0,
                isPlaying: message.playing ?? false,
                pid: message.pid ?? 0,
                artwork: message.artwork.flatMap { Data(base64Encoded: $0) },
                hasArtwork: message.hasArtwork ?? false,
                repeatMode: message.repeatMode
            ))
        default:
            return nil
        }
    }
}
