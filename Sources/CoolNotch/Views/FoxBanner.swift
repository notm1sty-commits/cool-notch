import AppKit
import SwiftUI

/// Пиксельная сцена вверху «Основных» в настройках: лиса бежит через поле, а небо — по часам Мака
/// (рассвет 5–8, день 8–18, закат 18–21, ночь 21–5; солнце и луна идут по небу вместе со временем).
/// Кадр собирается в маленькую картинку 186×34 и растягивается без сглаживания. 12 кадров в секунду
/// и только пока раздел виден на экране — батарею это не тратит.
struct FoxBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = false
    @State private var windowVisible = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Double(FoxScene.fps), paused: reduceMotion || !onScreen || !windowVisible)) { context in
            if let image = FoxScene.render(date: context.date) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
            }
        }
        .aspectRatio(CGFloat(FoxScene.width) / CGFloat(FoxScene.height), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .background(WindowVisibilityReader(visible: $windowVisible))
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .accessibilityElement()
        .accessibilityLabel("Пиксельная лиса бежит через поле. Made by reboot.raw")
    }
}

/// Сообщает, видно ли окно (закрыто, свёрнуто или перекрыто — анимация стоит).
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        let binding = $visible
        view.onChange = { isVisible in
            DispatchQueue.main.async {
                if binding.wrappedValue != isVisible { binding.wrappedValue = isVisible }
            }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else {
                onChange?(false)
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] note in
                let visible = (note.object as? NSWindow)?.occlusionState.contains(.visible) ?? false
                MainActor.assumeIsolated { self?.onChange?(visible) }
            }
            onChange?(window.occlusionState.contains(.visible))
        }
    }
}

// MARK: - Сцена

enum FoxScene {
    static let width = 186
    static let height = 34
    static let ground = 26
    static let fps = 12

    enum Sky {
        case dawn, day, sunset, night

        /// Какое небо сейчас и насколько прошло это время суток (0…1) — по нему движутся солнце и луна.
        static func at(_ date: Date) -> (sky: Sky, progress: Double) {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minutes = Double((parts.hour ?? 12) * 60 + (parts.minute ?? 0))
            func span(_ from: Double, _ to: Double) -> Double { (minutes - from * 60) / ((to - from) * 60) }
            switch minutes {
            case 300..<480: return (.dawn, span(5, 8))
            case 480..<1080: return (.day, span(8, 18))
            case 1080..<1260: return (.sunset, span(18, 21))
            default:
                // Ночь переходит через полночь: 21:00 → 5:00.
                let sinceNine = minutes >= 1260 ? minutes - 1260 : minutes + 180
                return (.night, sinceNine / 480)
            }
        }
    }

    struct Palette {
        var sky: [UInt32]
        var sun: UInt32 = 0, sunRim: UInt32 = 0
        var moon: UInt32 = 0
        var farHill: UInt32, nearHill: UInt32
        var mist: UInt32?
        var grass: [UInt32]
        var tuft: UInt32
        var flowers: [UInt32]
        var cloud: UInt32?, cloudShade: UInt32 = 0
        var star: UInt32?
        var text: UInt32, textShadow: UInt32
        /// Ночью лиса чуть темнее.
        var foxShade: Double = 1
    }

