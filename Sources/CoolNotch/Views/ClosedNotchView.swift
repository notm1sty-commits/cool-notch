import SwiftUI

/// Свёрнутая чёлка: по бокам от выреза — «живые активности».
struct ClosedNotchView: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let ear = max(0, (vm.shapeSize.width - vm.notchSize.width) / 2)
        HStack(spacing: 0) {
            ZStack { leading }
                .frame(width: ear, height: vm.notchSize.height)
            Color.clear
                .frame(width: vm.notchSize.width)
            ZStack { trailing }
                .frame(width: ear, height: vm.notchSize.height)
        }
        .frame(height: vm.notchSize.height)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
    }

    private var earTransition: some Transition {
        RevealTransition(blur: vm.lowPower ? 0 : 4, scale: 0.6, offset: .zero)
    }

    @ViewBuilder
    private var leading: some View {
        switch vm.activity {
        case .music?:
            ArtworkView(image: vm.nowPlaying.artwork, size: max(vm.notchSize.height - 12, 16), corner: 5)
                .transition(earTransition)
        case .timer?:
            TimerRing(progress: vm.timer.progress, color: .orange, lineWidth: 2.5)
                .frame(width: 14, height: 14)
                .transition(earTransition)
        case .charging?:
            Image(systemName: "bolt.fill")
                .foregroundStyle(.green)
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
                animated: !vm.lowPower
            )
            .frame(width: 22, height: 14)
            .transition(earTransition)
        case .timer?:
            Text(vm.timer.remainingText)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(Theme.micro, value: vm.timer.remainingText)
                .foregroundStyle(vm.timer.state == .paused ? Theme.secondaryText : Color.orange)
                .transition(earTransition)
        case .charging?:
            Text("\(vm.battery.level)%")
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.green)
                .transition(earTransition)
        case nil:
            EmptyView()
        }
    }
}

/// Уведомление, «выезжающее» из чёлки.
struct BannerView: View {
    @MainActor private static var iconCache: [String: NSImage] = [:]

    @MainActor static func appIcon(_ bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    @Environment(NotchViewModel.self) var vm
    let banner: NotchBanner

    @State var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: vm.notchSize.height)
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let subtitle = banner.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(banner.expanded ? 2 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if banner.icon == .artwork {
                    EqualizerView(
                        color: vm.nowPlaying.accentNSColor,
                        isPlaying: vm.nowPlaying.isPlaying,
                        animated: !vm.lowPower
                    )
                    .frame(width: 22, height: 14)
                }
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture {
            vm.performBannerAction(banner)
        }
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private var icon: some View {
        switch banner.icon {
        case .artwork:
            ArtworkView(image: vm.nowPlaying.artwork, size: 34, corner: 8)
        case .app(let bundleID):
            if let icon = Self.appIcon(bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .animation(Theme.hover, value: appeared)
            } else {
                Image(systemName: "app.badge.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(banner.tint)
                .symbolEffect(.bounce, value: appeared)
                .frame(width: 34, height: 34)
                .background(Circle().fill(banner.tint.opacity(0.16)))
        }
    }
}
