import SwiftUI

/// Вкладка «Часы»: слева текущее время (стрелочные часы, цифры, дата), справа — таймер или секундомер.
struct ClockView: View {
    @Environment(NotchViewModel.self) var vm
    @AppStorage("clockMode") private var modeRaw = ClockMode.timer.rawValue

    enum ClockMode: String, CaseIterable {
        case timer, stopwatch

        var title: String { self == .timer ? "Таймер" : "Секундомер" }
    }

    private var mode: ClockMode { ClockMode(rawValue: modeRaw) ?? .timer }

    var body: some View {
        HStack(spacing: 18) {
            NowPanel()
                .frame(width: 232)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 12) {
                picker
                ZStack(alignment: .topLeading) {
                    switch mode {
                    case .timer:
                        TimerPane().transition(.opacity.combined(with: .offset(x: -12)))
                    case .stopwatch:
                        StopwatchPane().transition(.opacity.combined(with: .offset(x: 12)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .animation(Theme.content, value: mode)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// «Таймер | Секундомер»; точка — если там что-то идёт.
    private var picker: some View {
        HStack(spacing: 6) {
            ForEach(ClockMode.allCases, id: \.self) { item in
                let selected = item == mode
                let running = item == .timer ? vm.timer.isActive : vm.stopwatch.isRunning
                Button {
                    withAnimation(Theme.content) { modeRaw = item.rawValue }
                } label: {
                    HStack(spacing: 5) {
                        if running {
                            Circle()
                                .fill(item == .timer ? Theme.orange : Theme.liveGreen)
                                .frame(width: 5, height: 5)
                        }
                        Text(item.title)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(selected ? .white : Theme.secondaryText)
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .glass(12, highlighted: selected)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.92))
            }
        }
    }
}

// MARK: - Сейчас

private struct NowPanel: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 16) {
                AnalogClock(date: context.date)
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 34, weight: .light).monospacedDigit())
                        .tracking(-0.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(context.date.formatted(.dateTime.weekday(.wide)).capitalized)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                    Text(context.date.formatted(.dateTime.day().month(.wide)))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

/// Стрелочные часы: метки, часовая и минутная стрелки, оранжевая секундная.
private struct AnalogClock: View {
    var date: Date

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side / 2

            let face = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: side, height: side))
            context.fill(face, with: .color(.white.opacity(0.06)))
            context.stroke(face, with: .color(.white.opacity(0.12)), lineWidth: 1)

            for tick in 0..<60 {
                let angle = Double(tick) / 60 * 2 * .pi
                let major = tick % 5 == 0
                let outer = radius - 5
                let inner = outer - (tick % 15 == 0 ? 7 : major ? 5 : 1.5)
                var path = Path()
                path.move(to: point(center, angle, inner))
                path.addLine(to: point(center, angle, outer))
                context.stroke(
                    path,
                    with: .color(.white.opacity(major ? 0.55 : 0.18)),
                    style: StrokeStyle(lineWidth: major ? 1.6 : 1, lineCap: .round)
                )
            }

            let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
            let seconds = Double(parts.second ?? 0)
            let minutes = Double(parts.minute ?? 0) + seconds / 60
            let hours = Double((parts.hour ?? 0) % 12) + minutes / 60

            hand(&context, center, hours / 12, length: radius * 0.5, width: 3.2, color: .white)
            hand(&context, center, minutes / 60, length: radius * 0.74, width: 2.2, color: .white)
            hand(&context, center, seconds / 60, length: radius * 0.82, width: 1, color: Theme.orange, tail: radius * 0.16)

            let dot = CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: dot), with: .color(Theme.orange))
        }
    }

    private func point(_ center: CGPoint, _ angle: Double, _ distance: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(sin(angle)) * distance, y: center.y - CGFloat(cos(angle)) * distance)
    }

    private func hand(_ context: inout GraphicsContext, _ center: CGPoint, _ turn: Double, length: CGFloat, width: CGFloat, color: Color, tail: CGFloat = 0) {
        let angle = turn * 2 * .pi
        var path = Path()
        path.move(to: point(center, angle + .pi, tail))
        path.addLine(to: point(center, angle, length))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

// MARK: - Таймер

private struct TimerPane: View {
    @Environment(NotchViewModel.self) var vm
    @AppStorage("timerPresetSeconds") var preset = 300
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private static let presets = [5, 15, 25, 45]

    var body: some View {
        let timer = vm.timer
        HStack(alignment: .center, spacing: 16) {
            if timer.isActive {
                VStack(alignment: .leading, spacing: 8) {
                    Text(timer.remainingText)
                        .font(.system(size: 40, weight: .light).monospacedDigit())
                        .tracking(-0.8)
                        .foregroundStyle(Theme.orange)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(Theme.micro, value: timer.remainingText)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Capsule()
                            .fill(Theme.orange.opacity(0.2))
                            .frame(height: 4)
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(Theme.orange)
                                        .frame(width: geo.size.width * timer.progress)
                                        .animation(.linear(duration: 0.5), value: timer.progress)
                                }
                            }
                        Text("из \(TimerService.durationText(timer.total))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.tertiaryText)
                            .fixedSize()
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    smallPill("+1 мин", help: "Добавить минуту") { timer.addMinute() }
                    RoundButton(symbol: "xmark", tint: .white, size: 44, help: "Отменить") {
                        withAnimation(Theme.content) { timer.stop() }
                    }
                    RoundButton(symbol: timer.state == .paused ? "play.fill" : "pause.fill", tint: Theme.orange, size: 56,
                                help: timer.state == .paused ? "Продолжить" : "Пауза") {
                        timer.toggle()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        stepButton("minus") { adjust(-60) }
                        timeField
                            .frame(minWidth: 120)
                        stepButton("plus") { adjust(60) }
                    }
                    HStack(spacing: 6) {
                        ForEach(Self.presets, id: \.self) { minutes in
                            let selected = preset == minutes * 60
                            Button {
                                withAnimation(Theme.micro) { preset = minutes * 60 }
                            } label: {
                                Text("\(minutes) мин")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(selected ? Theme.orange : .white.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .frame(height: 24)
                                    .background(Capsule().fill(selected ? Theme.orange.opacity(0.24) : Color.white.opacity(0.09)))
                            }
                            .buttonStyle(PressableButtonStyle(scale: 0.88))
                        }
                    }
                }
                Spacer(minLength: 0)
                RoundButton(symbol: "play.fill", tint: Theme.orange, size: 56, help: "Старт") {
                    commitDraft()
                    withAnimation(Theme.content) { timer.start(seconds: TimeInterval(preset)) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.content, value: timer.isActive)
    }

    /// Цифры: клик — ввод с клавиатуры («90» — 90 минут, «1:30» — 1 мин 30 с, «1:30:00» — 1,5 часа).
    @ViewBuilder
    private var timeField: some View {
        if editing {
            TextField("мм или мм:сс", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 34, weight: .light).monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($fieldFocused)
                .onSubmit { commitDraft() }
                .onAppear {
                    fieldFocused = true
                    vm.beginTyping()
                }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { commitDraft() }
                }
        } else {
            Text(TimerService.format(TimeInterval(preset)))
                .font(.system(size: 40, weight: .light).monospacedDigit())
                .tracking(-0.8)
                .contentTransition(.numericText())
                .animation(Theme.micro, value: preset)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentShape(Rectangle())
                .onTapGesture {
                    draft = ""
                    editing = true
                }
                .help("Нажми, чтобы ввести любое время")
        }
    }

    private func adjust(_ delta: Int) {
        withAnimation(Theme.micro) { preset = min(max(preset + delta, 60), 24 * 3600) }
    }

    private func commitDraft() {
        guard editing else { return }
        editing = false
        vm.endTyping()
        if let seconds = TimerService.parse(draft) {
            withAnimation(Theme.micro) { preset = seconds }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .glass(14)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.85))
    }

    private func smallPill(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .glass(13)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .help(help)
    }
}

// MARK: - Секундомер

private struct StopwatchPane: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let stopwatch = vm.stopwatch
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                // Сотые бегут, только пока секундомер идёт и вкладка на экране.
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !stopwatch.isRunning)) { context in
                    Text(StopwatchService.format(stopwatch.elapsed(at: context.date)))
                        .font(.system(size: 40, weight: .light).monospacedDigit())
                        .tracking(-0.8)
                        .foregroundStyle(stopwatch.hasTime ? Theme.liveGreen : .white)
                        .lineLimit(1)
                }
                let laps = stopwatch.laps
                if laps.isEmpty {
                    Text(stopwatch.isRunning ? "«Круг» — отметить отрезок" : "Нажми ▶︎, чтобы начать")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    HStack(spacing: 6) {
                        ForEach(laps.prefix(3)) { lap in
                            HStack(spacing: 4) {
                                Text("Круг \(lap.number)")
                                    .foregroundStyle(Theme.tertiaryText)
                                Text(StopwatchService.format(lap.duration))
                                    .monospacedDigit()
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                    .animation(Theme.bouncy, value: laps.count)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                if stopwatch.isRunning {
                    RoundButton(symbol: "flag.fill", tint: .white, size: 44, help: "Круг") { stopwatch.lap() }
                } else {
                    RoundButton(symbol: "arrow.counterclockwise", tint: .white, size: 44, help: "Сбросить") {
                        withAnimation(Theme.content) { stopwatch.reset() }
                    }
                    .disabled(!stopwatch.hasTime)
                    .opacity(stopwatch.hasTime ? 1 : 0.35)
                }
                RoundButton(symbol: stopwatch.isRunning ? "pause.fill" : "play.fill", tint: Theme.liveGreen, size: 56,
                            help: stopwatch.isRunning ? "Пауза" : "Старт") {
                    withAnimation(Theme.content) { stopwatch.toggle() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.content, value: stopwatch.isRunning)
    }
}

/// Круглая кнопка: белая — второстепенная, цветная — главная.
private struct RoundButton: View {
    let symbol: String
    let tint: Color
    let size: CGFloat
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.3, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(Circle().fill(tint == .white ? Color.white.opacity(0.12) : tint.opacity(0.22)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.88))
        .help(help)
    }
}