    static func palette(_ sky: Sky) -> Palette {
        switch sky {
        case .dawn:
            return Palette(
                sky: [0x2D3566, 0x5A5A8F, 0xA07AA6, 0xE39FB0, 0xFFD0A6],
                sun: 0xFFF0B8, sunRim: 0xFFD27E,
                farHill: 0x6A5C8F, nearHill: 0x4D4A78, mist: 0xD9C3E3,
                grass: [0x5C9A4C, 0x4A8540, 0x3B6E35, 0x2F5A2C], tuft: 0x79B45E, flowers: [0xFFC6D9, 0xFFF2A8],
                cloud: 0xF7C3C9, cloudShade: 0xE7A3B3, star: 0xE9E4FF,
                text: 0xFFF5EE, textShadow: 0x4A3A6A
            )
        case .day:
            return Palette(
                sky: [0x4F9EF0, 0x62ACF4, 0x78BBF7, 0x90CAF9, 0xA9D8FB],
                sun: 0xFFF3A6, sunRim: 0xFFE066,
                farHill: 0x7DBB6A, nearHill: 0x63A854,
                grass: [0x67BF47, 0x55A83C, 0x468F33, 0x3A7A2B], tuft: 0x7FD25A, flowers: [0xFF6B6B, 0xFFE14D, 0xFFFFFF],
                cloud: 0xFFFFFF, cloudShade: 0xDBEAFB,
                text: 0xFFFFFF, textShadow: 0x2F6B2A
            )
        case .sunset:
            return Palette(
                sky: [0x2B2D5C, 0x463D78, 0x7A4B86, 0xBB5F80, 0xEC8F72],
                sun: 0xFFD27A, sunRim: 0xFFB35C,
                farHill: 0x5A3C6E, nearHill: 0x3C2E55,
                grass: [0x5B8A3C, 0x467232, 0x365B29, 0x2B4A22], tuft: 0x6F9E45, flowers: [0xFFB3C7, 0xFFE17A],
                cloud: 0xF2A99A, cloudShade: 0xD98585,
                text: 0xFFF1E2, textShadow: 0x3B2346
            )
        case .night:
            return Palette(
                sky: [0x0B1026, 0x111839, 0x18214A, 0x1F2A5A, 0x27346A],
                moon: 0xF1ECC8,
                farHill: 0x1B2448, nearHill: 0x141B36,
                grass: [0x2F5A3A, 0x244A31, 0x1B3A27, 0x142D1F], tuft: 0x3B6B46, flowers: [0xA8B4FF, 0xE7E1FF],
                star: 0xF4F1D6,
                text: 0xCFD6FF, textShadow: 0x070A1A,
                foxShade: 0.78
            )
        }
    }

    static func render(date: Date) -> CGImage? {
        let tick = Int(date.timeIntervalSinceReferenceDate * Double(fps))
        let (sky, progress) = Sky.at(date)
        var canvas = PixelCanvas(width: width, height: height)
        draw(sky: sky, progress: min(max(progress, 0), 1), tick: tick, on: &canvas)
        return canvas.makeImage()
    }

    // MARK: Рисование

