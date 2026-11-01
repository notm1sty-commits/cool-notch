import AppKit
import Observation
import SQLite3

/// Уведомление другого приложения из Центра уведомлений macOS.
struct SystemNotification: Sendable, Equatable {
    let id: Int64
    let bundleID: String
    let title: String
    let subtitle: String
    let body: String
    let date: Date
    /// Время доставки как в базе (секунды от 2001 года).
    var delivered: Double = 0
}

/// Показывает в чёлке уведомления всех приложений.
///
/// Публичного API для этого в macOS нет, поэтому читаем локальную базу Центра уведомлений
/// (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`) — только чтение, ничего не меняем.
/// Нужно разрешение «Полный доступ к диску», которое пользователь даёт сам в Системных настройках.
@MainActor
@Observable
final class NotificationMirror {
    enum Status: Equatable {
        case off
        case needsAccess
        case running
        case unavailable
    }

    private(set) var status: Status = .off
    /// Последнее уведомление, которое удалось прочитать, — строка диагностики в настройках.
    private(set) var lastSeen: String?

    @ObservationIgnored var onNotification: (@MainActor (SystemNotification) -> Void)?
    private let reader: NotificationDatabaseReader
    @ObservationIgnored private var lastID: Int64?
    /// Некоторые приложения (Telegram) не добавляют запись, а обновляют прежнюю — новое сообщение
    /// из того же чата заменяет старое уведомление. Такие обновления ловим по времени доставки.
    @ObservationIgnored private var lastDelivered: Double = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var fileSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var isChecking = false

    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    init() {
        reader = NotificationDatabaseReader(path: Self.databaseURL.path)
    }

    /// Включает/выключает зеркалирование по настройке. Безопасно вызывать часто.
    func update(enabled: Bool) {
        if enabled {
            if status == .off || status == .needsAccess { start() }
        } else if status != .off {
            stop()
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func start() {
        reader.perform({ reader in
            reader.latestID()
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let latest):
                self.lastID = latest.id
                self.lastDelivered = latest.delivered
                self.status = .running
                self.startWatching()
            case .failure(let error):
                self.status = error == .noAccess ? .needsAccess : .unavailable
                self.scheduleRetry()
            }
        })
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        fileSource?.cancel()
        fileSource = nil
        reader.close()
        status = .off
    }

    /// Пока нет доступа, раз в несколько секунд проверяем — вдруг пользователь уже разрешил.
    private func scheduleRetry() {
        timer?.invalidate()
        timer = Timer.coalesced(interval: 4, tolerance: 0.5) { [weak self] in
            guard let self, self.status == .needsAccess || self.status == .unavailable else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.start()
        }
    }

    private func startWatching() {
        timer?.invalidate()
        // Мгновенная реакция — по изменению журнала базы (WAL), плюс редкая страховочная проверка.
        watchFile()
        timer = Timer.coalesced(interval: 6, tolerance: 0.4) { [weak self] in
            guard let self, !SystemState.screensAsleep else { return }
            if self.fileSource == nil { self.watchFile() }
            self.check()
        }
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        let path = Self.databaseURL.path + "-wal"
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let events = self.fileSource?.data ?? []
                if events.contains(.delete) || events.contains(.rename) {
                    // Журнал пересоздан — подпишемся заново при следующей проверке.
                    self.fileSource?.cancel()
                    self.fileSource = nil
                }
                self.check()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        fileSource = source
    }

    private func check() {
        guard status == .running, !isChecking, let lastID else { return }
        isChecking = true
        let since = lastDelivered
        reader.perform({ reader in
            reader.notifications(after: lastID, since: since)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.isChecking = false
            switch result {
            case .success(let items):
                guard !items.isEmpty else { return }
                self.lastID = max(lastID, items.map(\.id).max() ?? lastID)
                self.lastDelivered = max(since, items.map(\.delivered).max() ?? since)
                if let latest = items.max(by: { $0.delivered < $1.delivered }) {
                    let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: latest.bundleID)
                        .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                        ?? latest.bundleID
                    let text = latest.title.isEmpty ? latest.body : latest.title
                    self.lastSeen = "\(app): \(text) · \(latest.date.formatted(date: .omitted, time: .shortened))"
                }
                let ownBundle = Bundle.main.bundleIdentifier ?? ""
                let fresh = items.filter {
                    $0.bundleID != ownBundle && Date().timeIntervalSince($0.date) < 60
                }
                // Если пришла пачка — показываем последние три, без лавины.
                for item in fresh.suffix(3) { self.onNotification?(item) }
            case .failure(let error):
                if error == .noAccess {
                    self.status = .needsAccess
                    self.scheduleRetry()
                }
            }
        })
    }
}

