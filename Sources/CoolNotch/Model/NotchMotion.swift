import AppKit
import Observation
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
/// Ширина и высота тянутся с разной скоростью — форма «течёт», как Dynamic Island,
/// а скорость изменения используется для RGB-кромки.
@MainActor
@Observable
final class NotchMotion {
    struct Geometry: Equatable {
        var width: CGFloat
        var height: CGFloat
        var bottomRadius: CGFloat
        var shoulder: CGFloat
    }

    enum Feel {
        case open, close, morph, hover
    }

    private(set) var width: CGFloat = 185
    private(set) var height: CGFloat = 32
    private(set) var bottomRadius: CGFloat = 10
    private(set) var shoulder: CGFloat = 6
    /// 0…1 — насколько быстро сейчас меняется форма (для RGB-кромки).
    private(set) var aberration: CGFloat = 0

    @ObservationIgnored weak var host: NSView?
    @ObservationIgnored private var springs: [SpringValue] = [SpringValue(185), SpringValue(32), SpringValue(10), SpringValue(6)]
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var proxy: DisplayLinkProxy?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0

    var geometry: Geometry {
        Geometry(width: width, height: height, bottomRadius: bottomRadius, shoulder: shoulder)
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
        publish(aberration: 0)
    }

    private static func feels(for feel: Feel, reduced: Bool) -> [SpringFeel] {
        if reduced {
            let calm = SpringFeel(response: 0.35, damping: 1)
            return [calm, calm, calm, calm]
        }
        switch feel {
        case .open:
            return [SpringFeel(response: 0.52, damping: 0.7), SpringFeel(response: 0.58, damping: 0.74),
                    SpringFeel(response: 0.5, damping: 0.8), SpringFeel(response: 0.45, damping: 0.85)]
        case .close:
            return [SpringFeel(response: 0.42, damping: 0.88), SpringFeel(response: 0.38, damping: 0.92),
                    SpringFeel(response: 0.4, damping: 0.95), SpringFeel(response: 0.4, damping: 0.95)]
        case .morph:
            return [SpringFeel(response: 0.48, damping: 0.72), SpringFeel(response: 0.52, damping: 0.76),
                    SpringFeel(response: 0.46, damping: 0.8), SpringFeel(response: 0.45, damping: 0.85)]
        case .hover:
            return [SpringFeel(response: 0.3, damping: 0.58), SpringFeel(response: 0.3, damping: 0.6),
                    SpringFeel(response: 0.3, damping: 0.7), SpringFeel(response: 0.3, damping: 0.7)]
        }
    }

    private func start() {
        guard link == nil else { return }
        guard let host else {
            // Нет окна (например, при запуске) — просто встаём в цель.
            for index in springs.indices { springs[index] = SpringValue(springs[index].target) }
            publish(aberration: 0)
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
        let speed = abs(springs[0].velocity) * 0.9 + abs(springs[1].velocity)
        publish(aberration: moving ? CGFloat(min(1, speed / 1100)) : 0)

        if !moving {
            link.invalidate()
            self.link = nil
            proxy = nil
            lastTimestamp = 0
        }
    }

    private func publish(aberration newAberration: CGFloat) {
        let w = CGFloat(springs[0].value), h = CGFloat(springs[1].value)
        let r = CGFloat(max(0, springs[2].value)), s = CGFloat(max(0, springs[3].value))
        if w != width { width = w }
        if h != height { height = h }
        if r != bottomRadius { bottomRadius = r }
        if s != shoulder { shoulder = s }
        if abs(newAberration - aberration) > 0.004 || (newAberration == 0 && aberration != 0) {
            aberration = newAberration
        }
    }
}

/// CADisplayLink требует NSObject-цель — держим её отдельно от наблюдаемой модели.
final class DisplayLinkProxy: NSObject {
    private let handler: (CADisplayLink) -> Void

    init(_ handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
    }

    @objc func fire(_ link: CADisplayLink) {
        handler(link)
    }
}
