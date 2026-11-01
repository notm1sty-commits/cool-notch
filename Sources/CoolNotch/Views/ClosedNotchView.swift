import SwiftUI

/// Свёрнутая чёлка: по бокам от выреза — «живые активности».
struct ClosedNotchView: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let ear = max(0, (vm.closedSize.width - vm.notchSize.width) / 2)
        HStack(spacing: 0) {
            ZStack { leading }
                .frame(width: ear, height: vm.notchSize.height)
            Color.clear
                .frame(width: vm.notchSize.width)
            ZStack { trailing }
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

    @State var appeared = false

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
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.55).delay(0.1)) { appeared = true }
        }
    }

    private var standard: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: vm.notchSize.height)
            HStack(spacing: 13) {
                icon
                    .scaleEffect(appeared ? 1 : 0.3)
                    .rotationEffect(.degrees(appeared ? 0 : -10))
                    .opacity(appeared ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
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
                        Spacer(minLength: 8)
                        if case .openApp = banner.action {
                            Text("сейчас")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                        }
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
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch banner.icon {
        case .artwork:
            ArtworkView(image: vm.nowPlaying.artwork, size: 44, corner: 11)
                .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        case .app(let bundleID):
            if let icon = Self.appIcon(bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
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
                .symbolEffect(.bounce, value: appeared)
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

    @State var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: vm.notchSize.height)
            HStack(spacing: 10) {
                art
                    .frame(width: 140)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(Theme.green).frame(width: 6, height: 6)
                            .shadow(color: Theme.green, radius: 4)
                        Text("Подключено к этому Mac")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    batteryRow
                        .padding(.top, 10)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.7).delay(0.08)) { appeared = true }
        }
    }

    private var art: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.5))
                .frame(width: 96, height: 12)
                .blur(radius: 6)
                .offset(y: 46)
            Image(systemName: "airpodspro")
                .font(.system(size: 76, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(
                    LinearGradient(colors: [.white, Color(red: 0.8, green: 0.81, blue: 0.85)], startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: .white.opacity(0.25), radius: 10)
                .phaseAnimator([false, true]) { view, phase in
                    view
                        .rotation3DEffect(.degrees(phase ? 10 : -6), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                        .offset(y: phase ? -3 : 0)
                } animation: { _ in
                    .easeInOut(duration: 2.5)
                }
        }
        .rotation3DEffect(.degrees(appeared ? 0 : -55), axis: (x: 0.3, y: 1, z: 0), perspective: 0.6)
        .scaleEffect(appeared ? 1 : 0.7)
        .opacity(appeared ? 1 : 0)
    }

    @ViewBuilder
    private var batteryRow: some View {
        if let levels {
            HStack(spacing: 16) {
                if let single = levels.single, levels.left == nil {
                    BatteryCell(symbol: "headphones", level: single, index: 0, appeared: appeared)
                }
                if let left = levels.left {
                    BatteryCell(symbol: "airpodpro.left", level: left, index: 0, appeared: appeared)
                }
                if let right = levels.right {
                    BatteryCell(symbol: "airpodpro.right", level: right, index: 1, appeared: appeared)
                }
                if let caseLevel = levels.caseLevel {
                    BatteryCell(symbol: "airpodspro.chargingcase.wireless.fill", level: caseLevel, index: 2, appeared: appeared)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Узнаю заряд…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }
}

private struct BatteryCell: View {
    let symbol: String
    let level: Int
    let index: Int
    let appeared: Bool

    @State var fill: CGFloat = 0

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(level)%")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 30, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(level <= 20 ? Color(red: 1, green: 0.84, blue: 0.04) : Theme.green)
                            .frame(width: 30 * fill, height: 6)
                    }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 1.1, dampingFraction: 0.85).delay(0.35 + Double(index) * 0.09)) {
                fill = CGFloat(min(max(level, 0), 100)) / 100
            }
        }
    }
}
