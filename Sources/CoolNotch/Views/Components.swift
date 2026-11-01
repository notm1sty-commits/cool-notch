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
/// Столбики-капсулы «дышат» от центра по неповторяющимся траекториям, как живой звук.
struct EqualizerView: NSViewRepresentable {
    var color: NSColor
    var isPlaying: Bool
    /// В режиме энергосбережения анимация остаётся, но с меньшей частотой кадров.
    var lowPower = false

    func makeNSView(context: Context) -> EqualizerNSView {
        EqualizerNSView(frame: .zero)
    }

    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.update(color: color, isPlaying: isPlaying, lowPower: lowPower)
    }
}

final class EqualizerNSView: NSView {
    private let barCount = 4
    private var bars: [CALayer] = []
    private var color: NSColor = .white
    private var isPlaying = false
    private var lowPower = false

    /// Траектории высоты каждого столбика (первая точка = последней, чтобы цикл был бесшовным).
    private static let paths: [[CGFloat]] = [
        [0.38, 0.92, 0.52, 1.0, 0.42, 0.78, 0.38],
        [0.66, 0.34, 1.0, 0.56, 0.88, 0.3, 0.66],
        [0.46, 1.0, 0.36, 0.82, 0.5, 0.96, 0.46],
        [0.82, 0.42, 0.72, 0.32, 1.0, 0.56, 0.82],
    ]
    private static let durations: [CFTimeInterval] = [1.55, 1.3, 1.7, 1.45]
    private static let restScale: CGFloat = 0.28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        bars = (0..<barCount).map { _ in
            let bar = CALayer()
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
        // Ширина столбиков подстраивается под место: 4 капсулы с зазором в 0,7 ширины.
        let width = max(2, min(3.2, bounds.width / (CGFloat(barCount) * 1.7)))
        let spacing = width * 0.7
        let total = CGFloat(barCount) * width + CGFloat(barCount - 1) * spacing
        var x = (bounds.width - total) / 2
        for bar in bars {
            bar.cornerRadius = width / 2
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: x + width / 2, y: bounds.midY)
            x += width + spacing
        }
        CATransaction.commit()
        applyAnimations(force: false)
    }

    func update(color: NSColor, isPlaying: Bool, lowPower: Bool) {
        if color != self.color {
            self.color = color
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            for bar in bars { bar.backgroundColor = color.cgColor }  // плавная смена цвета
            CATransaction.commit()
        }
        let changed = isPlaying != self.isPlaying || lowPower != self.lowPower
        self.isPlaying = isPlaying
        self.lowPower = lowPower
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
                let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
                animation.values = Self.paths[index % Self.paths.count]
                animation.calculationMode = .cubic
                animation.duration = Self.durations[index % Self.durations.count]
                animation.repeatCount = .infinity
                animation.timeOffset = Double(index) * 0.23
                animation.isRemovedOnCompletion = false
                animation.preferredFrameRateRange = lowPower
                    ? CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
                    : CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
                bar.add(animation, forKey: "eq")
            } else if running || force {
                // Плавно опускаем столбики из текущего положения, без рывка.
                let current = bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat ?? Self.restScale
                bar.removeAnimation(forKey: "eq")
                let settle = CABasicAnimation(keyPath: "transform.scale.y")
                settle.fromValue = current
                settle.toValue = Self.restScale
                settle.duration = 0.35
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.transform = CATransform3DMakeScale(1, Self.restScale, 1)
                bar.add(settle, forKey: "settle")
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
