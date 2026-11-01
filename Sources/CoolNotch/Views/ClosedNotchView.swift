import SwiftUI

/// Свёрнутая чёлка: по бокам от выреза показываем «живые активности».
struct ClosedNotchView: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: vm.earWidth, height: vm.notchSize.height)
            Color.clear
                .frame(width: vm.notchSize.width)
            trailing
                .frame(width: vm.earWidth, height: vm.notchSize.height)
        }
        .frame(height: vm.notchSize.height)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var leading: some View {
        switch vm.activity {
        case .music?:
            ArtworkView(image: vm.nowPlaying.artwork, size: max(vm.notchSize.height - 12, 16), corner: 5)
                .padding(.leading, 4)
                .transition(.scale.combined(with: .opacity))
        case .timer?:
            TimerRing(progress: vm.timer.progress, color: .orange, lineWidth: 2.5)
                .frame(width: 15, height: 15)
                .padding(.leading, 4)
        case .charging?:
            Image(systemName: "bolt.fill")
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: vm.pulse)
                .padding(.leading, 4)
        case .lowBattery?:
            Image(systemName: "battery.25percent")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
                .padding(.leading, 4)
        case .timerDone?:
            Image(systemName: "bell.fill")
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .repeating, value: vm.pulse)
                .padding(.leading, 6)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch vm.activity {
        case .music?:
            EqualizerBars(color: vm.nowPlaying.accent, isPlaying: vm.nowPlaying.isPlaying)
                .frame(height: 14)
                .padding(.trailing, 4)
        case .timer?:
            Text(vm.timer.remainingText)
                .monospacedDigit()
                .foregroundStyle(vm.timer.state == .paused ? Color.white.opacity(0.5) : Color.orange)
                .padding(.trailing, 2)
        case .charging?:
            Text("\(vm.battery.level)%")
                .monospacedDigit()
                .foregroundStyle(.green)
        case .lowBattery?:
            Text("\(vm.battery.level)%")
                .monospacedDigit()
                .foregroundStyle(.red)
        case .timerDone?:
            Text("Готово!")
                .foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }
}
