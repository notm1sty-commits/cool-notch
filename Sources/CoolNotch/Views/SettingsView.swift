import ApplicationServices
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.hoverDelay) var hoverDelay = 0.1
    @AppStorage(Pref.haptics) var haptics = true
    @AppStorage(Pref.showMusicActivity) var showMusic = true
    @AppStorage(Pref.showChargingActivity) var showCharging = true
    @AppStorage(Pref.showLowBattery) var showLowBattery = true
    @AppStorage(Pref.trackBanners) var trackBanners = true
    @AppStorage(Pref.deviceBanners) var deviceBanners = true
    @AppStorage(Pref.browserMusic) var browserMusic = false
    @AppStorage(Pref.systemNowPlaying) var systemNowPlaying = true
    @AppStorage(Pref.clipboardHistory) var clipboardHistory = true
    @AppStorage(Pref.openOnFileDrag) var openOnFileDrag = true
    @AppStorage(Pref.timerSound) var timerSound = true

    @State var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State var loginError: String?
    @State var controlAccess = AXIsProcessTrusted()

    var body: some View {
        Form {
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

            Section("Уведомления в чёлке") {
                Toggle("Смена трека", isOn: $trackBanners)
                Toggle("Подключение наушников и колонок", isOn: $deviceBanners)
                Toggle("Низкий заряд батареи", isOn: $showLowBattery)
                Toggle("Звук по окончании таймера", isOn: $timerSound)
            }

            Section("Живые активности по бокам от выреза") {
                Toggle("Музыка: обложка и эквалайзер", isOn: $showMusic)
                Toggle("Анимация при подключении зарядки", isOn: $showCharging)
            }

            Section("Музыка") {
                Toggle("Любой плеер через системный «Что играет»", isOn: $systemNowPlaying)
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

            Section("Буфер обмена") {
                Toggle("Сохранять историю копирования", isOn: $clipboardHistory)
                Text("История хранится только в памяти и стирается при выходе. Пароли из менеджеров паролей пропускаются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Cool Notch")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("версия \(Self.version)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controlAccess = AXIsProcessTrusted()
        }
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
