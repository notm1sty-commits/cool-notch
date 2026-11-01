import AppKit
import CoreImage
import SwiftUI

/// Системное размытие macOS: то, что реально лежит за чёлкой (обои, окна, строка меню).
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
    }
}

/// Стеклянная поверхность для карточек и кнопок внутри чёлки:
/// полупрозрачная заливка, «световая» кромка и мягкая тень.
struct GlassSurface: ViewModifier {
    var radius: CGFloat
    var highlighted = false
    var tint: Color = .white

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(highlighted ? 0.2 : 0.13), tint.opacity(highlighted ? 0.1 : 0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    shape.strokeBorder(Self.rim, lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.22), radius: 11, y: 6)
        }
    }

    static let rim = LinearGradient(
        stops: [
            .init(color: .white.opacity(0.6), location: 0),
            .init(color: .white.opacity(0.09), location: 0.35),
            .init(color: .white.opacity(0.04), location: 0.62),
            .init(color: .white.opacity(0.34), location: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension View {
    func glass(_ radius: CGFloat, highlighted: Bool = false, tint: Color = .white) -> some View {
        modifier(GlassSurface(radius: radius, highlighted: highlighted, tint: tint))
    }
}

/// «Световая» кромка большой стеклянной панели (как у Liquid Glass).
struct RimLight: View {
    var shape: NotchShape

    var body: some View {
        shape
            .stroke(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.55), location: 0),
                        .init(color: .white.opacity(0.06), location: 0.28),
                        .init(color: .white.opacity(0.02), location: 0.55),
                        .init(color: .white.opacity(0.12), location: 0.78),
                        .init(color: .white.opacity(0.5), location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 2
            )
            .allowsHitTesting(false)
    }
}

/// Свечение по контуру в духе Apple Intelligence: переливающаяся кромка пробегает по кругу.
struct EdgeGlow: View {
    var shape: NotchShape
    var trigger: Int
    var green: Bool

    @State var startDate: Date?

    private static let duration = 2.2

    var body: some View {
        ZStack {
            if let startDate {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(startDate) / Self.duration
                    let envelope = t < 0.18 ? t / 0.18 : max(0, 1 - (t - 0.18) / 0.82)
                    let gradient = AngularGradient(colors: colors, center: .center, angle: .degrees(t * 360))
                    ZStack {
                        shape.stroke(gradient, lineWidth: 7).blur(radius: 10).opacity(envelope * 0.8)
                        shape.stroke(gradient, lineWidth: 2.2).opacity(envelope)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            let start = Date()
            startDate = start
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.duration + 0.1))
                if startDate == start { startDate = nil }
            }
        }
    }

    private var colors: [Color] {
        if green {
            return [Theme.green, Color(red: 0.65, green: 1, blue: 0.56), Theme.green, Color(red: 0.06, green: 0.75, blue: 0.42), Theme.green]
        }
        return [
            Color(red: 1, green: 0.42, blue: 0.53),
            Color(red: 1, green: 0.72, blue: 0.42),
            Color(red: 0.42, green: 0.82, blue: 1),
            Color(red: 0.7, green: 0.47, blue: 1),
            Color(red: 1, green: 0.42, blue: 0.53),
        ]
    }
}

/// RGB-кромка («3D-кино»): цветные копии формы расходятся тем сильнее, чем быстрее она меняется.
struct ChromaticFringe: View {
    var shape: NotchShape
    var amount: CGFloat

    var body: some View {
        ZStack {
            shape.fill(Color(red: 1, green: 0.18, blue: 0.37).opacity(Double(amount) * 0.85))
                .offset(x: -amount * 4)
            shape.fill(Color(red: 0, green: 0.8, blue: 1).opacity(Double(amount) * 0.85))
                .offset(x: amount * 4)
            shape.fill(Color(red: 0.55, green: 1, blue: 0.47).opacity(Double(amount) * 0.5))
                .offset(y: amount * 3)
        }
        .allowsHitTesting(false)
    }
}

/// Готовим размытую копию обложки один раз — потом она рисуется почти бесплатно.
enum ArtworkProcessing {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func backdrop(from image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var input = CIImage(cgImage: cgImage)
        let scale = 140 / max(input.extent.width, input.extent.height, 1)
        input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = input.extent
        let output = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 10)
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.7, kCIInputBrightnessKey: -0.02])
        guard let result = context.createCGImage(output, from: extent) else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
    }
}
