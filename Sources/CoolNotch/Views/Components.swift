import AppKit
import QuartzCore
import SwiftUI

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(
                    colors: [Color(white: 0.22), Color(white: 0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .animation(Theme.content, value: image)
    }
}

// MARK: - Equalizer

/// Эквалайзер на Core Animation: анимацию крутит системный рендер-сервер,
/// приложение при этом не просыпается каждый кадр — это заметно экономит батарею.
struct EqualizerView: NSViewRepresentable {
    var color: NSColor
    var isPlaying: Bool
    var animated: Bool = true

    func makeNSView(context: Context) -> EqualizerNSView {
        EqualizerNSView(frame: .zero)
    }

    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.update(color: color, isPlaying: isPlaying && animated)
    }
}

final class EqualizerNSView: NSView {
    private let barCount = 4
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2.5
    private var bars: [CALayer] = []
    private var color: NSColor = .white
    private var isPlaying = false

    private static let durations: [CFTimeInterval] = [0.46, 0.58, 0.39, 0.52]
    private static let lows: [CGFloat] = [0.3, 0.22, 0.38, 0.26]
    private static let restScale: CGFloat = 0.24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        bars = (0..<barCount).map { _ in
            let bar = CALayer()
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = NSColor.white.cgColor
            bar.transform = CATransform3DMakeScale(1, Self.restScale, 1)
            return bar
        }
        attachBars()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Не перехватываем клики.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// macOS может пересоздать слой вью при переносе в окно — тогда столбики и их анимации
    /// нужно вернуть на место, иначе эквалайзер «замирает».
    private func attachBars() {
        guard let root = layer else { return }
        root.masksToBounds = false
        for bar in bars where bar.superlayer !== root {
            bar.removeFromSuperlayer()
            root.addSublayer(bar)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachBars()
        applyAnimations(force: true)
    }

    override func layout() {
        super.layout()
        attachBars()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let total = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        var x = (bounds.width - total) / 2
        for bar in bars {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: bounds.height)
            bar.position = CGPoint(x: x + barWidth / 2, y: bounds.midY)
            x += barWidth + spacing
        }
        CATransaction.commit()
        applyAnimations(force: false)
    }

    func update(color: NSColor, isPlaying: Bool) {
        if color != self.color {
            self.color = color
            for bar in bars { bar.backgroundColor = color.cgColor }  // плавная смена цвета (неявная анимация)
        }
        let changed = isPlaying != self.isPlaying
        self.isPlaying = isPlaying
        applyAnimations(force: changed)
    }

    /// Ставит или снимает анимацию. Без `force` только чинит пропавшие анимации.
    private func applyAnimations(force: Bool) {
        for (index, bar) in bars.enumerated() {
            let running = bar.animation(forKey: "eq") != nil
            if isPlaying {
                guard force || !running else { continue }
                bar.removeAnimation(forKey: "eq")
                bar.transform = CATransform3DIdentity
                let animation = CABasicAnimation(keyPath: "transform.scale.y")
                animation.fromValue = Self.lows[index % Self.lows.count]
                animation.toValue = 1.0
                animation.duration = Self.durations[index % Self.durations.count]
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timeOffset = Double(index) * 0.17
                animation.isRemovedOnCompletion = false
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                bar.add(animation, forKey: "eq")
            } else if running || force {
                bar.removeAnimation(forKey: "eq")
                bar.transform = CATransform3DMakeScale(1, Self.restScale, 1)
            }
        }
    }
}

// MARK: - Timer ring

struct TimerRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.linear(duration: 0.5), value: progress)
    }
}

// MARK: - Buttons

/// Кнопка-иконка: подсветка при наведении, «проседание» при нажатии.
struct IconButton: View {
    var systemName: String
    var size: CGFloat = 14
    var weight: Font.Weight = .semibold
    var help: String = ""
    var action: () -> Void

    @State var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.85))
                .frame(width: size * 2.2, height: size * 2.2)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
        .onHover { value in
            withAnimation(Theme.micro) { hovering = value }
        }
    }
}

/// Кнопка-«капсула» с текстом.
struct CapsuleButton: View {
    var title: String
    var systemImage: String?
    var prominent = false
    var action: () -> Void

    @State var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    prominent
                        ? Color.white.opacity(hovering ? 1 : 0.9)
                        : Color.white.opacity(hovering ? 0.16 : 0.09)
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
        .onHover { value in
            withAnimation(Theme.micro) { hovering = value }
        }
    }
}

struct PlaceholderView: View {
    var icon: String
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
