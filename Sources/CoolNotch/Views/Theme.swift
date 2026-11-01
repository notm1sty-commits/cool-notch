import SwiftUI

/// Единые «токены» дизайна: один ритм движения, одни поверхности и радиусы на всё приложение.
enum Theme {
    // MARK: Motion
    // Пружины по мотивам WWDC23 «Animate with springs»: небольшой отскок на появление,
    // закрытие быстрее открытия и без отскока.
    static let open = Animation.spring(duration: 0.5, bounce: 0.2)
    static let morph = Animation.spring(duration: 0.4, bounce: 0.14)
    static let hover = Animation.spring(duration: 0.3, bounce: 0.25)
    static let content = Animation.smooth(duration: 0.32)
    static let micro = Animation.snappy(duration: 0.18)
    static let reduced = Animation.easeInOut(duration: 0.2)

    // MARK: Colors
    static let surface = Color.white.opacity(0.06)
    static let surfaceHover = Color.white.opacity(0.11)
    static let hairline = Color.white.opacity(0.08)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.36)

    // MARK: Geometry
    // Скругления «концентричные»: внутренний радиус = внешний − отступ.
    static let openRadius: CGFloat = 34
    static let padding: CGFloat = 16
    static let cardRadius: CGFloat = 18
    static let chipRadius: CGFloat = 10
}

/// Появление «из дымки»: прозрачность + размытие + лёгкий масштаб и сдвиг.
struct RevealTransition: Transition {
    var blur: CGFloat = 10
    var scale: CGFloat = 0.95
    var offset: CGSize = CGSize(width: 0, height: -8)

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : blur)
            .scaleEffect(phase.isIdentity ? 1 : scale, anchor: .top)
            .offset(phase.isIdentity ? .zero : offset)
    }
}

/// Нажатие «проседает» кнопку — тактильный отклик без лишних эффектов.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Theme.micro, value: configuration.isPressed)
    }
}

extension View {
    /// Мягкая подложка-карточка.
    func surface(_ radius: CGFloat = Theme.cardRadius, highlighted: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(highlighted ? Theme.surfaceHover : Theme.surface)
        )
    }

    /// Мелкая подпись-заголовок раздела в стиле Apple.
    func sectionLabelStyle() -> some View {
        font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.tertiaryText)
    }
}
