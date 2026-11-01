import SwiftUI

/// Свёрнутая чёлка: по бокам от выреза — «живые активности».
struct ClosedNotchView: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let ear = max(0, (vm.closedSize.width - vm.notchSize.width) / 2)
        HStack(spacing: 0) {
            // Содержимое «ушей» не прижимается к вырезу: отступ со стороны чёлки.
            ZStack { leading }
                .padding(.trailing, 8)
                .frame(width: ear, height: vm.notchSize.height)
            Color.clear
                .frame(width: vm.notchSize.width)
            ZStack { trailing }
                .padding(.leading, 8)
                .frame(width: ear, height: vm.notchSize.height)
        }
        .frame(height: vm.notchSize.height)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .animation(Theme.content, value: vm.activity)
    }

    private var earTransition: some Transition {
        RevealTransition(scale: 0.55, offset: .zero)
    }

    @ViewBuilder
    private var leading: some View {
        switch vm.activity {
        case .music?:
            ArtworkView(image: vm.nowPlaying.artwork, size: max(vm.notchSize.height - 12, 16), corner: 6)
                .transition(earTransition)
        case .timer?:
            TimerRing(progress: vm.timer.progress, color: Theme.orange, lineWidth: 2.4)
                .frame(width: 15, height: 15)
                .transition(earTransition)
        case .charging?:
            Image(systemName: "bolt.fill")
                .foregroundStyle(Theme.green)
                .symbolEffect(.bounce, value: vm.pulse)
                .transition(earTransition)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch vm.activity {
        case .music?:
            EqualizerView(
                color: vm.nowPlaying.accentNSColor,
                isPlaying: vm.nowPlaying.isPlaying,
                lowPower: vm.lowPower
            )
            .frame(width: 22, height: 14)
            .transition(earTransition)
        case .timer?:
            Text(vm.timer.remainingText)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(Theme.micro, value: vm.timer.remainingText)
                .foregroundStyle(vm.timer.state == .paused ? Theme.secondaryText : Theme.orange)
                .transition(earTransition)
        case .charging?:
            HStack(spacing: 6) {
                Text("\(vm.battery.level)%")
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.green)
                ChargingBattery(level: vm.battery.level, trigger: vm.pulse)
            }
            .transition(earTransition)
        case nil:
            EmptyView()
        }
    }
}

/// Батарейка, которая «заливается» при подключении зарядки.
private struct ChargingBattery: View {
    var level: Int
    var trigger: Int
    @State var shown: CGFloat = 0.2

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(Theme.green.opacity(0.6), lineWidth: 1)
                .frame(width: 23, height: 11.5)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.green)
                .frame(width: max(2, 19 * shown), height: 7.5)
                .padding(.leading, 2)
        }
        .overlay(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.green.opacity(0.6)).frame(width: 2, height: 4).offset(x: 3)
        }
        .onAppear { animateFill() }
        .onChange(of: trigger) { _, _ in animateFill() }
    }

    private func animateFill() {
        shown = 0.2
        withAnimation(.spring(response: 1.1, dampingFraction: 0.85).delay(0.3)) {
            shown = CGFloat(min(max(level, 3), 100)) / 100
        }
    }
}

/// Уведомление, «выезжающее» из чёлки.
struct BannerView: View {
    @Environment(NotchViewModel.self) var vm
    let banner: NotchBanner

    @MainActor private static var iconCache: [String: NSImage] = [:]

    @MainActor static func appIcon(_ bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    var body: some View {
        Group {
            if case let .airpods(name, levels) = banner.kind {
                AirPodsCard(name: name, levels: levels)
            } else {
                standard
            }
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { vm.performBannerAction(banner) }
    }

    /// «сейчас», «2 мин назад» или время, если давно.
    static func timeText(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "сейчас" }
        if seconds < 3600 { return "\(Int(seconds / 60)) мин назад" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var standard: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: vm.notchSize.height)
            standardRow
                .padding(.horizontal, 20)
                .modifier(BannerContentHeight())
                .background { standardRow.modifier(BannerIdealWidth()) }
            Spacer(minLength: 0)
        }
    }

