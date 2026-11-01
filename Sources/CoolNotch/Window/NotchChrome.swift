import AppKit
import QuartzCore

/// Состояние «оболочки» чёлки (то, что рисует Core Animation, а не SwiftUI).
struct ChromeState: Equatable {
    /// Раскрыта или показывает уведомление.
    var lifted = false
    var open = false
    /// Выбран стиль «Стекло».
    var glassStyle = true
    /// 0…1 — насколько тёмное стекло.
    var glassTint: CGFloat = 0.42
    var chromatic = true
    var edgeEffects = true
    var jelly = true
    var notchSize = CGSize(width: 185, height: 32)
}

enum ChromeEvent {
    /// Переливающееся свечение по контуру (уведомление / зарядка).
    case glow(green: Bool)
    /// Блик пробегает по кромке при раскрытии.
    case openSweep
    /// Быстрая вспышка кромки при сворачивании.
    case closeSweep
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

/// Форма, тень, стекло, кромка и эффекты чёлки на Core Animation.
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

    // back
    private let shadowLayer = CALayer()
    private let fringeRed = CAShapeLayer()
    private let fringeCyan = CAShapeLayer()
    private let fringeGreen = CAShapeLayer()
    // glass + tint
    private let glassMask = CAShapeLayer()
    private let tintLayer = CAShapeLayer()
    // content
    private let contentMask = CAShapeLayer()
    // front
    private let hardwareNotch = CAShapeLayer()
    private let rimGradient = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let shimmerContainer = CALayer()
    private let shimmerGradient = CAGradientLayer()
    private let shimmerMask = CAShapeLayer()
    private let glowContainer = CALayer()
    private let glowGradient = CAGradientLayer()
    private let glowMask = CAShapeLayer()
    private let glowWideContainer = CALayer()
    private let glowWideGradient = CAGradientLayer()
    private let glowWideMask = CAShapeLayer()

    private var lastRect: CGRect = .zero

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