    private static func draw(sky: Sky, progress: Double, tick t: Int, on c: inout PixelCanvas) {
        let p = palette(sky)
        let w = width, g = ground

        // Небо полосами, между полосами — шахматный переход.
        let band = Int((Double(g) / Double(p.sky.count)).rounded(.up))
        for (i, color) in p.sky.enumerated() {
            c.rect(0, i * band, w, band, color)
            if i > 0 { for x in stride(from: i % 2, to: w, by: 2) { c.set(x, i * band, p.sky[i - 1]) } }
        }

        // Звёзды: ночью мерцают, на рассвете гаснут наверху.
        if let star = p.star {
            for i in 0..<40 {
                let x = noise(i, 11) % w, y = noise(i, 12) % 18, phase = noise(i, 13) % 40
                if x < 80 && y < 11 { continue }   // не под подписью
                switch sky {
                case .night where (t + phase) % 40 < 34:
                    c.set(x, y, (t + phase) % 40 < 6 ? 0xFFFFFF : star)
                case .dawn where y < 6 && (t + phase) % 60 < 30:
                    c.set(x, y, star)
                default: break
                }
            }
        }

        // Солнце или луна — по времени суток.
        switch sky {
        case .dawn:
            disc(&c, x: 30 + Int(20 * progress), y: 27 - Int(12 * progress), r: 6, fill: p.sun, rim: p.sunRim)
        case .day:
            let arc = 2 * progress - 1
            disc(&c, x: 20 + Int(150 * progress), y: 6 + Int(6 * arc * arc), r: 4, fill: p.sun, rim: p.sunRim)
        case .sunset:
            disc(&c, x: 104 + Int(30 * progress), y: 14 + Int(13 * progress), r: 7, fill: p.sun, rim: p.sunRim)
        case .night:
            let arc = 2 * progress - 1
            crescent(&c, x: 20 + Int(150 * progress), y: 6 + Int(5 * arc * arc), r: 4, color: p.moon)
        }

        if let cloudColor = p.cloud {
            let clouds = [(60, 4, 18), (110, 8, 13), (160, 3, 22)]
            for (i, cloud) in clouds.enumerated() {
                let speed = 0.05 + Double(i) * 0.02
                let span = Double(w + 30)
                let x = (Double(cloud.0) - Double(t) * speed).truncatingRemainder(dividingBy: span)
                let wrapped = Int(((x + span).truncatingRemainder(dividingBy: span)) - 30)
                let y = cloud.1 + (sky == .dawn ? 2 : sky == .day ? 1 : 0)
                drawCloud(&c, x: wrapped, y: y, w: cloud.2, color: cloudColor, shade: p.cloudShade)
            }
        }

        hill(&c, base: 21, amp: 3, f1: 0.05, f2: 0.11, shift: t / 30, color: p.farHill)
        if let mist = p.mist {
            for x in 0..<w where (x + t / 6) % 3 != 0 { c.set(x, 21, mist) }
            for x in stride(from: 0, to: w, by: 2) { c.set(x + (t / 6) % 2, 22, mist) }
        }
        hill(&c, base: 24, amp: 2, f1: 0.08, f2: 0.17, shift: t / 14 + 50, color: p.nearHill)

        // Поле: полосы травы, травинки, цветы.
        for y in g..<height {
            let row = min(p.grass.count - 1, (y - g) / 2)
            c.rect(0, y, w, 1, p.grass[row])
            if row > 0, (y - g) % 2 == 0 {
                for x in stride(from: y % 2, to: w, by: 2) { c.set(x, y, p.grass[row - 1]) }
            }
        }
        for x in 0..<w {
            let tuft = noise(x, 21) % 100 < 45 ? 1 + noise(x, 22) % 2 : 0
            if tuft > 0 { c.rect(x, g - tuft, 1, tuft, p.tuft) }
        }
        for i in 0..<14 {
            c.set(noise(i, 31) % w, g + 1 + noise(i, 32) % 6, p.flowers[noise(i, 33) % p.flowers.count])
        }

        // Лиса бежит слева направо и выбегает снова.
        let foxX = (t * 2) % (w + 70) - 45
        drawFox(&c, x: foxX, y: g - 16, frame: t % FoxSprite.frames.count, shade: p.foxShade)

        // Ночью — светлячки, днём — бабочки.
        if sky == .night {
            for i in 0..<6 {
                let phase = Double(noise(i, 41) % 628) / 100
                let x = (noise(i, 42) % w + t * (3 + noise(i, 43) % 4) / 20) % w
                let y = 15 + noise(i, 44) % 9 + Int((sin(Double(t) * 0.15 + phase) * 2).rounded())
                if sin(Double(t) * 0.25 + phase) > -0.3 { c.set(x, y, 0xD9FF7A) }
            }
        }
        if sky == .day {
            for i in 0..<2 {
                let phase = Double(i) * 2.1
                let x = (40 + i * 80 + t * 2 / 5) % w
                let y = 14 + i * 3 + Int((sin(Double(t) * 0.3 + phase) * 2).rounded())
                let wing: UInt32 = i == 0 ? 0xFFFFFF : 0xFFD84D
                c.set(x, y, 0x3A3A3A)
                if (t / 2 + i) % 2 == 0 {
                    c.set(x - 1, y - 1, wing); c.set(x + 1, y - 1, wing)
                } else {
                    c.set(x - 1, y, wing); c.set(x + 1, y, wing)
                }
            }
        }

        drawLabel(&c, x: 4, y: 2, color: p.text, shadow: p.textShadow)
    }

    private static func disc(_ c: inout PixelCanvas, x cx: Int, y cy: Int, r: Int, fill: UInt32, rim: UInt32) {
        let inner = (Double(r) - 1.2) * (Double(r) - 1.2)
        for y in -r...r {
            for x in -r...r where x * x + y * y <= r * r {
                c.set(cx + x, cy + y, Double(x * x + y * y) > inner ? rim : fill)
            }
        }
    }

    private static func crescent(_ c: inout PixelCanvas, x cx: Int, y cy: Int, r: Int, color: UInt32) {
        for y in -r...r {
            for x in -r...r where x * x + y * y <= r * r {
                if Double((x - 2) * (x - 2) + (y + 1) * (y + 1)) > Double(r * r) * 0.7 { c.set(cx + x, cy + y, color) }
            }
        }
    }