enum NotificationDatabaseError: Error, Equatable {
    case noAccess
    case unreadable
}

/// Доступ к базе Центра уведомлений на отдельной очереди (только чтение).
final class NotificationDatabaseReader: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "cool-notch.notifications", qos: .utility)
    private var db: OpaquePointer?

    init(path: String) {
        self.path = path
    }

    func perform<T: Sendable>(
        _ work: @escaping @Sendable (NotificationDatabaseReader) -> T,
        completion: @escaping @MainActor (T) -> Void
    ) {
        queue.async {
            let value = work(self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(value) }
            }
        }
    }

    func close() {
        queue.async {
            if let db = self.db { sqlite3_close(db) }
            self.db = nil
        }
    }

    /// Вызывать только внутри `perform`.
    func latestID() -> Result<(id: Int64, delivered: Double), NotificationDatabaseError> {
        switch openIfNeeded() {
        case .failure(let error): return .failure(error)
        case .success(let db):
            var statement: OpaquePointer?
            let sql = "SELECT IFNULL(MAX(rec_id), 0), IFNULL(MAX(delivered_date), 0) FROM record"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return .failure(failure(for: db))
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return .failure(failure(for: db)) }
            return .success((sqlite3_column_int64(statement, 0), sqlite3_column_double(statement, 1)))
        }
    }

    /// Вызывать только внутри `perform`.
    func notifications(after id: Int64, since delivered: Double) -> Result<[SystemNotification], NotificationDatabaseError> {
        switch openIfNeeded() {
        case .failure(let error): return .failure(error)
        case .success(let db):
            let sql = """
            SELECT r.rec_id, IFNULL(a.identifier, ''), r.data, IFNULL(r.delivered_date, 0)
            FROM record r LEFT JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ? OR IFNULL(r.delivered_date, 0) > ? ORDER BY r.rec_id ASC LIMIT 50
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return .failure(failure(for: db))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            sqlite3_bind_double(statement, 2, delivered)

            var result: [SystemNotification] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let recID = sqlite3_column_int64(statement, 0)
                let bundleID = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                let deliveredAt = sqlite3_column_double(statement, 3)
                var data = Data()
                if let bytes = sqlite3_column_blob(statement, 2) {
                    data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
                }
                let parsed = Self.parse(data)
                let notification = SystemNotification(
                    id: recID,
                    bundleID: bundleID.isEmpty ? parsed.bundleID : bundleID,
                    title: parsed.title,
                    subtitle: parsed.subtitle,
                    body: parsed.body,
                    date: deliveredAt > 0 ? Date(timeIntervalSinceReferenceDate: deliveredAt) : Date(),
                    delivered: deliveredAt
                )
                result.append(notification)
            }
            return .success(result)
        }
    }

    private func openIfNeeded() -> Result<OpaquePointer, NotificationDatabaseError> {
        if let db { return .success(db) }
        guard FileManager.default.isReadableFile(atPath: path) else { return .failure(.noAccess) }
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard code == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return .failure(code == SQLITE_CANTOPEN || code == SQLITE_PERM || code == SQLITE_AUTH ? .noAccess : .unreadable)
        }
        sqlite3_busy_timeout(handle, 500)
        db = handle
        return .success(handle)
    }

    private func failure(for db: OpaquePointer) -> NotificationDatabaseError {
        let code = sqlite3_errcode(db)
        // Ошибка — закрываем (v2 дождётся финализации запросов), чтобы потом открыть заново.
        sqlite3_close_v2(db)
        self.db = nil
        return code == SQLITE_CANTOPEN || code == SQLITE_PERM || code == SQLITE_AUTH ? .noAccess : .unreadable
    }

    /// Запись уведомления — бинарный plist: { app, req: { titl, subt, body } }.
    private static func parse(_ data: Data) -> (bundleID: String, title: String, subtitle: String, body: String) {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any] else {
            return ("", "", "", "")
        }
        let request = root["req"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String {
            (request[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return (root["app"] as? String ?? "", text("titl"), text("subt"), text("body"))
    }
}
