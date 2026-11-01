import SwiftUI

struct ExpandedNotchView: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
                .frame(height: vm.notchSize.height)
            Group {
                switch vm.tab {
                case .home: HomeView()
                case .shelf: ShelfView()
                case .clipboard: ClipboardView()
                case .notes: NotesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .foregroundStyle(.white)
        .fontDesign(.rounded)
    }
}

private struct HeaderBar: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(NotchTab.allCases) { tab in
                    TabButton(tab: tab, badge: tab == .shelf ? vm.shelf.items.count : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Место под аппаратный вырез.
            Color.clear.frame(width: vm.notchSize.width + 12)

            HStack(spacing: 8) {
                if vm.battery.hasBattery {
                    BatteryBadge()
                }
                IconButton(systemName: "gearshape.fill", size: 11, help: "Настройки") {
                    vm.openSettings?()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
    }
}

private struct TabButton: View {
    @Environment(NotchViewModel.self) var vm
    var tab: NotchTab
    var badge: Int

    @State var hovering = false

    var body: some View {
        let selected = vm.tab == tab
        Button {
            withAnimation(.snappy(duration: 0.25)) { vm.tab = tab }
        } label: {
            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : (hovering ? 0.8 : 0.45)))
                .frame(width: 32, height: 22)
                .background(Capsule().fill(.white.opacity(selected ? 0.16 : (hovering ? 0.07 : 0))))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 2, y: -3)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .onHover { hovering = $0 }
    }
}

private struct BatteryBadge: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let battery = vm.battery
        HStack(spacing: 4) {
            Text("\(battery.level)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
            Image(systemName: battery.symbolName)
                .font(.system(size: 13))
                .symbolRenderingMode(.palette)
                .foregroundStyle(color(for: battery), .white.opacity(0.5))
        }
        .help(helpText(for: battery))
    }

    private func color(for battery: BatteryService) -> Color {
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
