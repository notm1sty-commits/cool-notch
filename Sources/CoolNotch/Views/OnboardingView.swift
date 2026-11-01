import AppKit
import Carbon
import ServiceManagement
import SwiftUI

/// Первый запуск: все разрешения сразу, в одном окне, со статусами.
struct OnboardingView: View {
    var nowPlaying: NowPlayingService?
    var onFinish: () -> Void

    @State private var accessibility = AXIsProcessTrusted()
    @State private var fullDisk = Permissions.hasFullDiskAccess
    @State private var screenshots: Permissions.State = .unknown
    @State private var automation: [Permissions.AutomationTarget] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var requesting = false
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 34)
                .padding(.bottom, 22)

            VStack(spacing: 8) {
                PermissionRow(
                    icon: "hand.raised.fill",
                    tint: .blue,
                    title: "Универсальный доступ",
                    detail: "Кнопки ⏯ ⏭ ⏮ для любого плеера, раскрытие по наведению.",
                    granted: accessibility,
                    action: { MediaKeys.requestAccess(); Permissions.openPane("Privacy_Accessibility") }
                )
                PermissionRow(
                    icon: "internaldrive.fill",
                    tint: .gray,
                    title: "Полный доступ к диску",
                    detail: "Уведомления всех приложений в чёлке. Журнал читается только на этом Маке.",
                    granted: fullDisk,
                    action: { Permissions.openPane("Privacy_AllFiles") }
                )
                PermissionRow(
                    icon: "camera.viewfinder",
                    tint: .purple,
                    title: "Папка со скриншотами",
                    detail: "Новые снимки экрана попадают в историю копирования.",
                    granted: screenshots == .granted,
                    denied: screenshots == .denied,
                    action: { Task { screenshots = await Permissions.requestScreenshotFolder() } }
                )
                PermissionRow(
                    icon: "music.note",
                    tint: .pink,
                    title: "Плееры и браузеры",
                    detail: automationDetail,
                    granted: !automation.isEmpty && automation.allSatisfy { $0.state == .granted },
                    denied: automation.contains { $0.state == .denied },
                    action: { Task { await requestAutomation() } }
                )
                LaunchRow(isOn: $launchAtLogin)
            }
            .padding(.horizontal, 26)

            Spacer(minLength: 18)

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
        .frame(width: 500, height: 640)
        .background(
            ZStack {
                Color.black
                RadialGradient(
                    colors: [Color(red: 0.25, green: 0.27, blue: 0.4).opacity(0.55), .clear],
                    center: .top,
                    startRadius: 10,
                    endRadius: 420
                )
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .task {
            screenshots = await Permissions.screenshotFolderState()
            automation = await Permissions.automationTargets(ask: false)
            withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) { appeared = true }
            // Пока окно открыто, статусы обновляются сами — включил в настройках и сразу видно галочку.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                accessibility = AXIsProcessTrusted()
                fullDisk = Permissions.hasFullDiskAccess
                if screenshots != .granted { screenshots = await Permissions.screenshotFolderState() }
                automation = await Permissions.automationTargets(ask: false)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Capsule()
                    .fill(Color.black)
                    .frame(width: appeared ? 150 : 86, height: appeared ? 42 : 26)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                AngularGradient(
                                    colors: [.white.opacity(0.05), .white.opacity(0.5), .white.opacity(0.05), .white.opacity(0.25), .white.opacity(0.05)],
                                    center: .center
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .white.opacity(appeared ? 0.12 : 0), radius: 18)
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.orange)
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(width: 112)
                .opacity(appeared ? 1 : 0)
            }
            .frame(height: 44)

            Text("Cool Notch")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Пара разрешений — и чёлка заработает на полную:\nмузыка и видео, уведомления, скриншоты.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var allGranted: Bool {
        accessibility && fullDisk && screenshots == .granted
            && automation.allSatisfy { $0.state == .granted || $0.state == .notRunning }
    }

    private var automationDetail: String {
        let running = automation.filter { $0.state != .notRunning }
        if automation.isEmpty { return "Трек и переход к вкладке: Музыка, Spotify, браузеры." }
        if running.isEmpty {
            return "Спросим, когда откроешь \(automation.map(\.name).prefix(3).joined(separator: ", "))."
        }
        let names = automation.map { target in
            switch target.state {
            case .granted: return "\(target.name) ✓"
            case .denied: return "\(target.name) ✕"
            default: return target.name
            }
        }
        return names.joined(separator: " · ")
    }

    private func requestAutomation() async {
        automation = await Permissions.automationTargets(ask: true)
        if automation.contains(where: { $0.state == .denied }) {
            Permissions.openPane("Privacy_Automation")
        }
    }

    private func requestAll() async {
        requesting = true
        defer { requesting = false }
        if !accessibility {
            MediaKeys.requestAccess()
            try? await Task.sleep(for: .milliseconds(600))
        }
        if screenshots != .granted {
            screenshots = await Permissions.requestScreenshotFolder()
        }
        await requestAutomation()
        if !fullDisk {
            // Этот доступ macOS выдаёт только руками — открываем нужный раздел.
            Permissions.openPane("Privacy_AllFiles")
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    var granted: Bool
    var denied = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(denied ? "Настройки" : "Разрешить", action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(hovering ? 0.22 : 0.14)))
                    .onHover { hovering = $0 }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(granted ? 0.04 : 0.08), lineWidth: 0.5)
                )
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: granted)
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
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.gradient))
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

    /// Плееры и браузеры, установленные на Маке, и статус «Автоматизации» для каждого.
    /// macOS умеет спрашивать только про запущенные приложения — остальные спросит при первом использовании.
    static func automationTargets(ask: Bool) async -> [AutomationTarget] {
        let installed = automationApps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return await Task.detached {
            installed.map { bundleID, name in
                guard running.contains(bundleID) else {
                    return AutomationTarget(bundleID: bundleID, name: name, state: .notRunning)
                }
                return AutomationTarget(bundleID: bundleID, name: name, state: automationState(bundleID, ask: ask))
            }
        }.value
    }

    private static func automationState(_ bundleID: String, ask: Bool) -> State {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBufferPointer { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &target)
        }
        guard created == OSErr(noErr) else { return .unknown }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case OSStatus(noErr): return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .unknown
        }
    }
}
