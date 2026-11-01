import ApplicationServices
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var notifications: NotificationMirror?
    var updates: UpdateService?
    var nowPlaying: NowPlayingService?
    var clipboard: ClipboardService?
    var showcase: Showcase?
    /// Закрыть окно настроек (кнопка «Применить»).
    var onApply: () -> Void = {}
    /// Вернуть всё, что поменяли с момента открытия окна, и закрыть (кнопка «Отмена»).
    var onCancel: () -> Void = {}

    @AppStorage(Pref.hoverDelay) var hoverDelay = 0.1
    @AppStorage(Pref.haptics) var haptics = true
    @AppStorage(Pref.showMusicActivity) var showMusic = true
    @AppStorage(Pref.showChargingActivity) var showCharging = true
    @AppStorage(Pref.showLowBattery) var showLowBattery = true
    @AppStorage(Pref.trackBanners) var trackBanners = true
    @AppStorage(Pref.deviceBanners) var deviceBanners = true
    @AppStorage(Pref.browserMusic) var browserMusic = false
    @AppStorage(Pref.systemNowPlaying) var systemNowPlaying = true
    @AppStorage(Pref.systemNotifications) var systemNotifications = true
    @AppStorage(Pref.notchStyle) var notchStyle = "black"
    @AppStorage(Pref.fx3D) var fx3D = true
    @AppStorage(Pref.fxJelly) var fxJelly = true
    @AppStorage(Pref.glassTint) var glassTint = 0.6
    @AppStorage(Pref.screenshotsInHistory) var screenshotsInHistory = true
    @AppStorage(Pref.autoCheckUpdates) var autoCheckUpdates = true
    @AppStorage(Pref.betaUpdates) var betaUpdates = false
    @AppStorage(Pref.clipboardHistory) var clipboardHistory = true
    @AppStorage(Pref.openOnFileDrag) var openOnFileDrag = true
    @AppStorage(Pref.timerSound) var timerSound = true

    @State var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State var loginError: String?
    @State var controlAccess = AXIsProcessTrusted()

    /// Открытый раздел. Хранится в настройках, чтобы, например, баннер обновления открывал сразу «Обновления».
    @AppStorage("settingsPage") private var pageRaw = SettingsPage.general.rawValue

    private var page: SettingsPage {
        get { SettingsPage(rawValue: pageRaw) ?? .general }
        nonmutating set { pageRaw = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            pageBar
                .padding(.top, 30)
                .padding(.bottom, 6)

            // Лиса — вверху каждого раздела.
            FoxBanner()
                .padding(.horizontal, 20)
                .padding(.top, 10)

            Form {
                switch page {
                case .general:
                    Section("Поведение") {
                        Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { _, enabled in
                                setLaunchAtLogin(enabled)
                            }
                        if let loginError {
                            Text(loginError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Задержка открытия при наведении: \(hoverDelay, specifier: "%.2f") с")
                            Slider(value: $hoverDelay, in: 0...0.6, step: 0.02)
                        }
                        Toggle("Тактильный отклик трекпада", isOn: $haptics)
                        Toggle("Открывать полку, когда тащишь файл к чёлке", isOn: $openOnFileDrag)
                    }
                    Section("Живые активности по бокам от выреза") {
                        Toggle("Музыка: обложка и эквалайзер", isOn: $showMusic)
                        Toggle("Анимация при подключении зарядки", isOn: $showCharging)
                    }
                case .look:
                    Section("Оформление") {
                        Picker("Подложка чёлки", selection: $notchStyle) {
                            Text("Чёрная").tag("black")
                            Text("Стекло").tag("glass")
                        }
                        .pickerStyle(.segmented)
                        if notchStyle == "glass" {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Затемнение стекла: \(Int(glassTint * 100))%")
                                Slider(value: $glassTint, in: 0.15...0.85)
                            }
                        }
                        Toggle("Эффект желе при раскрытии", isOn: $fxJelly)
                        Toggle("Объёмная карусель плеера", isOn: $fx3D)
                        Text("В режиме энергосбережения и при включённом «Уменьшить движение» эффекты упрощаются автоматически.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .player:
                    Section("Музыка") {
                        Toggle("Любой плеер через системный «Что играет»", isOn: $systemNowPlaying)
                        if systemNowPlaying, let nowPlaying {
                            PlayerDiagnosticsRow(nowPlaying: nowPlaying)
                        }
                        Text("Показывает трек из любого приложения — Яндекс Музыки, браузера, Spotify. Работает через небольшой помощник, который запускается в системном perl: так macOS отдаёт эти данные. Если что-то не так — выключи, и чёлка вернётся к Spotify, Музыке и браузеру.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Музыка из браузера (Яндекс Музыка, YouTube, SoundCloud, VK)", isOn: $browserMusic)
                        if browserMusic {
                            Text("Один раз включи в браузере разрешение:\n• Chrome / Яндекс Браузер / Edge: меню «Вид» → «Разработчикам» → «Разрешить JavaScript из Apple Events».\n• Safari: «Настройки» → «Дополнения» → «Показывать функции для веб-разработчиков», затем меню «Разработка» → «Разрешить JavaScript из Apple Events».")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Управление любым плеером")
                                Text("Кнопки ⏯ ⏭ ⏮ для приложения Яндекс Музыки и других плееров. Нужен «Универсальный доступ».")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if controlAccess {
                                Label("Разрешено", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button("Разрешить") {
                                    MediaKeys.requestAccess()
                                }
                            }
                        }
                    }
                    AppColorsSection()
                case .notifications:
                    Section("Уведомления в чёлке") {
                        Toggle("Уведомления всех приложений", isOn: $systemNotifications)
                        if systemNotifications, let notifications {
                            NotificationAccessRow(mirror: notifications)
                        }
                        Toggle("Смена трека и видео", isOn: $trackBanners)
                        Toggle("Подключение наушников и колонок", isOn: $deviceBanners)
                        Toggle("Низкий заряд батареи", isOn: $showLowBattery)
                        Toggle("Звук по окончании таймера", isOn: $timerSound)
                    }
                case .clipboard:
                    Section("Буфер обмена") {
                        Toggle("Сохранять историю копирования", isOn: $clipboardHistory)
                        Toggle("Добавлять новые скриншоты", isOn: $screenshotsInHistory)
                            .disabled(!clipboardHistory)
                        if clipboardHistory, screenshotsInHistory, let clipboard {
                            ScreenshotStatusRow(clipboard: clipboard)
                        }
                        Text("История хранится только в памяти и стирается при выходе. Пароли из менеджеров паролей пропускаются. Скриншоты берутся из папки, куда их сохраняет macOS (обычно рабочий стол).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .updates:
                    if let updates {
                        UpdatesSection(updates: updates, autoCheck: $autoCheckUpdates, beta: $betaUpdates)
                    }
                case .test:
                    if let showcase {
                        ShowcaseSection(showcase: showcase)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            footer
        }
        .frame(width: 600, height: 620)
        .background(Color(white: 0.085).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controlAccess = AXIsProcessTrusted()
        }
    }

    /// Разделы как в системных настройках: значок и подпись, выбранный — на светлой плашке.
    private var pageBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsPage.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { page = item }
                } label: {
                    // Значок в рамке фиксированного размера, подпись — на одной линии у всех вкладок.
                    VStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 24, height: 20)
                        Text(item.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .frame(height: 13)
                    }
                    .padding(.top, 7)
                    .foregroundStyle(page == item ? Color.white : Color.white.opacity(0.55))
                    .frame(width: 78, height: 50, alignment: .top)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(page == item ? 0.12 : 0))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Изменения применяются сразу; «Применить» закрывает окно и возвращает фокус туда, где ты был.
    private var footer: some View {
        HStack {
            Text("Halo \(Self.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Отмена") { onCancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button("Применить") { onApply() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.04))
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Не получилось: \(error.localizedDescription). Перенеси приложение в папку «Программы»."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Статус доступа к уведомлениям и подсказки.
private struct NotificationAccessRow: View {
    let mirror: NotificationMirror

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch mirror.status {
            case .running:
                Label("Работает — новые уведомления появятся в чёлке", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Последнее прочитанное") {
                    Text(mirror.lastSeen ?? "пока ничего")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                Text("Если приложения нет в чёлке, проверь в «Системных настройках» → «Уведомления» → приложение, что включено «Показывать в Центре уведомлений»: Halo видит только то, что туда попадает.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Чтобы не было двойных баннеров, в «Системных настройках» → «Уведомления» можно выбрать для приложений стиль «Нет» — в чёлке они всё равно появятся.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .needsAccess, .off:
                Text("macOS не даёт приложениям читать чужие уведомления напрямую. Halo читает журнал Центра уведомлений на твоём Маке (только чтение, никуда не отправляется). Для этого нужен «Полный доступ к диску»: добавь туда Halo и включи переключатель.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Открыть «Полный доступ к диску»") {
                    mirror.openPrivacySettings()
                }
            case .unavailable:
                Text("Не удалось прочитать журнал уведомлений на этой версии macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// «Обновления»: проверка, загрузка с прогрессом и установка в один клик.
private struct UpdatesSection: View {
    let updates: UpdateService
    @Binding var autoCheck: Bool
    @Binding var beta: Bool

    var body: some View {
        Section("Обновления") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .fontWeight(.medium)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                actionButton
            }
            if case .downloading(let progress) = updates.state {
                ProgressView(value: progress)
            } else if case .installing = updates.state {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Toggle("Проверять автоматически", isOn: $autoCheck)
            Toggle("Тестовые сборки", isOn: $beta)
                .onChange(of: beta) { _, _ in updates.check() }
            Text("Свежие версии из разработки — сразу после каждого изменения, ещё до релиза. Могут быть сырыми.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: updates.state) { _, state in
            if Pref.bool(Pref.haptics), state == .available {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch updates.state {
        case .checking, .downloading, .installing:
            ProgressView()
                .controlSize(.small)
        case .available:
            Button("Обновить") { updates.install() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
        default:
            if updates.hasUpdate {
                Button("Обновить") { updates.install() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            } else {
                Button("Проверить") { updates.check() }
            }
        }
    }

    private var isError: Bool {
        if case .failed = updates.state { return true }
        return false
    }

    private var title: String {
        switch updates.state {
        case .checking: return "Проверяю…"
        case .available: return "Доступна версия \(updates.latest?.version ?? "")"
        case .downloading(let progress): return "Загрузка… \(Int(progress * 100))%"
        case .installing: return "Устанавливаю и перезапускаю…"
        case .upToDate: return updates.latest == nil ? "Обновлений пока нет" : "Последняя версия"
        case .failed: return "Не получилось обновить"
        case .idle: return updates.hasUpdate ? "Доступна версия \(updates.latest?.version ?? "")" : "Halo \(updates.currentVersion)"
        }
    }

    private var detail: String {
        switch updates.state {
        case .failed(let message):
            return message
        case .available:
            return "Сейчас \(updates.currentVersion). Скачаю и поставлю сам — переустанавливать ничего не нужно."
        default:
            if let date = updates.lastCheck {
                return "Установлена \(updates.currentVersion) (сборка \(updates.currentBuild)) · проверено \(date.formatted(date: .omitted, time: .shortened))"
            }
            return "Установлена \(updates.currentVersion) (сборка \(updates.currentBuild))"
        }
    }
}

/// Видно ли папку со скриншотами и кнопка «починить».
private struct ScreenshotStatusRow: View {
    let clipboard: ClipboardService

    var body: some View {
        HStack {
            switch clipboard.screenshotAccess {
            case true?:
                Label("Папка со скриншотами доступна", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case false?:
                Label("Нет доступа к папке со скриншотами", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Разрешить") { clipboard.fixScreenshotAccess() }
            case nil:
                Label("Ждём первый скриншот", systemImage: "camera.viewfinder")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, look, player, notifications, clipboard, updates, test

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Основные"
        case .look: return "Вид"
        case .player: return "Плеер"
        case .notifications: return "Уведомления"
        case .clipboard: return "Буфер"
        case .updates: return "Обновления"
        case .test: return "Тест"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .look: return "paintbrush"
        case .player: return "music.note"
        case .notifications: return "bell.badge"
        case .clipboard: return "doc.on.clipboard"
        case .updates: return "arrow.down.circle"
        case .test: return "play.rectangle"
        }
    }
}

/// «Тест»: по кругу показывает все анимации чёлки, пока не нажмёшь «Стоп».
private struct ShowcaseSection: View {
    let showcase: Showcase

    var body: some View {
        Section("Тест анимаций") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(showcase.isRunning ? "Показываю: \(showcase.step)" : "Показать все анимации по очереди")
                        .fontWeight(.medium)
                    Text("«Сейчас играет» и быстрое переключение треков, уведомление, раскрытие и свайп по плееру и разделам, наушники, зарядка, три ступени низкого заряда (20, 10 и 5 %). Идёт по кругу, пока не нажмёшь «Стоп». Твои заметки, полка и история не меняются.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if showcase.isRunning {
                    Button("Стоп") { showcase.stop() }
                        .controlSize(.large)
                        .tint(.red)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Запустить") { showcase.start() }
                        .controlSize(.large)
                }
            }
        }
    }
}

/// Что видит системный «Что играет»: текст целиком, его можно выделить или скопировать кнопкой.
private struct PlayerDiagnosticsRow: View {
    let nowPlaying: NowPlayingService
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Главный плеер в системе")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(copied ? "Скопировано" : "Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .controlSize(.small)
            }
            Text(nowPlaying.systemStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if nowPlaying.readsAllPlayers {
                Text("Сообщают о воспроизведении: \(nowPlaying.otherPlayersStatus ?? "ждём данные…")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("Режим «все плееры» выключен: помощник в нём сбоил, поэтому видно только главный плеер.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var report: String {
        var lines = ["Главный плеер: \(nowPlaying.systemStatus)"]
        if nowPlaying.readsAllPlayers {
            lines.append("Сообщают о воспроизведении: \(nowPlaying.otherPlayersStatus ?? "нет данных")")
        } else {
            lines.append("Режим «все плееры» выключен после сбоя")
        }
        return lines.joined(separator: "\n")
    }
}

/// «Цвета приложений»: цвет, которым подписано приложение в «Сейчас играет». По умолчанию —
/// средний цвет иконки; можно задать свой или сбросить все.
private struct AppColorsSection: View {
    @State private var apps: [String] = AppColorCache.knownApps
    @State private var revision = 0

    var body: some View {
        Section("Цвета приложений") {
            if apps.isEmpty {
                Text("Появятся здесь, когда в чёлке что-нибудь заиграет.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apps, id: \.self) { bundleID in
                    AppColorRow(bundleID: bundleID, revision: revision) { revision += 1 }
                }
            }
            HStack {
                Text("Цвет берётся из иконки приложения один раз и запоминается.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Сбросить цвета плееров") {
                    AppColorCache.resetAll()
                    apps = AppColorCache.knownApps
                    revision += 1
                }
            }
        }
        .onAppear { apps = AppColorCache.knownApps }
    }
}

private struct AppColorRow: View {
    let bundleID: String
    let revision: Int
    var changed: () -> Void

    var body: some View {
        let custom = AppColorCache.isCustom(bundleID)
        HStack(spacing: 10) {
            if let icon = AppColorCache.appIcon(bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            Text(AppColorCache.displayName(bundleID))
            if custom {
                Text("свой")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if custom {
                Button("Как в иконке") {
                    AppColorCache.clearCustom(for: bundleID)
                    changed()
                }
                .controlSize(.small)
            }
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: AppColorCache.color(for: bundleID, icon: nil)) },
                set: { newValue in
                    AppColorCache.setCustom(NSColor(newValue), for: bundleID)
                    changed()
                }
            ), supportsOpacity: false)
            .labelsHidden()
        }
        .id("\(bundleID)-\(revision)")
    }
}
