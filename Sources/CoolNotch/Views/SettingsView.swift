import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.hoverDelay) var hoverDelay = 0.12
    @AppStorage(Pref.haptics) var haptics = true
    @AppStorage(Pref.showMusicActivity) var showMusic = true
    @AppStorage(Pref.showChargingActivity) var showCharging = true
    @AppStorage(Pref.showLowBattery) var showLowBattery = true
    @AppStorage(Pref.clipboardHistory) var clipboardHistory = true
    @AppStorage(Pref.openOnFileDrag) var openOnFileDrag = true
    @AppStorage(Pref.timerSound) var timerSound = true

    @State var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State var loginError: String?

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

            Section("Живые активности в свёрнутой чёлке") {
                Toggle("Музыка: обложка и эквалайзер", isOn: $showMusic)
                Toggle("Анимация при подключении зарядки", isOn: $showCharging)
                Toggle("Предупреждение о низком заряде", isOn: $showLowBattery)
                Toggle("Звук по окончании таймера", isOn: $timerSound)
            }

            Section("Буфер обмена") {
                Toggle("Сохранять историю копирования", isOn: $clipboardHistory)
                Text("История хранится только в памяти и стирается при выходе. Пароли из менеджеров паролей пропускаются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Музыка") {
                Text("Поддерживаются Spotify и Музыка (Apple Music). При первом запуске macOS спросит разрешение управлять ими — нажми «OK».")
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
        .frame(width: 460, height: 560)
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
