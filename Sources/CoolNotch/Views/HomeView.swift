import SwiftUI

struct HomeView: View {
    var body: some View {
        HStack(spacing: 16) {
            MusicCard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .padding(.vertical, 8)
            TimerCard()
                .frame(width: 172)
        }
    }
}

// MARK: - Music

private struct MusicCard: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let player = vm.nowPlaying
        if let track = player.track {
            HStack(spacing: 14) {
                ArtworkView(image: player.artwork, size: 96, corner: 16)
                    .shadow(color: player.accent.opacity(player.isPlaying ? 0.6 : 0.25), radius: 18)
                    .scaleEffect(player.isPlaying ? 1 : 0.94)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: player.isPlaying)
                    .onTapGesture { player.openSourceApp() }
                    .help("Открыть плеер")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .bold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        EqualizerBars(color: player.accent, isPlaying: player.isPlaying)
                            .frame(height: 12)
                    }
                    Text(track.artist.isEmpty ? track.album : track.artist)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    PlaybackProgress(player: player)

                    HStack(spacing: 18) {
                        Spacer(minLength: 0)
                        IconButton(systemName: "backward.fill", size: 13, help: "Предыдущий трек") { player.previous() }
                        IconButton(systemName: player.isPlaying ? "pause.fill" : "play.fill", size: 19, help: "Пауза / воспроизведение") {
                            player.togglePlayPause()
                        }
                        .contentTransition(.symbolEffect(.replace))
                        IconButton(systemName: "forward.fill", size: 13, help: "Следующий трек") { player.next() }
                        Spacer(minLength: 0)
                    }
                }
            }
        } else {
            EmptyMusicView()
        }
    }
}

private struct PlaybackProgress: View {
    let player: NowPlayingService
    @State var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(player.track?.duration ?? 0, 0)
            let position = player.position(at: context.date)
            let fraction = dragFraction ?? (duration > 0 ? min(max(position / duration, 0), 1) : 0)

            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule()
                            .fill(player.accent.gradient)
                            .frame(width: max(5, geo.size.width * fraction))
                    }
                    .frame(height: dragFraction == nil ? 5 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            }
                            .onEnded { value in
                                guard duration > 0 else { return }
                                let target = min(max(value.location.x / geo.size.width, 0), 1)
                                player.seek(to: target * duration)
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 9)
                .animation(.easeOut(duration: 0.15), value: dragFraction == nil)

                HStack {
                    Text(TimerService.format(fraction * duration))
                    Spacer()
                    Text("−" + TimerService.format(max(0, duration - fraction * duration)))
                }
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

private struct EmptyMusicView: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let player = vm.nowPlaying
        HStack(spacing: 14) {
            ArtworkView(image: nil, size: 96, corner: 16)
            VStack(alignment: .leading, spacing: 6) {
                Text("Сейчас ничего не играет")
                    .font(.system(size: 14, weight: .bold))
                Text("Включи музыку в Spotify или Музыке — она появится здесь.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(player.installedPlayers, id: \.rawValue) { app in
                        Button {
                            player.launch(app)
                        } label: {
                            Text(app == .music ? "Музыка" : app.appName)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Timer

private struct TimerCard: View {
    @Environment(NotchViewModel.self) var vm

    private static let presets = [1, 5, 10, 15, 25, 45]

    var body: some View {
        let timer = vm.timer
        VStack(spacing: 8) {
            if timer.isActive {
                ZStack {
                    TimerRing(progress: timer.progress, color: .orange, lineWidth: 5)
                    VStack(spacing: 0) {
                        Text(timer.remainingText)
                            .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                        Text(timer.state == .paused ? "пауза" : "осталось")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .frame(width: 86, height: 86)

                HStack(spacing: 6) {
                    IconButton(systemName: timer.state == .paused ? "play.fill" : "pause.fill", size: 11, help: "Пауза") {
                        timer.toggle()
                    }
                    IconButton(systemName: "plus", size: 11, help: "Добавить минуту") { timer.addMinute() }
                    IconButton(systemName: "xmark", size: 11, help: "Остановить") { timer.stop() }
                }
            } else {
                HStack {
                    Label("Таймер", systemImage: "timer")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Self.presets, id: \.self) { minutes in
                        PresetButton(minutes: minutes) { timer.start(minutes: minutes) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct PresetButton: View {
    var minutes: Int
    var action: () -> Void
    @State var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text("\(minutes)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("мин")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Color.orange.opacity(0.3) : Color.white.opacity(0.07))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