    private static func drawCloud(_ c: inout PixelCanvas, x: Int, y: Int, w: Int, color: UInt32, shade: UInt32) {
        c.rect(x + 2, y, w - 4, 1, color)
        c.rect(x, y + 1, w, 2, color)
        c.rect(x + 1, y + 3, w - 2, 1, shade)
        c.rect(x + w / 3, y - 1, w / 3, 1, color)
    }

    private static func hill(_ c: inout PixelCanvas, base: Double, amp: Double, f1: Double, f2: Double, shift: Int, color: UInt32) {
        for x in 0..<width {
            let xx = Double(x + shift)
            let top = Int((base - amp * (0.6 * sin(xx * f1) + 0.4 * sin(xx * f2 + 1.3))).rounded())
            c.rect(x, top, 1, ground - top, color)
        }
    }

    private static func drawFox(_ c: inout PixelCanvas, x: Int, y: Int, frame: Int, shade: Double) {
        for (row, line) in FoxSprite.frames[frame].enumerated() {
            for (col, char) in line.enumerated() {
                guard let color = FoxSprite.colors[char] else { continue }
                c.set(x + col, y + row, shade < 1 ? darken(color, shade) : color)
            }
        }
    }

    private static func drawLabel(_ c: inout PixelCanvas, x: Int, y: Int, color: UInt32, shadow: UInt32) {
        var cursor = x
        for char in "made by reboot.raw" {
            guard let glyph = Glyphs.table[char] else { continue }
            for pass in 0..<2 {
                for (gy, line) in glyph.enumerated() {
                    for (gx, bit) in line.enumerated() where bit == "#" {
                        if pass == 0 {
                            c.set(cursor + gx + 1, y + gy + 1, shadow)
                        } else {
                            c.set(cursor + gx, y + gy, color)
                        }
                    }
                }
            }
            cursor += (glyph.first?.count ?? 0) + 1
        }
    }

    private static func darken(_ color: UInt32, _ k: Double) -> UInt32 {
        let r = UInt32(Double((color >> 16) & 0xFF) * k)
        let g = UInt32(Double((color >> 8) & 0xFF) * k)
        let b = UInt32(Double(color & 0xFF) * k)
        return (r << 16) | (g << 8) | b
    }

    /// Неизменный «случайный» номер для травинок, цветов и звёзд — без хранения состояния.
    private static func noise(_ i: Int, _ seed: Int) -> Int {
        var h = UInt64(bitPattern: Int64(i &* 374_761_393 &+ seed &* 668_265_263))
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Int(h % 1_000_003)
    }
}

/// Маленький холст: пиксели 0xRRGGBB → CGImage без сглаживания.
struct PixelCanvas {
    let width: Int
    let height: Int
    private var pixels: [UInt32]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = Array(repeating: 0xFF00_0000, count: width * height)
    }

    mutating func set(_ x: Int, _ y: Int, _ color: UInt32) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = 0xFF00_0000 | color
    }

    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        let x0 = max(0, x), y0 = max(0, y), x1 = min(width, x + w), y1 = min(height, y + h)
        guard x0 < x1, y0 < y1 else { return }
        let value = 0xFF00_0000 | color
        for row in y0..<y1 {
            let base = row * width
            for col in x0..<x1 { pixels[base + col] = value }
        }
    }

    func makeImage() -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // 0xAARRGGBB в порядке байт машины — стандартный BGRA.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Лиса: «Fox (animated)» от hdst, CC0 (opengameart.org/content/fox-animated). 8 кадров бега, 19×16.
enum FoxSprite {
    static let colors: [Character: UInt32] = [
        "o": 0xFFA000, "d": 0xEF6C00, "l": 0xFFCC80, "c": 0xFFE0B2, "k": 0x424242,
    ]

