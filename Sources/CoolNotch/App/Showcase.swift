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
                do {
                    try await self?.playOnce()
                } catch {
                    break
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
        vm.nowPlaying.endDemo()
    }

    private func wait(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func playOnce() async throws {
        guard let vm else { return }
        let image = DemoDirector.image

        step = "Смена трека"
        vm.nowPlaying.showDemo([
            DemoMedia(source: .music, title: "Летний дождь", subtitle: "Aurora Lane — Seasons", artwork: image("c1"), duration: 187, elapsed: 41, playing: true, url: nil),
            DemoMedia(source: .browser(.chrome), title: "Как приготовить идеальный эспрессо", subtitle: "Coffee Lab", artwork: image("v1"), duration: 642, elapsed: 252, playing: false, url: "https://www.youtube.com/watch?v=coolnotch"),
            DemoMedia(source: .spotify, title: "Ночной город", subtitle: "Neon Drive — Afterglow", artwork: image("c2"), duration: 214, elapsed: 96, playing: false, url: nil),
        ])
        try await wait(3.6)

        step = "Уведомление"
        vm.post(NotchBanner(
            icon: .app("com.apple.MobileSMS"),
            tint: .white,
            title: "Аня",
            subtitle: "Это тест анимаций Cool Notch ✨",
            duration: 3.4,
            action: .openNotch,
            expanded: true,
            glows: true
        ))
        try await wait(4.4)

        step = "Раскрытие"
        vm.demoHover(true)
        try await wait(0.5)
        vm.open(pinned: true)
        try await wait(1.8)

        step = "Карусель плеера"
        for index in [1, 2, 0] {
            vm.selectDeck(index)
            try await wait(1.5)
        }

        step = "Вкладки"
        for tab in [NotchTab.shelf, .clipboard, .notes, .home] {
            withAnimation(Theme.content) { vm.select(tab) }
            try await wait(1.4)
        }

        step = "Сворачивание"
        vm.demoHover(false)
        vm.close()
        try await wait(1.6)

        step = "AirPods"
        vm.showAirPods(name: "AirPods Pro", levels: AirPodsLevels(left: 92, right: 88, caseLevel: 34, single: nil))
        try await wait(5)

        step = "Зарядка"
        vm.flashCharging()
        try await wait(3.6)

        step = "Низкий заряд"
        vm.post(NotchBanner(
            icon: .symbol("battery.25percent"),
            tint: .red,
            title: "Низкий заряд",
            subtitle: "Это тест — с батареей всё в порядке",
            duration: 3
        ))
        try await wait(4)
    }
}
