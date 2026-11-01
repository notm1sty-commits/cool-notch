import AppKit
import Carbon
import ServiceManagement
import SwiftUI

/// Первый запуск: все разрешения сразу, в одном окне, со статусами.
struct OnboardingView: View {
    var onFinish: () -> Void
    /// Вернуть окно на передний план (например, когда в Системных настройках что-то включили).
    var bringToFront: () -> Void = {}

    @State private var accessibility = AXIsProcessTrusted()
    @State private var fullDisk = Permissions.hasFullDiskAccess
    @State private var screenshots: Permissions.State = .unknown
    @State private var automation: [Permissions.AutomationTarget] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var requesting = false
    @State private var askingAutomation = false
    /// Когда что-то уже просили: если галочки так и нет, предлагаем сброс.
    @State private var askedAccessibility: Date?
    @State private var askedFullDisk: Date?
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 34)
                .padding(.bottom, 20)

            VStack(spacing: 8) {
                PermissionRow(
                    icon: "hand.raised.fill",
                    tint: .blue,
                    title: "Универсальный доступ",
                    detail: "Кнопки ⏯ ⏭ ⏮ для любого плеера.",
                    status: accessibility ? .granted : .needed,
                    hint: stuck(askedAccessibility, granted: accessibility) ? Self.staleHint : nil,
                    action: { requestAccessibility() },
                    reset: stuck(askedAccessibility, granted: accessibility) ? { Task { await resetAccessibility() } } : nil
                )
                PermissionRow(
                    icon: "internaldrive.fill",
                    tint: .gray,
                    title: "Полный доступ к диску",
                    detail: "Уведомления всех приложений и скриншоты. Всё читается только на этом Маке.",
                    status: fullDisk ? .granted : .needed,
                    hint: stuck(askedFullDisk, granted: fullDisk) ? Self.staleHint : nil,
                    action: { requestFullDisk() },
                    reset: stuck(askedFullDisk, granted: fullDisk) ? { Task { await resetFullDisk() } } : nil
                )
                PermissionRow(
                    icon: "camera.viewfinder",
                    tint: .purple,
                    title: "Папка со скриншотами",
                    detail: "Новые снимки экрана попадают в историю копирования.",
                    status: screenshots == .granted || fullDisk ? .granted : (screenshots == .denied ? .denied : .needed),
                    action: { Task { screenshots = await Permissions.requestScreenshotFolder() } },
                    reset: screenshots == .denied && !fullDisk ? { Task { await resetScreenshots() } } : nil
                )
                PermissionRow(
                    icon: "music.note",
                    tint: .pink,
                    title: "Плееры и браузеры",
                    detail: automationDetail,
                    status: automationStatus,
                    busy: askingAutomation,
                    action: { Task { await requestAutomation() } },
                    reset: automationStatus == .denied ? { Task { await resetAutomation() } } : nil
                )
                LaunchRow(isOn: $launchAtLogin)
            }
            .padding(.horizontal, 26)

            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Button {
                    Task { await requestAll() }
                } label: {
                    HStack(spacing: 8) {
                        if requesting {
                            ProgressView().controlSize(.small)
                        }
                        Text(allGranted ? "Всё разрешено" : "Разрешить всё")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(allGranted ? Color.green.opacity(0.85) : Color.white)
                    )
                    .foregroundStyle(allGranted ? Color.white : Color.black)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.98))
                .disabled(requesting || allGranted)

                Button(allGranted ? "Начать" : "Продолжить без части разрешений") {
                    onFinish()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: allGranted ? .semibold : .regular))
                .foregroundStyle(allGranted ? Color.white : Color.white.opacity(0.55))
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 24)
        }
        .frame(width: 500, height: 660)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            screenshots = await Permissions.screenshotFolderState()
            automation = await Permissions.automationTargets()
            // Пока окно открыто, статусы обновляются сами — включил в настройках и сразу видно галочку.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
                let trusted = AXIsProcessTrusted()
                let disk = Permissions.hasFullDiskAccess
                // Что-то включили в Системных настройках — возвращаем окно, чтобы было видно галочку.
                if (trusted && !accessibility) || (disk && !fullDisk) { bringToFront() }
                accessibility = trusted
                fullDisk = disk
                if screenshots != .granted { screenshots = await Permissions.screenshotFolderState() }
                if !askingAutomation { automation = await Permissions.automationTargets() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .frame(width: 150, height: 40)
            .background(Capsule().fill(Color(white: 0.1)))

            Text("Cool Notch")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Пара разрешений — и чёлка заработает на полную:\nмузыка и видео, уведомления, скриншоты.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private static let staleHint = "Уже включено, а галочки нет? macOS помнит прошлую версию Cool Notch. Нажми «Сбросить», затем включи переключатель ещё раз."

    /// Просили больше 4 секунд назад, а доступа всё нет.
    private func stuck(_ asked: Date?, granted: Bool) -> Bool {
        guard let asked, !granted else { return false }
        return now.timeIntervalSince(asked) > 4
    }

    private var running: [Permissions.AutomationTarget] {
        automation.filter { $0.state != .notRunning }
    }

    private var automationStatus: PermissionRow.Status {
        if running.isEmpty { return .later }
        if running.contains(where: { $0.state == .denied }) { return .denied }
        if running.allSatisfy({ $0.state == .granted }) { return .granted }
        return .needed
    }

    private var automationDetail: String {
        if automation.isEmpty { return "Название трека и переход к вкладке: Музыка, Spotify, браузеры." }
        if running.isEmpty {
            let names = automation.map(\.name).prefix(3).joined(separator: ", ")
            return "macOS спросит, когда откроешь \(names). Можно открыть сейчас и нажать «Разрешить»."
        }
        return running.map { target in
            switch target.state {
            case .granted: return "\(target.name) ✓"
            case .denied: return "\(target.name) — запрещено"
            default: return target.name
            }
        }
        .joined(separator: " · ")
    }

    private var allGranted: Bool {
        accessibility && fullDisk && automationStatus != .denied && automationStatus != .needed
    }

    // MARK: - Requests

    private func requestAccessibility() {
        askedAccessibility = Date()
        MediaKeys.requestAccess()
        Permissions.openPane("Privacy_Accessibility")
    }

    private func requestFullDisk() {
        askedFullDisk = Date()
        // Этот доступ macOS выдаёт только руками — открываем нужный раздел.
        Permissions.openPane("Privacy_AllFiles")
    }

    private func requestAutomation() async {
        askingAutomation = true
        defer { askingAutomation = false }
        var targets = await Permissions.automationTargets()
        if !targets.contains(where: { $0.state != .notRunning }) {
            // Ничего не запущено — тихо открываем браузер по умолчанию, чтобы macOS было про что спросить.
            await Permissions.launchDefaultBrowserHidden()
            targets = await Permissions.automationTargets()
        }
        for index in targets.indices where targets[index].state != .notRunning && targets[index].state != .granted {
            // Настоящий запрос к приложению вызывает системный вопрос «Разрешить управлять…?».
            targets[index].state = await Permissions.askAutomation(targets[index].bundleID)
            automation = targets
        }
        automation = await Permissions.automationTargets()
        if automationStatus == .denied { Permissions.openPane("Privacy_Automation") }
    }

    private func requestAll() async {
        requesting = true
        defer { requesting = false }
        if !accessibility {
            askedAccessibility = Date()
            MediaKeys.requestAccess()
            try? await Task.sleep(for: .milliseconds(800))
        }
        if screenshots != .granted && !fullDisk {
            screenshots = await Permissions.requestScreenshotFolder()
        }
        await requestAutomation()
        if !fullDisk {
            requestFullDisk()
        } else if !accessibility {
            Permissions.openPane("Privacy_Accessibility")
        }
    }

    // MARK: - Reset (после переустановки macOS держит запись о прежней сборке)

    private func resetAccessibility() async {
        await Permissions.reset("Accessibility")
        askedAccessibility = Date()
        MediaKeys.requestAccess()
        Permissions.openPane("Privacy_Accessibility")
    }

    private func resetFullDisk() async {
        await Permissions.reset("SystemPolicyAllFiles")
        requestFullDisk()
    }

    private func resetScreenshots() async {
        await Permissions.reset("SystemPolicyDesktopFolder")
        screenshots = await Permissions.requestScreenshotFolder()
    }

    private func resetAutomation() async {
        await Permissions.reset("AppleEvents")
        await requestAutomation()
    }
}