    /// Собирает иерархию: тень и RGB-кромка → стекло → тонировка → SwiftUI → кромка и эффекты.
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
        frontView.layerUsesCoreImageFilters = true
    }

    private func setUpLayers() {
        backView.layer?.addSublayer(shadowLayer)
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0
        shadowLayer.shadowRadius = 26
        shadowLayer.shadowOffset = CGSize(width: 0, height: 12)

        for (layer, color) in [(fringeRed, NSColor(red: 1, green: 0.18, blue: 0.37, alpha: 1)),
                               (fringeCyan, NSColor(red: 0, green: 0.8, blue: 1, alpha: 1)),
                               (fringeGreen, NSColor(red: 0.55, green: 1, blue: 0.47, alpha: 1))] {
            layer.fillColor = color.cgColor
            layer.opacity = 0
            backView.layer?.addSublayer(layer)
        }

        tintLayer.fillColor = NSColor.black.cgColor
        tintLayer.opacity = 1
        tintView.layer?.addSublayer(tintLayer)

        hardwareNotch.fillColor = NSColor.black.cgColor
        hardwareNotch.opacity = 0
        frontView.layer?.addSublayer(hardwareNotch)

        // Статичная «световая» кромка стекла.
        rimGradient.colors = [
            NSColor.white.withAlphaComponent(0.5).cgColor,
            NSColor.white.withAlphaComponent(0.06).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            NSColor.white.withAlphaComponent(0.12).cgColor,
            NSColor.white.withAlphaComponent(0.45).cgColor,
        ]
        rimGradient.locations = [0, 0.28, 0.55, 0.78, 1]
        rimGradient.startPoint = CGPoint(x: 0, y: 0)
        rimGradient.endPoint = CGPoint(x: 1, y: 1)
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.lineWidth = 1.5
        rimGradient.mask = rimMask
        rimGradient.opacity = 0
        frontView.layer?.addSublayer(rimGradient)

        // Переливающийся блик, медленно бегущий по кромке, пока чёлка открыта.
        shimmerGradient.type = .conic
        shimmerGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        shimmerGradient.endPoint = CGPoint(x: 0.5, y: 0)
        shimmerGradient.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.9).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.55).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        shimmerGradient.locations = [0, 0.08, 0.18, 0.5, 0.6, 0.72]
        shimmerContainer.addSublayer(shimmerGradient)
        shimmerMask.fillColor = nil
        shimmerMask.strokeColor = NSColor.white.cgColor
        shimmerMask.lineWidth = 1.6
        shimmerContainer.mask = shimmerMask
        shimmerContainer.opacity = 0
        frontView.layer?.addSublayer(shimmerContainer)

        // Свечение контура: чёткая линия + размытый ореол.
        for (container, gradient, mask, width) in [(glowWideContainer, glowWideGradient, glowWideMask, CGFloat(9)),
                                                   (glowContainer, glowGradient, glowMask, CGFloat(2.4))] {
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            container.addSublayer(gradient)
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = width
            container.mask = mask
            container.opacity = 0
            frontView.layer?.addSublayer(container)
        }
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": 6]) {
            glowWideContainer.filters = [blur]
        }
    }

    // MARK: - Per-frame

    func render(_ frame: NotchMotion.Frame) {
        let k = scale
        var g = frame.geometry

        // «Желе»: форма чуть сплющивается и вытягивается от скорости и пружинит обратно.
        if state.jelly {
            let vw = frame.widthVelocity, vh = frame.heightVelocity
            let sx = 1 + clamp(vw / 7000, 0.045) - clamp(vh / 9000, 0.03)
            let sy = 1 + clamp(vh / 5000, 0.07) - clamp(vw / 10000, 0.03)
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

        // RGB-кромка: цветные копии расходятся тем сильнее, чем быстрее меняется форма.
        let speed = abs(frame.widthVelocity) * 0.9 + abs(frame.heightVelocity)
        let aberration = state.chromatic && frame.isMoving ? Float(min(1, speed / 1100)) : 0
        for layer in [fringeRed, fringeCyan, fringeGreen] { layer.path = closed }
        fringeRed.setAffineTransform(CGAffineTransform(translationX: CGFloat(-aberration) * 4 * k, y: 0))
        fringeCyan.setAffineTransform(CGAffineTransform(translationX: CGFloat(aberration) * 4 * k, y: 0))
        fringeGreen.setAffineTransform(CGAffineTransform(translationX: 0, y: CGFloat(aberration) * 3 * k))
        fringeRed.opacity = aberration * 0.85
        fringeCyan.opacity = aberration * 0.85
        fringeGreen.opacity = aberration * 0.5

        rimGradient.frame = rect
        rimMask.frame = CGRect(origin: .zero, size: rect.size)
        rimMask.path = NotchShape.cgPath(
            in: CGRect(origin: .zero, size: rect.size), top: g.shoulder * k, bottom: g.bottomRadius * k, closed: false
        )
        rimMask.lineWidth = 1.5 * k

        let side = max(rect.width, rect.height) * 1.6
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        for (container, gradient, mask, width) in [(shimmerContainer, shimmerGradient, shimmerMask, CGFloat(1.6)),
                                                   (glowContainer, glowGradient, glowMask, CGFloat(2.4)),
                                                   (glowWideContainer, glowWideGradient, glowWideMask, CGFloat(9))] {
            container.frame = bounds
            gradient.bounds = CGRect(origin: .zero, size: square.size)
            gradient.position = CGPoint(x: square.midX, y: square.midY)
            mask.frame = bounds
            mask.path = open
            mask.lineWidth = width * k
        }

        CATransaction.commit()
        lastRect = rect
    }

    private func clamp(_ value: CGFloat, _ limit: CGFloat) -> CGFloat {
        max(-limit, min(limit, value))
    }

    // MARK: - State

    func apply(_ newState: ChromeState, animated: Bool) {
        let previous = state
        state = newState
        let k = scale

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.35 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

        let glassActive = newState.glassStyle && newState.lifted
        glassHost.isHidden = !newState.glassStyle
        tintLayer.opacity = glassActive ? Float(newState.glassTint) : 1
        shadowLayer.shadowOpacity = newState.lifted ? 0.45 : 0
        rimGradient.opacity = newState.lifted ? (glassActive ? 1 : 0.4) : 0
        hardwareNotch.opacity = glassActive ? 1 : 0

        let notchWidth = (newState.notchSize.width + 12) * k
        let notchRect = CGRect(x: (frontView.bounds.width - notchWidth) / 2, y: 0, width: notchWidth, height: newState.notchSize.height * k)
        hardwareNotch.path = NotchShape.cgPath(in: notchRect, top: 6 * k, bottom: 10 * k, closed: true)

        let shimmerOn = newState.open && newState.edgeEffects
        shimmerContainer.opacity = shimmerOn ? 0.55 : 0
        CATransaction.commit()

        if shimmerOn, shimmerGradient.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.pi * 2
            spin.duration = 7
            spin.repeatCount = .infinity
            spin.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 60)
            shimmerGradient.add(spin, forKey: "spin")
        } else if !shimmerOn, previous.open != newState.open || previous.edgeEffects != newState.edgeEffects {
            shimmerGradient.removeAnimation(forKey: "spin")
        }
    }

    // MARK: - Events

    func fire(_ event: ChromeEvent) {
        guard state.edgeEffects else { return }
        switch event {
        case .glow(let green):
            let colors: [NSColor] = green
                ? [NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1), NSColor(red: 0.65, green: 1, blue: 0.56, alpha: 1),
                   NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1), NSColor(red: 0.06, green: 0.75, blue: 0.42, alpha: 1),
                   NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)]
                : [NSColor(red: 1, green: 0.42, blue: 0.53, alpha: 1), NSColor(red: 1, green: 0.72, blue: 0.42, alpha: 1),
                   NSColor(red: 0.42, green: 0.82, blue: 1, alpha: 1), NSColor(red: 0.7, green: 0.47, blue: 1, alpha: 1),
                   NSColor(red: 1, green: 0.42, blue: 0.53, alpha: 1)]
            runSweep(colors: colors, duration: 2.2, peak: 1, turns: 1)
        case .openSweep:
            let white = NSColor.white
            runSweep(colors: [white.withAlphaComponent(0), white, white.withAlphaComponent(0), white.withAlphaComponent(0), white.withAlphaComponent(0)],
                     duration: 1.0, peak: 0.85, turns: 0.6)
        case .closeSweep:
            let white = NSColor.white
            runSweep(colors: [white.withAlphaComponent(0), white.withAlphaComponent(0.8), white.withAlphaComponent(0), white.withAlphaComponent(0), white.withAlphaComponent(0)],
                     duration: 0.55, peak: 0.5, turns: -0.35)
        }
    }

    private func runSweep(colors: [NSColor], duration: CFTimeInterval, peak: Float, turns: Double) {
        let cgColors = colors.map(\.cgColor)
        for (container, gradient, strength) in [(glowContainer, glowGradient, Float(1)), (glowWideContainer, glowWideGradient, Float(0.75))] {
            gradient.colors = cgColors
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, peak * strength, peak * strength * 0.9, 0]
            fade.keyTimes = [0, 0.18, 0.7, 1]
            fade.duration = duration
            container.add(fade, forKey: "fade")

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.pi * 2 * turns
            spin.duration = duration
            spin.timingFunction = CAMediaTimingFunction(name: .easeOut)
            gradient.add(spin, forKey: "spin")
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
