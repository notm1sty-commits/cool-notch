import AppKit
import SwiftUI

/// Демо-режим (`--demo`): сам проигрывает сценарий — музыка, баннеры, раскрытие, вкладки.
/// Нужен, чтобы записать видео интерфейса на машине без плееров и без курсора.
@MainActor
final class DemoDirector {
    private let vm: NotchViewModel

    init(viewModel: NotchViewModel) {
        vm = viewModel
    }

    func run() {
        Task { await play() }
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func play() async {
        prepareData()
        await wait(3)  // запись видео стартует чуть позже приложения

        // 1. Заиграла музыка — по бокам выреза появляются обложка и эквалайзер.
        vm.nowPlaying.showDemo(
            track: NowPlayingTrack(title: "Ночной город", artist: "Neon Drive", album: "Afterglow", duration: 214),
            artwork: Self.artwork(colors: [NSColor(red: 0.98, green: 0.36, blue: 0.55, alpha: 1), NSColor(red: 0.45, green: 0.2, blue: 0.95, alpha: 1)]),
            playing: true,
            elapsed: 48
        )
        await wait(3)

        // 2. Смена трека — баннер выезжает из чёлки.
        vm.nowPlaying.showDemo(
            track: NowPlayingTrack(title: "Летний дождь", artist: "Aurora Lane", album: "Seasons", duration: 187),
            artwork: Self.artwork(colors: [NSColor(red: 1, green: 0.67, blue: 0.25, alpha: 1), NSColor(red: 0.95, green: 0.28, blue: 0.4, alpha: 1)]),
            playing: true,
            elapsed: 3
        )
        await wait(4.5)

        // 3. Наведение: чёлка чуть подрастает, затем раскрывается.
        vm.demoHover(true)
        await wait(0.6)
        vm.open()
        await wait(2.2)

        // 4. Запускаем таймер.
        withAnimation(Theme.content) { vm.timer.start(minutes: 25) }
        await wait(2)

        // 5. Листаем вкладки.
        for tab in [NotchTab.shelf, .clipboard, .notes, .home] {
            withAnimation(Theme.content) { vm.select(tab) }
            await wait(2)
        }

        // 6. Пауза и снова воспроизведение.
        vm.nowPlaying.setDemoPlaying(false)
        await wait(1.4)
        vm.nowPlaying.setDemoPlaying(true)
        await wait(1.2)

        // 7. Курсор ушёл — чёлка сворачивается обратно в «ушки» с таймером.
        vm.demoHover(false)
        vm.close()
        await wait(2.5)

        // 8. Подключились AirPods.
        vm.post(NotchBanner(
            icon: .symbol("airpodspro"),
            tint: Color(red: 0.35, green: 0.68, blue: 1),
            title: "AirPods Pro",
            subtitle: "Подключено"
        ))
        await wait(5)

        // 9. Подключили зарядку.
        vm.flashCharging()
        await wait(4.5)

        print("DEMO_DONE")
        fflush(stdout)
    }

    private func prepareData() {
        vm.battery.applyDemo(level: 76, charging: false)

        // Файлы на полке — пустые, нужны только иконки.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CoolNotchDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["Презентация.key", "Отчёт.pdf", "Фото отпуска.jpg", "Трек.mp3"]
        let urls = names.map { folder.appendingPathComponent($0) }
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        vm.shelf.clear()
        vm.shelf.add(urls)

        vm.clipboard.insertDemo([
            ("https://music.yandex.ru/album/123", "Safari"),
            ("Встреча в 19:30 у кофейни", "Telegram"),
            ("hello@coolnotch.app", "Почта"),
            ("4276 1600 0000 0000", "Заметки"),
        ])

        UserDefaults.standard.set("Купить: молоко, кофе, бананы\nПозвонить маме в 18:00\nДоделать презентацию 🎯", forKey: Pref.notesText)
    }

    /// Обложка-заглушка: градиент и нота.
    static func artwork(colors: [NSColor]) -> NSImage {
        let size = NSSize(width: 300, height: 300)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: -45)
            if let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 120, weight: .semibold)) {
                let tinted = NSImage(size: symbol.size, flipped: false) { symbolRect in
                    symbol.draw(in: symbolRect)
                    NSColor.white.withAlphaComponent(0.9).set()
                    symbolRect.fill(using: .sourceAtop)
                    return true
                }
                let origin = NSPoint(x: rect.midX - tinted.size.width / 2, y: rect.midY - tinted.size.height / 2)
                tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
    }
}
