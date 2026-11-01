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
    /// Смена трека: быстро и чётко, без раскачки.
    static let track = Animation.spring(response: 0.3, dampingFraction: 0.88)

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
    /// Высота карточки плеера. Строки внутри неё фиксированной высоты, поэтому низ кнопки
    /// «Открыть» всегда на одной линии (playerHeight − 2) — по ней выровнен «Старт» таймера.
    static let playerHeight: CGFloat = 124
}

/// Спокойное появление: прозрачность и лёгкий масштаб от верхнего края, как у Dynamic Island.
/// Без размытия и цветных эффектов.
struct RevealTransition: Transition {
    var scale: CGFloat = 0.96
    var offset: CGSize = CGSize(width: 0, height: -6)

    func body(content: Content, phase: TransitionPhase) -> some View {
        let identity = phase.isIdentity
        content
            .opacity(identity ? 1 : 0)
            .scaleEffect(identity ? 1 : scale, anchor: .top)
            .offset(identity ? .zero : offset)
    }
}

/// Смена трека: старое уезжает в сторону листания, новое въезжает с другой стороны.
struct TrackSlide: Transition {
    /// +1 — следующий трек (новое появляется справа), −1 — предыдущий.
    var direction: CGFloat = 1
    var distance: CGFloat = 16

    func body(content: Content, phase: TransitionPhase) -> some View {
        // phase.value: −1 — появляется, 0 — на месте, 1 — исчезает.
        content
            .offset(x: -CGFloat(phase.value) * distance * direction)
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : 2.5)
    }
}

/// Пока плеер переключает трек, текущий слегка «уходит» — нажатие откликается сразу,
/// ещё до того, как плеер сообщит новый трек.
struct SwitchingLook: ViewModifier {
    var active: Bool
    var direction: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0.38 : 1)
            .offset(x: active ? -7 * direction : 0)
            .blur(radius: active ? 1.4 : 0)
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
