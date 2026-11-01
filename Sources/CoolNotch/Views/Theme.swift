import SwiftUI

/// Единые «токены» дизайна: один ритм движения, одни поверхности и радиусы на всё приложение.
enum Theme {
    // MARK: Motion (по мотивам WWDC23 «Animate with springs»)
    static let content = Animation.smooth(duration: 0.34)
    static let micro = Animation.snappy(duration: 0.18)
    static let hover = Animation.spring(response: 0.3, dampingFraction: 0.62)
    static let bouncy = Animation.spring(response: 0.45, dampingFraction: 0.62)
    static let deck = Animation.spring(response: 0.55, dampingFraction: 0.78)
    static let reduced = Animation.easeInOut(duration: 0.2)

    // MARK: Colors
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.42)
    static let orange = Color(red: 1, green: 0.62, blue: 0.04)
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let liveGreen = Color(red: 0.31, green: 0.89, blue: 0.54)
    static let glassTint = Color(red: 0.055, green: 0.055, blue: 0.094)

    // MARK: Geometry (концентричные радиусы: внутренний = внешний − отступ)
    static let openRadius: CGFloat = 40
    static let padding: CGFloat = 18
    static let cardRadius: CGFloat = 22
    static let chipRadius: CGFloat = 12
}

/// Появление «из дымки»: прозрачность, размытие, масштаб, сдвиг и (по желанию) RGB-расслоение.
struct RevealTransition: Transition {
    var blur: CGFloat = 10
    var scale: CGFloat = 0.95
    var offset: CGSize = CGSize(width: 0, height: -8)
    var chromatic = false

    func body(content: Content, phase: TransitionPhase) -> some View {
        let identity = phase.isIdentity
        content
            .background {
                if chromatic {
                    ZStack {
                        content
                            .colorMultiply(Color(red: 1, green: 0.18, blue: 0.4))
                            .offset(x: identity ? 0 : -3.5)
                        content
                            .colorMultiply(Color(red: 0, green: 0.82, blue: 1))
                            .offset(x: identity ? 0 : 3.5)
                    }
                    .opacity(identity ? 0 : 0.85)
                    .allowsHitTesting(false)
                }
            }
            .opacity(identity ? 1 : 0)
            .blur(radius: identity ? 0 : blur)
            .scaleEffect(identity ? 1 : scale, anchor: .top)
            .offset(identity ? .zero : offset)
    }
}

/// Нажатие «проседает» кнопку — тактильный отклик без лишних эффектов.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

extension View {
    /// Мелкая подпись-заголовок раздела в стиле Apple.
    func sectionLabelStyle() -> some View {
        font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
    }
}
