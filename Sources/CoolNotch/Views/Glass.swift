import AppKit
import CoreImage
import SwiftUI

/// Поверхность карточек и кнопок внутри чёлки: ровная полупрозрачная заливка
/// и еле заметная граница. Без градиентов, бликов и теней — спокойно, как у Apple.
struct GlassSurface: ViewModifier {
    var radius: CGFloat
    var highlighted = false
    var tint: Color = .white
    /// Подсветка при наведении в полтора раза слабее обычной.
    var soft = false

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape
                .fill(tint.opacity(highlighted ? (soft ? 0.103 : 0.12) : 0.07))
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                }
        }
    }
}

extension View {
    func glass(_ radius: CGFloat, highlighted: Bool = false, tint: Color = .white, soft: Bool = false) -> some View {
        modifier(GlassSurface(radius: radius, highlighted: highlighted, tint: tint, soft: soft))
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