    /// Строка всплывашки: значок, текст, эквалайзер. Ширина всплывашки подгоняется под неё,
    /// чтобы по бокам не оставалось пустого чёрного места.
    private var standardRow: some View {
        HStack(spacing: 13) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                if let source = banner.source {
                    // Как на iPhone: приложение слева, время справа.
                    HStack(alignment: .firstTextBaseline) {
                        Text(source)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.timeText(banner.date))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                if banner.icon == .artwork {
                    Text(vm.nowPlaying.items.first?.isVideo == true ? "ВИДЕО" : "СЕЙЧАС ИГРАЕТ")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.tertiaryText)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(banner.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                if let subtitle = banner.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(banner.expanded ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if banner.icon == .artwork {
                EqualizerView(
                    color: vm.nowPlaying.accentNSColor,
                    isPlaying: vm.nowPlaying.isPlaying,
                    lowPower: vm.lowPower
                )
                .frame(width: 22, height: 14)
            }
        }
    }

    /// У значков приложений есть прозрачные поля, поэтому рамка чуть больше высоты текста —
    /// тогда сам значок визуально совпадает с блоком «приложение · заголовок · текст».
    private var appIconSize: CGFloat { banner.source != nil ? 58 : 50 }

    @ViewBuilder
    private var icon: some View {
        switch banner.icon {
        case .artwork:
            ArtworkView(image: vm.nowPlaying.artwork, size: 50, corner: 12)
                .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        case .app(let bundleID):
            if let icon = Self.appIcon(bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: appIconSize, height: appIconSize)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            } else {
                Image(systemName: "app.badge.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .glass(11)
            }
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(banner.tint)
                .frame(width: 42, height: 42)
                .glass(21, tint: banner.tint)
        }
    }
}

/// Карточка «AirPods подключены» с зарядом левого, правого наушника и футляра.
struct AirPodsCard: View {
    @Environment(NotchViewModel.self) var vm
    let name: String
    let levels: AirPodsLevels?

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: vm.notchSize.height)
            row
                .padding(.horizontal, 20)
                .modifier(BannerContentHeight())
            Spacer(minLength: 0)
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: deviceSymbol)
                .font(.system(size: 17, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("Подключено")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Кольца и проценты не сжимаются никогда — если тесно, обрежется название.
            batteries
                .fixedSize()
                .padding(.leading, 10)
        }
    }

    private var deviceSymbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        let type = levels?.deviceType?.lowercased() ?? ""
        if type.contains("speaker") { return "hifispeaker.fill" }
        if type.contains("car") { return "car.fill" }
        return "headphones"
    }

    @ViewBuilder
    private var batteries: some View {
        if let levels, levels.isEmpty {
            EmptyView()
        } else if let levels {
            HStack(spacing: 12) {
                if let single = levels.single, levels.left == nil {
                    BatteryRing(symbol: "headphones", label: "Заряд", level: single)
                }
                if let left = levels.left {
                    BatteryRing(symbol: "airpod.left", label: "Л", level: left)
                }
                if let right = levels.right {
                    BatteryRing(symbol: "airpod.right", label: "П", level: right)
                }
                if let caseLevel = levels.caseLevel {
                    BatteryRing(symbol: "airpodspro.chargingcase.wireless", label: "Футляр", level: caseLevel)
                }
            }
            .transition(.opacity)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// Кольцо заряда с процентом под ним — как в карточке AirPods на iPhone.
private struct BatteryRing: View {
    let symbol: String
    let label: String
    let level: Int

    @State private var fill: CGFloat = 0

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fill)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 30, height: 30)
            Text("\(level)%")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .fixedSize()
        }
        .help(label)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                fill = CGFloat(min(max(level, 0), 100)) / 100
            }
        }
    }

    private var color: Color {
        level <= 20 ? Color(red: 1, green: 0.62, blue: 0.04) : Theme.green
    }
}

/// Высота всплывашки = её содержимое + одинаковые отступы (сверху от выреза и снизу от последнего
/// элемента). Содержимое меряет себя само, и форма чёлки подстраивается ровно под него.
struct BannerContentHeight: ViewModifier {
    @Environment(NotchViewModel.self) var vm

    static let topGap: CGFloat = 6
    static let bottomGap: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(.top, Self.topGap)
            .padding(.bottom, Self.bottomGap)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: BannerHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(BannerHeightKey.self) { height in
                MainActor.assumeIsolated {
                    if height > 0, abs((vm.bannerContentHeight ?? 0) - height) > 0.5 {
                        vm.bannerContentHeight = height
                    }
                }
            }
    }
}

/// Меряет «естественную» ширину строки всплывашки (невидимая копия без ограничений),
/// чтобы форма чёлки обнимала содержимое, а не оставляла пустые края.
struct BannerIdealWidth: ViewModifier {
    @Environment(NotchViewModel.self) var vm

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .hidden()
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: BannerWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(BannerWidthKey.self) { width in
                MainActor.assumeIsolated {
                    if width > 0, abs((vm.bannerContentWidth ?? 0) - width) > 0.5 {
                        vm.bannerContentWidth = width
                    }
                }
            }
    }
}

private struct BannerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BannerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
