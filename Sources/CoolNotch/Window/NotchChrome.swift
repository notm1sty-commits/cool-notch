import AppKit
import QuartzCore

/// Состояние «оболочки» чёлки (то, что рисует Core Animation, а не SwiftUI).
struct ChromeState: Equatable {
    /// Раскрыта или показывает уведомление.
    var lifted = false
    var open = false
    /// Выбран стиль «Стекло».
    var glassStyle = false
    /// 0…1 — насколько тёмное стекло.
    var glassTint: CGFloat = 0.6
    var edgeEffects = true
    var jelly = true
    var notchSize = CGSize(width: 185, height: 32)
}

enum ChromeEvent {
    /// Мягкое свечение по контуру (уведомление / зарядка).
    case glow(green: Bool)
}

/// Слой-вью без хит-теста: только картинка.
final class PassthroughLayerView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Контейнер окна: перевёрнутые координаты (y вниз), как у SwiftUI.
final class NotchRootContainer: NSView {
    override var isFlipped: Bool { true }
}

/// Форма, тень, стекло и свечение чёлки на Core Animation.
/// Обновляется каждым кадром пружин без участия SwiftUI.
@MainActor
final class NotchChrome {
    let backView = PassthroughLayerView(frame: .zero)
    let glassHost = PassthroughLayerView(frame: .zero)
    let glassView: NSVisualEffectView
    let tintView = PassthroughLayerView(frame: .zero)
    let contentContainer = PassthroughContentView(frame: .zero)
    let frontView = PassthroughLayerView(frame: .zero)

    /// Масштаб отрисовки (2 — в демо-режиме для чёткой записи).
    var scale: CGFloat = 1

    private var state = ChromeState()

    private let shadowLayer = CALayer()
    private let glassMask = CAShapeLayer()
    private let tintLayer = CAShapeLayer()
    private let contentMask = CAShapeLayer()
    /// Чёрный «аппаратный» вырез поверх стекла.
    private let hardwareNotch = CAShapeLayer()
    /// Тонкая ровная граница — только у стекла, чтобы край читался на светлых обоях.
    private let hairline = CAShapeLayer()
    private let glowContainer = CALayer()
    private let glowGradient = CAGradientLayer()
    private let glowMask = CAShapeLayer()

    init() {
        let glass = NSVisualEffectView(frame: .zero)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.autoresizingMask = [.width, .height]
        glass.wantsLayer = true
        glassView = glass
        setUpLayers()
    }

    /// Собирает иерархию: тень → стекло → тонировка → SwiftUI → граница и свечение.
    func install(in root: NSView, content: NSView) {
        for view in [backView, glassHost, tintView, contentContainer, frontView] as [NSView] {
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
            view.wantsLayer = true
            // Все наши слои и маски — в координатах «y вниз», как у SwiftUI.
            view.layer?.isGeometryFlipped = true
        }
        glassView.frame = glassHost.bounds
        glassHost.addSubview(glassView)
        glassHost.layer?.mask = glassMask

        content.frame = contentContainer.bounds
        content.autoresizingMask = [.width, .height]
        contentContainer.addSubview(content)
        contentContainer.layer?.mask = contentMask
    }

    private func setUpLayers() {
        backView.layer?.addSublayer(shadowLayer)
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0
        shadowLayer.shadowRadius = 22
        shadowLayer.shadowOffset = CGSize(width: 0, height: 10)

        tintLayer.fillColor = NSColor.black.cgColor
        tintLayer.opacity = 1
        tintView.layer?.addSublayer(tintLayer)

        hardwareNotch.fillColor = NSColor.black.cgColor
        hardwareNotch.opacity = 0
        frontView.layer?.addSublayer(hardwareNotch)

        hairline.fillColor = nil
        hairline.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
        hairline.lineWidth = 1
        hairline.opacity = 0
        frontView.layer?.addSublayer(hairline)

        glowGradient.type = .conic
        glowGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowGradient.endPoint = CGPoint(x: 0.5, y: 0)
        glowContainer.addSublayer(glowGradient)
        glowMask.fillColor = nil
        glowMask.strokeColor = NSColor.white.cgColor
        glowMask.lineWidth = 1.5
        glowContainer.mask = glowMask
        glowContainer.opacity = 0
        frontView.layer?.addSublayer(glowContainer)
    }

