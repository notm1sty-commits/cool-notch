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

    private var backdrop: NSWindow?

    func run() {
        showBackdrop()
        Task { await play() }
    }

    /// Обои под чёлкой, чтобы на записи было видно её форму.
    private func showBackdrop() {
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: DemoWallpaper())
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        backdrop = window
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

        // 2б. Пришло сообщение — системное уведомление в чёлке.
        vm.post(NotchBanner(
            icon: .app("com.apple.MobileSMS"),
            tint: .white,
            title: "Аня",
            subtitle: "Ты видел новую чёлку? Выглядит прямо как на iPhone, очень плавно!",
            duration: 4,
            action: .openApp("com.apple.MobileSMS"),
            expanded: true
        ))
        await wait(5)

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

        // 6б. Включили видео на YouTube — оно запущено последним, поэтому теперь в чёлке оно.
        vm.nowPlaying.showDemo(
            track: NowPlayingTrack(title: "Как приготовить идеальный эспрессо", artist: "Coffee Lab · YouTube", album: "", duration: 642),
            artwork: Self.artwork(colors: [NSColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1), NSColor(red: 0.35, green: 0.08, blue: 0.08, alpha: 1)]),
            playing: true,
            elapsed: 95,
            source: .browser(.chrome)
        )
        await wait(2.5)

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

/// Обои для записи демо: мягкий градиент в духе macOS.
private struct DemoWallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.22, blue: 0.52), Color(red: 0.55, green: 0.32, blue: 0.75), Color(red: 0.98, green: 0.62, blue: 0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color(red: 0.3, green: 0.75, blue: 0.95).opacity(0.55))
                .frame(width: 700, height: 700)
                .blur(radius: 140)
                .offset(x: -300, y: -220)
            Circle()
                .fill(Color(red: 1, green: 0.45, blue: 0.6).opacity(0.5))
                .frame(width: 600, height: 600)
                .blur(radius: 140)
                .offset(x: 320, y: 160)
        }
        .ignoresSafeArea()
    }
}
