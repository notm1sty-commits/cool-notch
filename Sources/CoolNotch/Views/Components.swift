import AppKit
import QuartzCore
import SwiftUI

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var corner: CGFloat
    /// Прежняя обложка, пока новая догружается (новый трек часто приходит без неё).
    @State private var held: NSImage?
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        let shown = image ?? held
        ZStack {
            if let shown {
                // У каждой картинки своя «личность» — новая обложка плавно проявляется поверх старой.
                Image(nsImage: shown)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(shown))
                    .transition(.opacity.combined(with: .scale(scale: 1.08)))
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
        .opacity(image == nil && held != nil ? 0.6 : 1)
        .animation(Theme.track, value: shown.map { ObjectIdentifier($0) })
        .animation(Theme.track, value: image == nil)
        .onAppear { held = image }
        .onChange(of: image.map { ObjectIdentifier($0) }) { _, _ in hold() }
    }

    private func hold() {
        holdTask?.cancel()
        if let image {
            held = image
            return
        }
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.track) { held = nil }
        }
    }
}

// MARK: - Equalizer

/// Эквалайзер: пять почти прямоугольных столбиков цвета обложки.
/// Пока играет музыка, они двигаются под настоящий звук Мака (басы → верха, см. AudioLevelMeter).
/// Без разрешения, на macOS старше 14.2 и в режиме энергосбережения — спокойная волна на Core Animation:
/// её крутит системный рендер-сервер, приложение при этом не просыпается каждый кадр.
struct EqualizerView: NSViewRepresentable {
    var color: NSColor
    var isPlaying: Bool
    /// В режиме энергосбережения — только волна и с меньшей частотой кадров.
    var lowPower = false

    func makeNSView(context: Context) -> EqualizerNSView {
        EqualizerNSView(frame: .zero)
    }

    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.update(color: color, isPlaying: isPlaying, lowPower: lowPower)
    }
}

final class EqualizerNSView: NSView {
    private static let barCount = AudioLevelMeter.bandCount
    private var bars: [CALayer] = []
    private var color: NSColor = .white
    private var hasColor = false
    private var isPlaying = false
    private var lowPower = false
    /// Подписан на настоящий звук.
    private var listening = false
    /// Сейчас столбики идут за настоящим звуком (а не за волной).
    private var live = false
    /// Когда запустили волну: все столбики считают фазу от одного момента, поэтому волна
    /// остаётся цельной, даже если анимацию одного столбика пришлось восстановить.
    private var waveStart: CFTimeInterval?

    /// Одна волна проходит по столбикам за ~1,9 с; нарастает и стихает она раз в четыре волны.
    private static let wavePeriod: CFTimeInterval = 1.9
    private static let swellWaves = 4
    private static var cycle: CFTimeInterval { wavePeriod * Double(swellWaves) }
    private static let restScale: CGFloat = 0.3
    /// Под звуком: тишина — низкий столбик, но не пропадает совсем.
    private static let liveFloor: CGFloat = 0.2

