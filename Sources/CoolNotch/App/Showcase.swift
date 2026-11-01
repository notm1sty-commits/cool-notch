import AppKit
import Observation
import SwiftUI

/// «Тест анимаций» из настроек: по кругу показывает всё, что умеет чёлка, пока не нажмёшь «Стоп».
/// Ничего не трогает в твоих данных: заметки, полка и история остаются как были,
/// а плеер после остановки снова показывает настоящую музыку.
@MainActor
@Observable
final class Showcase {
    private(set) var isRunning = false
    /// Что сейчас показываем — для подписи в настройках.
    private(set) var step = ""

    @ObservationIgnored private weak var vm: NotchViewModel?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(viewModel: NotchViewModel) {
        vm = viewModel
    }

    func start() {
        guard task == nil else { return }
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.playOnce()
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        step = ""
        guard let vm else { return }
        vm.demoHover(false)
        vm.dismissBanner()
        vm.close()
        vm.select(.home)
        vm.nowPlaying.endDemo()
    }

    private func wait(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private static func media(_ music: (title: String, artist: String, art: String)) -> [DemoMedia] {
        let image = DemoDirector.image
        return [
            DemoMedia(source: .music, title: music.title, subtitle: music.artist, artwork: image(music.art), duration: 187, elapsed: 41, playing: true, url: nil),
            DemoMedia(source: .browser(.chrome), title: "Как приготовить идеальный эспрессо", subtitle: "Coffee Lab", artwork: image("v1"), duration: 642, elapsed: 252, playing: false, url: "https://www.youtube.com/watch?v=coolnotch"),
            DemoMedia(source: .spotify, title: "Ночной город", subtitle: "Neon Drive", artwork: image("c2"), duration: 214, elapsed: 96, playing: false, url: nil),
        ]
    }

    /// Один круг. Порядок — как ими пользуются: музыка, уведомление, раскрытая чёлка и свайпы,
    /// устройства и батарея.
    private func playOnce() async throws {
        guard let vm else { return }

        // 1. Заиграл трек — «Сейчас играет · Музыка», эквалайзер цвета обложки.
        step = "Сейчас играет"
        vm.nowPlaying.showDemo(Self.media(("Летний дождь", "Aurora Lane", "c1")))
        try await wait(2.2)

        // 2. Треки быстро листают — всплывашка одна, просто обновляется.
        step = "Быстрое переключение треков"
        vm.nowPlaying.showDemo(Self.media(("Северное сияние", "Polar Echo", "c3")))
        try await wait(0.45)
        vm.nowPlaying.showDemo(Self.media(("Тёплый вечер", "Aurora Lane", "c1")))
        try await wait(4.4)

        // 3. Уведомление: «Сообщения · сейчас», ширина по тексту.
        step = "Уведомление"
        vm.post(NotchBanner(
            icon: .app("com.apple.MobileSMS"),
            tint: .white,
            title: "Аня",
            subtitle: "Это тест анимаций Halo ✨",
            duration: 3.4,
            action: .openNotch,
            source: "Сообщения"
        ))
        try await wait(4.2)

        // 4. Раскрытие и сквозной свайп: карточки плеера, затем разделы.
        step = "Раскрытие"
        vm.demoHover(true)
        try await wait(0.4)
        vm.open(pinned: true)
        try await wait(1.6)

        step = "Свайп по плееру и разделам"
        for _ in 0..<5 {
            vm.swipe(next: true)
            try await wait(1.2)
        }
        for _ in 0..<5 {
            vm.swipe(next: false)
            try await wait(0.7)
        }
        try await wait(0.6)

        step = "Сворачивание"
        vm.demoHover(false)
        vm.close()
        try await wait(1.6)

        // 5. Устройства и батарея.
        step = "Наушники"
        vm.showAirPods(name: "AirPods Pro", levels: AirPodsLevels(left: 92, right: 88, caseLevel: 34, single: nil))
        try await wait(5.4)

        step = "Зарядка"
        vm.flashCharging()
        try await wait(3.8)

        step = "Низкий заряд"
        vm.showLowBattery(level: 20)
        try await wait(5.6)

        step = "Очень низкий заряд"
        vm.showLowBattery(level: 10)
        try await wait(6.6)

        step = "Критический заряд"
        vm.showLowBattery(level: 5)
        try await wait(7.6)
    }
}