private struct PermissionRow: View {
    enum Status: Equatable {
        case needed, granted, denied, later
    }

    let icon: String
    let tint: Color
    let title: String
    let detail: String
    var status: Status
    var busy = false
    var hint: String?
    var action: () -> Void
    var reset: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 44)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: status)
        .animation(.easeInOut(duration: 0.2), value: hint)
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            if let reset {
                pill("Сбросить", action: reset)
            }
            switch status {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.green)
                    .transition(.scale.combined(with: .opacity))
            case .later:
                pill("Разрешить", action: action)
                    .opacity(0.7)
            case .needed, .denied:
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    pill(status == .denied ? "Настройки" : "Разрешить", action: action)
                }
            }
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.22 : 0.14)))
            .onHover { hovering = $0 }
    }
}

private struct LaunchRow: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "power")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text("Запускать при входе")
                    .font(.system(size: 13, weight: .semibold))
                Text("Чёлка будет на месте после перезагрузки.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: isOn) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        isOn = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }
}

/// Проверка и запрос разрешений macOS.
enum Permissions {
    enum State: Equatable {
        case unknown, granted, denied, notRunning
    }

    struct AutomationTarget: Equatable {
        let bundleID: String
        let name: String
        var state: State
    }

    static func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Сбрасывает запись о разрешении для Cool Notch. Нужна после обновления ad-hoc сборки:
    /// переключатель в настройках включён, но относится к прежней версии приложения.
    static func reset(_ service: String) async {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {}
        }.value
    }

    /// Полный доступ к диску: пробуем открыть журнал уведомлений (без доступа macOS не даст).
    static var hasFullDiskAccess: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    private static let screenshotAskedKey = "screenshotFolderAsked"

    /// Статус доступа к папке скриншотов. Пока мы не спрашивали — не трогаем папку, чтобы не вызвать запрос.
    static func screenshotFolderState() async -> State {
        guard UserDefaults.standard.bool(forKey: screenshotAskedKey) else { return .unknown }
        return await readScreenshotFolder()
    }

    /// Чтение папки вызывает системный запрос «Разрешить доступ к папке „Рабочий стол“».
    static func requestScreenshotFolder() async -> State {
        UserDefaults.standard.set(true, forKey: screenshotAskedKey)
        return await readScreenshotFolder()
    }

    private static func readScreenshotFolder() async -> State {
        let folder = ClipboardService.screenshotFolder
        return await Task.detached {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                return State.granted
            } catch {
                return State.denied
            }
        }.value
    }

    private static let automationApps: [(String, String)] = [
        ("com.apple.Music", "Музыка"),
        ("com.spotify.client", "Spotify"),
        ("com.apple.Safari", "Safari"),
        ("com.google.Chrome", "Chrome"),
        ("ru.yandex.desktop.yandex-browser", "Яндекс Браузер"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.brave.Browser", "Brave"),
    ]

    /// Плееры и браузеры, установленные на Маке, и статус «Автоматизации» для каждого (без вопросов).
    /// macOS умеет спрашивать только про запущенные приложения — остальные спросит при первом использовании.
    static func automationTargets() async -> [AutomationTarget] {
        let installed = automationApps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return await Task.detached {
            installed.map { bundleID, name in
                guard running.contains(bundleID) else {
                    return AutomationTarget(bundleID: bundleID, name: name, state: .notRunning)
                }
                return AutomationTarget(bundleID: bundleID, name: name, state: automationState(bundleID))
            }
        }.value
    }

    /// Запускает браузер по умолчанию в фоне (без окна на переднем плане), если это один из поддерживаемых.
    @MainActor
    static func launchDefaultBrowserHidden() async {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier,
              automationApps.contains(where: { $0.0 == bundleID }) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        try? await Task.sleep(for: .seconds(1.5))
    }

    private static let scriptQueue = DispatchQueue(label: "com.notm1sty.coolnotch.permissions")

    /// Отправляет приложению безобидную команду — так macOS показывает вопрос «Разрешить управлять…?».
    static func askAutomation(_ bundleID: String) async -> State {
        let isPlayer = bundleID == "com.apple.Music" || bundleID == "com.spotify.client"
        let source = isPlayer
            ? "tell application id \"\(bundleID)\" to get player state"
            : "tell application id \"\(bundleID)\" to count windows"
        let code: Int = await withCheckedContinuation { continuation in
            scriptQueue.async {
                var error: NSDictionary?
                _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
                continuation.resume(returning: (error?[NSAppleScript.errorNumber] as? Int) ?? 0)
            }
        }
        switch code {
        case 0: return .granted
        case -1743: return .denied
        default: return automationState(bundleID)
        }
    }

    private static func automationState(_ bundleID: String) -> State {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBufferPointer { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &target)
        }
        guard created == OSErr(noErr) else { return .unknown }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        switch status {
        case OSStatus(noErr): return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .unknown
        }
    }
}
