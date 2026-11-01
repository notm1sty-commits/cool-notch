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
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Color(white: 0.28), Color(white: 0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// «Живой» эквалайзер: столбики двигаются, пока играет музыка.
struct EqualizerBars: View {
    var color: Color
    var isPlaying: Bool
    var barCount = 4

    private static let speeds: [Double] = [5.3, 7.1, 4.4, 6.2, 5.8]
    private static let phases: [Double] = [0.0, 1.7, 3.1, 4.6, 2.3]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule()
                            .fill(color.gradient)
                            .frame(width: 3, height: barHeight(index, time: time, maxHeight: geo.size.height))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: CGFloat(barCount) * 5)
    }

    private func barHeight(_ index: Int, time: Double, maxHeight: CGFloat) -> CGFloat {
        guard isPlaying else { return 3 }
        let i = index % Self.speeds.count
        let wave = sin(time * Self.speeds[i] + Self.phases[i]) * 0.5 + 0.5
        let envelope = 0.55 + 0.45 * sin(time * 1.3 + Self.phases[i] * 0.7)
        return max(3, CGFloat(wave * envelope) * maxHeight)
    }
}

struct TimerRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.linear(duration: 0.3), value: progress)
    }
}

/// Кнопка с иконкой, которая чуть увеличивается при наведении.
struct IconButton: View {
    var systemName: String
    var size: CGFloat = 14
    var help: String = ""
    var action: () -> Void

    @State var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: size * 2.1, height: size * 2.1)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Небольшая «плитка» с фоном для кнопок и блоков.
struct Tile<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(highlighted ? 0.14 : 0.06))
            )
    }
}

struct PlaceholderView: View {
    var icon: String
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
