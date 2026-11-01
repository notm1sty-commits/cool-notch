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
                            insertion: RevealTransition(scale: 0.98, offset: CGSize(width: simple ? 0 : shift, height: 0)),
                            removal: RevealTransition(scale: 0.98, offset: CGSize(width: simple ? 0 : -shift, height: 0))
                        )
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Theme.padding)
            .padding(.top, 10)
            .padding(.bottom, 12)
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

private struct HeaderBar: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        HStack(spacing: 0) {
            LiquidTabs()
                .frame(maxWidth: .infinity, alignment: .leading)

            // Место под аппаратный вырез.
            Color.clear.frame(width: vm.notchSize.width + 16)

            HStack(spacing: 9) {
                if vm.battery.hasBattery {
                    BatteryBadge()
                }
                if vm.updates.hasUpdate {
                    Button {
                        vm.updates.install()
                        UserDefaults.standard.set(SettingsPage.updates.rawValue, forKey: "settingsPage")
                        vm.openSettings?()
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.green)
                            .frame(width: 26, height: 26)
                            .glass(13)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Установить обновление")
                    .transition(.scale.combined(with: .opacity))
                }
                Button {
                    vm.openSettings?()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .glass(13)
                }
                .buttonStyle(PressableButtonStyle())
                .help("Настройки")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }
}

/// Вкладки-кружки в одном стиле с кнопкой настроек.
private struct LiquidTabs: View {
    @Environment(NotchViewModel.self) var vm
    @State var hovered: NotchTab?
    @Namespace private var selection

    var body: some View {
        // Каждая вкладка — такой же кружок, как кнопка настроек справа; выбранная подсвечена,
        // и подсветка плавно переезжает между кружками.
        HStack(spacing: 6) {
            ForEach(NotchTab.allCases) { tab in
                Button {
                    select(tab)
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(vm.tab == tab ? 1 : (hovered == tab ? 0.8 : 0.55)))
                        .frame(width: 26, height: 26)
                        .background {
                            if vm.tab == tab {
                                Circle()
                                    .fill(Color.white.opacity(0.14))
                                    .matchedGeometryEffect(id: "selected", in: selection)
                            }
                        }
                        .glass(13, highlighted: hovered == tab && vm.tab != tab)
                        .contentShape(Circle())
                        .overlay(alignment: .topTrailing) { badge(for: tab) }
                }
                .buttonStyle(PressableButtonStyle(scale: 0.88))
                .help(tab.title)
                .onHover { inside in
                    withAnimation(Theme.micro) { hovered = inside ? tab : (hovered == tab ? nil : hovered) }
                }
            }
        }
    }

    private func select(_ tab: NotchTab) {
        guard tab != vm.tab else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { vm.select(tab) }
    }

    @ViewBuilder
    private func badge(for tab: NotchTab) -> some View {
        let count = tab == .shelf ? vm.shelf.items.count : 0
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 8, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.black)
                .padding(.horizontal, 3.5)
                .frame(minWidth: 12, minHeight: 12)
                .background(Capsule().fill(Color.white))
                .offset(x: 1, y: -3)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

private struct BatteryBadge: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let battery = vm.battery
        HStack(spacing: 5) {
            Text("\(battery.level)%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.white.opacity(0.9))
            // Как в строке меню macOS: значок целиком белый, и при зарядке тоже.
            Image(systemName: battery.symbolName)
                .font(.system(size: 14))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint(for: battery))
        }
        .animation(Theme.micro, value: battery.level)
        .help(helpText(for: battery))
    }

    private func tint(for battery: BatteryService) -> Color {
        if !battery.isCharging && !battery.isPluggedIn && battery.level <= 20 { return .red }
        return .white
    }

    private func helpText(for battery: BatteryService) -> String {
        if let minutes = battery.minutesToFull, battery.isCharging {
            return "До полной зарядки: \(minutes / 60) ч \(minutes % 60) мин"
        }
        return battery.isPluggedIn ? "Подключено к сети" : "От батареи"
    }
}
