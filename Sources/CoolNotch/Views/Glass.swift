import AppKit
import CoreImage
import SwiftUI

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
