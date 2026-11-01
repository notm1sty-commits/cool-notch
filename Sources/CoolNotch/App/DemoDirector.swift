import AppKit
import SwiftUI

/// Демо-режим (`--demo`): сам проигрывает сценарий — музыка и видео, уведомления, раскрытие,
/// карусель источников, вкладки, AirPods, зарядка. Нужен, чтобы записать видео интерфейса
/// на машине без плееров и без курсора (см. scripts/record-demo.sh).
@MainActor
final class DemoDirector {
    private let vm: NotchViewModel
    private var backdrop: NSWindow?

    init(viewModel: NotchViewModel) {
        vm = viewModel
    }

    func run() {
        showBackdrop()
        Task { await play() }
    }

    static func image(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "Demo") else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Обои под чёлкой, чтобы на записи было видно форму и стекло.
    private func showBackdrop() {
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: DemoWallpaper(image: Self.image("wall")))
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        backdrop = window
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func media(musicTitle: String, musicSubtitle: String, musicArt: String, musicElapsed: Double) -> [DemoMedia] {
        [
            DemoMedia(source: .music, title: musicTitle, subtitle: musicSubtitle, artwork: Self.image(musicArt), duration: 187, elapsed: musicElapsed, playing: true, url: nil),
            DemoMedia(source: .browser(.chrome), title: "Как приготовить идеальный эспрессо", subtitle: "Coffee Lab · 1,2 млн просмотров", artwork: Self.image("v1"), duration: 642, elapsed: 252, playing: false, url: "https://www.youtube.com/watch?v=coolnotch"),
            DemoMedia(source: .spotify, title: "Ночной город", subtitle: "Neon Drive — Afterglow", artwork: Self.image("c2"), duration: 214, elapsed: 96, playing: false, url: nil),
        ]
    }

    private func play() async {
        prepareData()
        await wait(3)  // запись видео стартует чуть позже приложения

        // 1. Заиграла музыка — по бокам выреза появляются обложка и эквалайзер.
        vm.nowPlaying.showDemo(media(musicTitle: "Летний дождь", musicSubtitle: "Aurora Lane — Seasons", musicArt: "c1", musicElapsed: 41))
        await wait(3)

        // 2. Смена трека — баннер выезжает из чёлки.
        vm.nowPlaying.showDemo(media(musicTitle: "Северное сияние", musicSubtitle: "Polar Echo — Lumen", musicArt: "c3", musicElapsed: 2))
        await wait(4.2)

        // 3. Пришло сообщение — уведомление в чёлке со свечением контура.
        vm.post(NotchBanner(
            icon: .app("com.apple.MobileSMS"),
            tint: .white,
            title: "Аня",
            subtitle: "Ты видел новую чёлку? Выглядит прямо как на iPhone, всё такое плавное 😍",
            duration: 4,
            action: .openApp("com.apple.MobileSMS"),
            expanded: true,
            glows: true
        ))
        await wait(4.8)

        // 4. Наведение: чёлка чуть подрастает, затем раскрывается стеклянной панелью.
        vm.demoHover(true)
        await wait(0.6)
        vm.open()
        await wait(2.4)

        // 5. Таймер.
        withAnimation(Theme.content) { vm.timer.start(seconds: 25 * 60) }
        await wait(1.8)

        // 6. Листаем источники: YouTube на паузе, Spotify, обратно.
        vm.selectDeck(1)
        await wait(2.2)
        vm.selectDeck(2)
        await wait(2)
        vm.selectDeck(1)
        await wait(1.4)

        // 7. Запускаем видео — музыка встаёт на паузу, видео становится главным.
        vm.nowPlaying.setDemoPlaying(.browser(.chrome), true)
        vm.selectDeck(0)
        await wait(2.4)
        vm.nowPlaying.setDemoPlaying(.music, true)
        await wait(2)

        // 8. Вкладки.
        for tab in [NotchTab.shelf, .clipboard, .notes, .home] {
            withAnimation(Theme.content) { vm.select(tab) }
            await wait(1.7)
        }

        // 9. Курсор ушёл — чёлка сворачивается в «ушки» с таймером.
        vm.demoHover(false)
        vm.close()
        await wait(2.4)

        // 10. Подключились AirPods.
        vm.showAirPods(name: "AirPods Pro", levels: AirPodsLevels(left: 92, right: 88, caseLevel: 34, single: nil))
        await wait(5.6)

        // 11. Подключили зарядку.
        vm.flashCharging()
        await wait(4.2)

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
            ("Встреча в 19:30 у кофейни", "Сообщения"),
            ("hello@coolnotch.app", "Почта"),
            ("Купить: молоко, кофе, бананы", "Заметки"),
        ])
        if let shot = Self.image("wall") {
            vm.clipboard.insertDemoImage(shot, title: "Снимок экрана 2026-11-01 в 12.30.15")
        }

        let now = Date()
        vm.notes.replaceAll([
            NotesStore.Note(text: "Купить: молоко, кофе, бананы", date: now.addingTimeInterval(-600)),
            NotesStore.Note(text: "Позвонить маме в 18:00", date: now.addingTimeInterval(-3600)),
            NotesStore.Note(text: "Доделать презентацию к пятнице", date: now.addingTimeInterval(-7200)),
        ])
    }
}

/// Обои для записи демо.
private struct DemoWallpaper: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.12, blue: 0.36), Color(red: 0.48, green: 0.26, blue: 0.6)], startPoint: .top, endPoint: .bottom)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .ignoresSafeArea()
    }
}