    static let frames: [[String]] = [
        [
            "...................",
            "...................",
            "...................",
            "..........lll...lll",
            "............ol.lodd",
            "............dooooo.",
            ".............ooooo.",
            ".............ookok.",
            "..cco........ookok.",
            "..cool.....llccccck",
            "..ooool..lloooccccc",
            "...doooolooooccc...",
            "....doodooooooco...",
            "........oddddodo...",
            "........o.o..o.o...",
            "........k.k..k.k...",
        ],
        [
            "...................",
            "...................",
            "...........ll...ll.",
            "..........ldol.lodl",
            "............doooood",
            ".............ooooo.",
            ".............ookok.",
            ".............ookok.",
            "...........llccccck",
            "..llo.....loooccccc",
            ".cooolo..loooccc...",
            "coooooooloooooco...",
            ".cooddddoooododo...",
            "........oddd.o.o...",
            "........o.o.k.k....",
            ".......k.k.........",
        ],
        [
            "...................",
            ".................l.",
            "..........lll...lol",
            "...........dol.lodd",
            "............dooooo.",
            ".............ooooo.",
            ".............ookok.",
            ".............ookok.",
            "...........llccccck",
            ".........lloooccccc",
            "...lloollooooccc...",
            "..looodoooooooco...",
            ".ooood.ooooddodo...",
            ".cood..oodd.k.k....",
            ".cco...o.o.........",
            "......k.k..........",
        ],
        [
            "...................",
            "..........l......ll",
            "..........dll...lod",
            "...........dol.lod.",
            "............dooooo.",
            ".............ooooo.",
            ".............ookok.",
            ".............ookok.",
            "..........lllccccck",
            "....ooolllooooccccc",
            "..oooodooooooccc...",
            ".ooood.oooooooco...",
            ".cood..odddddodo...",
            ".cco..o.o....k.k...",
            ".....k.k...........",
            "...................",
        ],
        [
            ".................l.",
            "..........ll.....l.",
            "..........dol...lo.",
            "...........dol.lod.",
            "............dooooo.",
            ".............ooooo.",
            ".............ookok.",
            ".............ookok.",
            "....llollllllccccck",
            "..looodoooooooccccc",
            "looood.ooooooccc...",
            "coood..oooooooco...",
            "cco..koodddddodo...",
            ".......ko.....k.k..",
            "...................",
            "...................",
        ],
        [
            "...................",
            "..........l......l.",
            "..........ol.....l.",
            "..........dol...lo.",
            "...........dol.lod.",
            "............dooooo.",
            ".............ooooo.",
            "..llo........ookok.",
            ".cooooolll...ookok.",
            "cooooodooolllccccck",
            ".coood.oooooooccccc",
            "..odd..ooooooccc...",
            "......koddddooco...",
            "........ko..dodook.",
            "..............ok...",
            "...................",
        ],
        [
            "...................",
            "..........l.......l",
            "..........ol.....lo",
            "..........dol...lod",
            "...........dol.lod.",
            "............dooooo.",
            "ccl..........ooooo.",
            "coool........ookok.",
            "oooooo.......ookok.",
            ".dooooollllllccccck",
            "..dooodoooooooccccc",
            "...dod.ooooooccc...",
            ".......oooooooco...",
            ".......ooddddodo...",
            ".......k.k....o.o..",
            "...............k.k.",
        ],
        [
            "...................",
            "...................",
            "..........ll.....ll",
            "..........dol...lod",
            "...........dol.lod.",
            "............dooooo.",
            ".............ooooo.",
            ".ccol........ookok.",
            ".coool.......ookok.",
            ".oooool....llccccck",
            "..ddoooollloooccccc",
            ".....dodoooooccc...",
            "........ooooooco...",
            "........oodddodo...",
            "........o.o...o.o..",
            ".........k.k..k.k..",
        ],
    ]
}

/// Пиксельный шрифт подписи: строчные, высота x — 4 пикселя.
private enum Glyphs {
    static let table: [Character: [String]] = [
        "a": ["....", "....", ".###", "#..#", "#..#", ".###", "...."],
        "b": ["#...", "#...", "###.", "#..#", "#..#", "###.", "...."],
        "d": ["...#", "...#", ".###", "#..#", "#..#", ".###", "...."],
        "e": ["....", "....", ".##.", "####", "#...", ".###", "...."],
        "m": [".....", ".....", "####.", "#.#.#", "#.#.#", "#.#.#", "....."],
        "o": ["....", "....", ".##.", "#..#", "#..#", ".##.", "...."],
        "r": ["...", "...", "#.#", "##.", "#..", "#..", "..."],
        "t": ["...", ".#.", "###", ".#.", ".#.", "..#", "..."],
        "w": [".....", ".....", "#...#", "#...#", "#.#.#", ".#.#.", "....."],
        "y": ["....", "....", "#..#", "#..#", ".###", "...#", ".##."],
        ".": [".", ".", ".", ".", ".", "#", "."],
        " ": ["..", "..", "..", "..", "..", "..", ".."],
    ]
}
