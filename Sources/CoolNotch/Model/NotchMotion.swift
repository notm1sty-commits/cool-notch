import AppKit
import QuartzCore

/// Параметры пружины в терминах Apple: время отклика и доля затухания.
struct SpringFeel {
    var response: Double
    var damping: Double

    var stiffness: Double { pow(2 * .pi / response, 2) }
    var friction: Double { 4 * .pi * damping / response }
}

/// Одна пружинная величина (полу-неявный Эйлер с подшагами — стабильно на любой частоте кадров).
struct SpringValue {
    var value: Double
    var velocity: Double = 0
    var target: Double
    var feel = SpringFeel(response: 0.5, damping: 0.8)

    init(_ value: Double) {
        self.value = value
        self.target = value
    }

    /// Возвращает true, пока пружина ещё движется.
    mutating func step(_ dt: Double) -> Bool {
        var steps = max(1, Int((dt * 240).rounded()))
        let h = dt / Double(steps)
        let k = feel.stiffness, c = feel.friction
        while steps > 0 {
            let acceleration = -k * (value - target) - c * velocity
            velocity += acceleration * h
            value += velocity * h
            steps -= 1
        }
        if abs(velocity) < 0.02, abs(value - target) < 0.02 {
            value = target
            velocity = 0
            return false
        }
        return true
    }
}

/// Геометрия чёлки на собственной пружинной физике, синхронно с кадрами дисплея.
/// Каждый кадр отдаётся прямо в Core Animation (`onFrame`) — SwiftUI при этом не пересчитывается,
/// поэтому движение остаётся плавным даже с тенью, стеклом и эффектами.
@MainActor
final class NotchMotion {
    struct Geometry: Equatable {
        var width: CGFloat
        var height: CGFloat
        var bottomRadius: CGFloat
        var shoulder: CGFloat
    }

    struct Frame {
        var geometry: Geometry
        /// Скорость изменения ширины и высоты (пт/с) — для «желе» и RGB-кромки.
        var widthVelocity: CGFloat
        var heightVelocity: CGFloat
        var isMoving: Bool
    }

    enum Feel {
        case open, close, morph, hover
    }

    var onFrame: ((Frame) -> Void)?
    weak var host: NSView?

    private var springs: [SpringValue] = [SpringValue(185), SpringValue(32), SpringValue(10), SpringValue(6)]
    private var link: CADisplayLink?
    private var proxy: DisplayLinkProxy?
    private var lastTimestamp: CFTimeInterval = 0

    var current: Frame {
        Frame(
            geometry: Geometry(
                width: CGFloat(springs[0].value),
                height: CGFloat(springs[1].value),
                bottomRadius: CGFloat(max(0, springs[2].value)),
                shoulder: CGFloat(max(0, springs[3].value))
            ),
            widthVelocity: CGFloat(springs[0].velocity),
            heightVelocity: CGFloat(springs[1].velocity),
            isMoving: link != nil
        )
    }

    func animate(to target: Geometry, feel: Feel, reduced: Bool) {
        let feels = Self.feels(for: feel, reduced: reduced)
        let targets = [target.width, target.height, target.bottomRadius, target.shoulder]
        for index in springs.indices {
            springs[index].target = Double(targets[index])
            springs[index].feel = feels[index]
        }
        start()
    }

    func jump(to target: Geometry) {
        let targets = [target.width, target.height, target.bottomRadius, target.shoulder]
        for index in springs.indices {
            springs[index] = SpringValue(Double(targets[index]))
        }
        onFrame?(current)
    }

    /// Пружины с небольшим отскоком — «желе». Закрытие быстрее открытия.
    private static func feels(for feel: Feel, reduced: Bool) -> [SpringFeel] {
        if reduced {
            let calm = SpringFeel(response: 0.35, damping: 1)
            return [calm, calm, calm, calm]
        }
        switch feel {
        case .open:
            return [SpringFeel(response: 0.55, damping: 0.6), SpringFeel(response: 0.62, damping: 0.64),
                    SpringFeel(response: 0.5, damping: 0.75), SpringFeel(response: 0.45, damping: 0.8)]
        case .close:
            return [SpringFeel(response: 0.42, damping: 0.76), SpringFeel(response: 0.38, damping: 0.8),
                    SpringFeel(response: 0.4, damping: 0.9), SpringFeel(response: 0.4, damping: 0.9)]
        case .morph:
            return [SpringFeel(response: 0.5, damping: 0.62), SpringFeel(response: 0.55, damping: 0.66),
                    SpringFeel(response: 0.46, damping: 0.78), SpringFeel(response: 0.45, damping: 0.8)]
        case .hover:
            return [SpringFeel(response: 0.32, damping: 0.5), SpringFeel(response: 0.32, damping: 0.52),
                    SpringFeel(response: 0.3, damping: 0.7), SpringFeel(response: 0.3, damping: 0.7)]
        }
    }

    private func start() {
        guard link == nil else { return }
        guard let host else {
            for index in springs.indices { springs[index] = SpringValue(springs[index].target) }
            onFrame?(current)
            return
        }
        let proxy = DisplayLinkProxy { [weak self] link in
            MainActor.assumeIsolated { self?.tick(link) }
        }
        let link = host.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire(_:)))
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.link = link
        lastTimestamp = 0
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? 1.0 / 60.0 : min(1.0 / 30.0, max(1.0 / 240.0, now - lastTimestamp))
        lastTimestamp = now

        var moving = false
        for index in springs.indices {
            if springs[index].step(dt) { moving = true }
        }
        if !moving {
            link.invalidate()
            self.link = nil
            proxy = nil
            lastTimestamp = 0
        }
        onFrame?(current)
    }
}

/// CADisplayLink требует NSObject-цель.
final class DisplayLinkProxy: NSObject {
    private let handler: (CADisplayLink) -> Void

    init(_ handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
    }

    @objc func fire(_ link: CADisplayLink) {
        handler(link)
    }
}