    /// Высота каждого столбика на весь цикл волны (первая точка = последней — цикл бесшовный).
    private static let paths: [[CGFloat]] = (0..<barCount).map { index in
        let samples = 96
        return (0...samples).map { step in
            let t = cycle * Double(step) / Double(samples)
            let swell = 0.65 + 0.35 * sin(2 * .pi * t / cycle)
            let wave = sin(2 * .pi * t / wavePeriod - Double(index) * 0.85)
            return CGFloat(0.55 + 0.33 * swell * wave)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        bars = (0..<Self.barCount).map { _ in
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
        updateListening()
        applyAnimations(force: true)
    }

    override func layout() {
        super.layout()
        attachBars()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Ширина столбиков подстраивается под место, зазор — 0,7 ширины.
        let count = CGFloat(Self.barCount)
        let width = max(2, min(3.2, bounds.width / (count * 1.7)))
        let spacing = width * 0.7
        let total = count * width + (count - 1) * spacing
        var x = (bounds.width - total) / 2
        for bar in bars {
            // Почти прямоугольные: лишь чуть скруглённые углы.
            bar.cornerRadius = min(0.8, width * 0.25)
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: x + width / 2, y: bounds.midY)
            x += width + spacing
        }
        CATransaction.commit()
        applyAnimations(force: false)
    }

    func update(color: NSColor, isPlaying: Bool, lowPower: Bool) {
        if !hasColor {
            // Эквалайзер создаётся заново при каждом открытии и закрытии чёлки — сразу в нужном цвете,
            // без «перетекания» из белого.
            hasColor = true
            self.color = color
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for bar in bars { bar.backgroundColor = color.cgColor }
            CATransaction.commit()
        } else if color != self.color {
            self.color = color
            // Плавное перетекание в цвет новой обложки.
            for bar in bars {
                let from = bar.presentation()?.backgroundColor ?? bar.backgroundColor
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = from
                fade.toValue = color.cgColor
                fade.duration = 0.8
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.backgroundColor = color.cgColor
                bar.add(fade, forKey: "color")
            }
        }
        let changed = isPlaying != self.isPlaying || lowPower != self.lowPower
        self.isPlaying = isPlaying
        self.lowPower = lowPower
        updateListening()
        applyAnimations(force: changed)
    }

    // MARK: Настоящий звук

    /// Слушаем звук, только пока играет музыка, вью в окне и нет режима энергосбережения.
    private func updateListening() {
        // Включён ли «настоящий звук» в настройках, решает AudioLevelMeter: если нет, он просто
        // сообщает «не вживую», и здесь идёт волна. Так переключатель срабатывает сразу.
        let wants = isPlaying && window != nil && !lowPower
        guard wants != listening else { return }
        listening = wants
        if wants {
            AudioLevelMeter.shared.subscribe(self) { [weak self] levels, isLive in
                self?.receive(levels, isLive: isLive)
            }
        } else {
            AudioLevelMeter.shared.unsubscribe(self)
            setLive(false)
        }
    }

    private func receive(_ levels: [Float], isLive: Bool) {
        guard listening, isPlaying else { return }
        setLive(isLive)
        guard isLive else { return }
        // Короткая линейная анимация между замерами (~30 в секунду) — движение плавное, без ступенек.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.07)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        for (index, bar) in bars.enumerated() {
            let level = CGFloat(index < levels.count ? levels[index] : 0)
            let scale = Self.liveFloor + (1 - Self.liveFloor) * level
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }

    /// Переход между настоящим звуком и волной.
    private func setLive(_ isLive: Bool) {
        guard isLive != live else { return }
        live = isLive
        if isLive {
            // Волну снимаем с того места, где она была, — дальше столбики ведёт звук.
            for bar in bars {
                let current = bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat ?? Self.restScale
                bar.removeAnimation(forKey: "eq")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                bar.transform = CATransform3DMakeScale(1, current, 1)
                CATransaction.commit()
            }
            waveStart = nil
        } else {
            applyAnimations(force: true)
        }
    }

    // MARK: Волна

    /// Ставит или снимает волну. Без `force` только чинит пропавшие анимации.
    private func applyAnimations(force: Bool) {
        guard !(live && isPlaying) else { return }
        if isPlaying {
            if force || waveStart == nil { waveStart = CACurrentMediaTime() }
        } else {
            waveStart = nil
        }
        for (index, bar) in bars.enumerated() {
            let running = bar.animation(forKey: "eq") != nil
            if isPlaying, let waveStart {
                guard force || !running else { continue }
                bar.removeAnimation(forKey: "eq")
                bar.transform = CATransform3DIdentity
                let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
                animation.values = Self.paths[index % Self.paths.count]
                animation.calculationMode = .cubic
                animation.duration = Self.cycle
                animation.repeatCount = .infinity
                // Общая точка отсчёта для всех столбиков — фазы не разъезжаются.
                animation.beginTime = bar.convertTime(waveStart, from: nil)
                animation.fillMode = .backwards
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

/// Пустое состояние: иконка в круглой подложке, заголовок и подпись. Одна раскладка на всё
/// приложение — заметки, буфер, полка и AirDrop выглядят одинаково.
enum PlaceholderLayout {
    /// Столбиком, а если не помещается по высоте — строкой.
    case automatic
    /// Значок слева, текст справа.
    case horizontal
    /// Значок сверху, текст под ним.
    case vertical
}

struct PlaceholderView<Glyph: View>: View {
    var title: String
    var subtitle: String?
    var fill: Color = .white.opacity(0.08)
    var layout: PlaceholderLayout = .automatic
    @ViewBuilder var glyph: () -> Glyph

    var body: some View {
        Group {
            switch layout {
            case .automatic:
                ViewThatFits(in: .vertical) {
                    column
                    row
                }
            case .horizontal:
                row
            case .vertical:
                column
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var column: some View {
        VStack(spacing: 10) {
            badge
            VStack(spacing: 3) {
                titleText
                subtitleText
            }
            .multilineTextAlignment(.center)
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                titleText
                subtitleText
            }
            .multilineTextAlignment(.leading)
        }
    }

    private var badge: some View {
        ZStack {
            Circle().fill(fill)
            glyph()
        }
        .frame(width: 40, height: 40)
    }

    private var titleText: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(1)
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension PlaceholderView where Glyph == PlaceholderSymbol {
    init(icon: String, title: String, subtitle: String? = nil, layout: PlaceholderLayout = .automatic) {
        self.init(title: title, subtitle: subtitle, layout: layout) { PlaceholderSymbol(name: icon) }
    }
}

struct PlaceholderSymbol: View {
    var name: String
    var color: Color = .white.opacity(0.62)

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(color)
    }
}

/// Значок AirDrop: концентрические дуги, открытые снизу, и точка в центре.
struct AirDropGlyph: View {
    var color: Color = .white

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let unit = min(size.width, size.height) / 2
            for radius in [0.42, 0.7, 0.98] {
                var arc = Path()
                arc.addRelativeArc(center: center, radius: unit * radius, startAngle: .degrees(125), delta: .degrees(290))
                context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: unit * 0.13, lineCap: .round))
            }
            let dot = unit * 0.15
            context.fill(Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)), with: .color(color))
        }
        .frame(width: 17, height: 17)
    }
}