    // MARK: - Per-frame

    func render(_ frame: NotchMotion.Frame) {
        let k = scale
        var g = frame.geometry

        // «Желе»: форма чуть-чуть сплющивается и вытягивается от скорости и пружинит обратно.
        if state.jelly {
            let vw = frame.widthVelocity, vh = frame.heightVelocity
            let sx = 1 + clamp(vw / 16000, 0.02) - clamp(vh / 20000, 0.012)
            let sy = 1 + clamp(vh / 11000, 0.035) - clamp(vw / 22000, 0.012)
            g.width *= sx
            g.height *= sy
        }

        let bounds = backView.bounds
        let totalWidth = (g.width + 2 * g.shoulder) * k
        let rect = CGRect(x: (bounds.width - totalWidth) / 2, y: 0, width: totalWidth, height: g.height * k)
        let closed = NotchShape.cgPath(in: rect, top: g.shoulder * k, bottom: g.bottomRadius * k, closed: true)
        let open = NotchShape.cgPath(in: rect, top: g.shoulder * k, bottom: g.bottomRadius * k, closed: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        shadowLayer.frame = bounds
        shadowLayer.shadowPath = closed
        tintLayer.path = closed
        glassMask.path = closed
        contentMask.path = closed
        hairline.path = open
        hairline.lineWidth = k

        let side = max(rect.width, rect.height) * 1.6
        glowContainer.frame = bounds
        glowGradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        glowGradient.position = CGPoint(x: rect.midX, y: rect.midY)
        glowMask.frame = bounds
        glowMask.path = open
        glowMask.lineWidth = 1.5 * k

        CATransaction.commit()
    }

    private func clamp(_ value: CGFloat, _ limit: CGFloat) -> CGFloat {
        max(-limit, min(limit, value))
    }

    // MARK: - State

    func apply(_ newState: ChromeState, animated: Bool) {
        state = newState
        let k = scale

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

        let glassActive = newState.glassStyle && newState.lifted
        glassHost.isHidden = !newState.glassStyle
        tintLayer.opacity = glassActive ? Float(newState.glassTint) : 1
        shadowLayer.shadowOpacity = newState.lifted ? 0.4 : 0
        hairline.opacity = glassActive ? 1 : 0
        hardwareNotch.opacity = glassActive ? 1 : 0

        let notchWidth = (newState.notchSize.width + 12) * k
        let notchRect = CGRect(x: (frontView.bounds.width - notchWidth) / 2, y: 0, width: notchWidth, height: newState.notchSize.height * k)
        hardwareNotch.path = NotchShape.cgPath(in: notchRect, top: 6 * k, bottom: 10 * k, closed: true)
        CATransaction.commit()
    }

    // MARK: - Events

    func fire(_ event: ChromeEvent) {
        guard state.edgeEffects else { return }
        switch event {
        case .glow(let green):
            // Тонкая линия по контуру плавно проявляется и гаснет, медленно переливаясь.
            let colors: [NSColor] = green
                ? [NSColor(red: 0.2, green: 0.84, blue: 0.4, alpha: 1), NSColor(red: 0.62, green: 0.96, blue: 0.62, alpha: 1),
                   NSColor(red: 0.2, green: 0.84, blue: 0.4, alpha: 1)]
                : [NSColor(white: 1, alpha: 0.9), NSColor(red: 0.72, green: 0.82, blue: 1, alpha: 1),
                   NSColor(white: 1, alpha: 0.9)]
            glowGradient.colors = colors.map(\.cgColor)

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.7, 0.7, 0]
            fade.keyTimes = [0, 0.25, 0.65, 1]
            fade.duration = 2
            fade.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeIn),
            ]
            glowContainer.add(fade, forKey: "fade")

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.pi * 0.6
            spin.duration = 2
            spin.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glowGradient.add(spin, forKey: "spin")
        }
    }
}

/// Контейнер для SwiftUI: клики проходят в SwiftUI, но сам он ничего не перехватывает.
final class PassthroughContentView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
