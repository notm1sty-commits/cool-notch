import SwiftUI

struct ExpandedNotchView: View {
    @Environment(NotchViewModel.self) var vm
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        let simple = reduceMotion || vm.lowPower
        let shift = 18 * vm.tabDirection

        VStack(spacing: 0) {
            HeaderBar()
                .frame(height: vm.notchSize.height)

            ZStack {
                tabContent
                    .id(vm.tab)
                    .transition(
                        AsymmetricTransition(
                            insertion: RevealTransition(blur: simple ? 0 : 6, scale: 0.98, offset: CGSize(width: simple ? 0 : shift, height: 0)),
                            removal: RevealTransition(blur: simple ? 0 : 6, scale: 0.98, offset: CGSize(width: simple ? 0 : -shift, height: 0))
                        )
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Theme.padding)
            .padding(.top, 10)
            .padding(.bottom, Theme.padding)
        }
        .background(alignment: .topLeading) {
            if !simple { AmbientGlow() }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch vm.tab {
        case .home: HomeView()
        case .shelf: ShelfView()
        case .clipboard: ClipboardView()
        case .notes: NotesView()
        }
    }
}

/// Едва заметное цветное свечение от обложки — как в «Музыке» на iPhone, но тише.
private struct AmbientGlow: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let player = vm.nowPlaying
        ZStack {
            if vm.tab == .home, player.track != nil, let artwork = player.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 240, height: 240)
                    .blur(radius: 70)
                    .opacity(player.isPlaying ? 0.3 : 0.15)
                    .offset(x: -40, y: 10)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(Theme.content, value: player.artwork)
        .animation(Theme.content, value: player.isPlaying)
        .animation(Theme.content, value: vm.tab)
    }
}

private struct HeaderBar: View {
    @Environment(NotchViewModel.self) var vm
    @Namespace var tabNamespace

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(NotchTab.allCases) { tab in
                    TabButton(tab: tab, namespace: tabNamespace)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Место под аппаратный вырез.
            Color.clear.frame(width: vm.notchSize.width + 12)

            HStack(spacing: 8) {
                if vm.battery.hasBattery {
                    BatteryBadge()
                }
                IconButton(systemName: "gearshape.fill", size: 10.5, help: "Настройки") {
                    vm.openSettings?()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
    }
}

private struct TabButton: View {
    @Environment(NotchViewModel.self) var vm
    let tab: NotchTab
    let namespace: Namespace.ID

    @State var hovering = false

    var body: some View {
        let selected = vm.tab == tab
        let badge = tab == .shelf ? vm.shelf.items.count : 0

        Button {
            withAnimation(Theme.content) { vm.select(tab) }
        } label: {
            ZStack {
                if selected {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .matchedGeometryEffect(id: "selected-tab", in: namespace)
                } else if hovering {
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                }
                Image(systemName: tab.icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(selected ? 1 : (hovering ? 0.8 : 0.42)))
            }
            .frame(width: 34, height: 22)
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 8, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3.5)
                        .frame(minWidth: 12, minHeight: 12)
                        .background(Capsule().fill(Color.white))
                        .offset(x: 3, y: -3)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .help(tab.title)
        .onHover { value in
            withAnimation(Theme.micro) { hovering = value }
        }
        .animation(Theme.hover, value: badge)
    }
}

private struct BatteryBadge: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let battery = vm.battery
        HStack(spacing: 4) {
            Text("\(battery.level)%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Theme.secondaryText)
            Image(systemName: battery.symbolName)
                .font(.system(size: 13))
                .symbolRenderingMode(.palette)
                .foregroundStyle(tint(for: battery), Theme.tertiaryText)
        }
        .animation(Theme.micro, value: battery.level)
        .help(helpText(for: battery))
    }

    private func tint(for battery: BatteryService) -> Color {
        if battery.isCharging || battery.isPluggedIn { return .green }
        if battery.level <= 20 { return .red }
        return .white
    }

    private func helpText(for battery: BatteryService) -> String {
        if let minutes = battery.minutesToFull, battery.isCharging {
            return "До полной зарядки: \(minutes / 60) ч \(minutes % 60) мин"
        }
        return battery.isPluggedIn ? "Подключено к сети" : "От батареи"
    }
}
