import SwiftUI

struct HomeView: View {
    var body: some View {
        HStack(spacing: 14) {
            MusicSection()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TimerCard()
                .frame(width: 168)
                .frame(maxHeight: .infinity)
                .surface()
        }
    }
}

// MARK: - Music

private struct MusicSection: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let player = vm.nowPlaying
        ZStack {
            if let track = player.track {
                PlayerView(player: player, track: track)
                    .transition(.opacity)
            } else if let external = player.externalPlayer {
                ExternalPlayerView(player: player, external: external)
                    .transition(.opacity)
            } else {
                EmptyMusicView()
                    .transition(.opacity)
            }
        }
        .animation(Theme.content, value: player.track == nil)
    }
}

private struct PlayerView: View {
    let player: NowPlayingService
    let track: NowPlayingTrack

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(image: player.artwork, size: 104, corner: 16)
                .overlay(alignment: .bottomTrailing) {
                    if let icon = player.sourceIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                            .offset(x: 7, y: 7)
                    }
                }
                .scaleEffect(player.isPlaying ? 1 : 0.92)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .animation(Theme.open, value: player.isPlaying)
                .onTapGesture { player.openSourceApp() }
                .help(player.sourceName.isEmpty ? "Открыть плеер" : "Открыть \(player.sourceName)")

            VStack(alignment: .leading, spacing: 0) {
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(track.artist.isEmpty ? track.album : track.artist)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .padding(.top, 2)

                Spacer(minLength: 8)

                PlaybackProgress(player: player)

                HStack(spacing: 20) {
                    Spacer(minLength: 0)
                    IconButton(systemName: "backward.fill", size: 13, help: "Предыдущий трек") { player.previous() }
                    IconButton(systemName: player.isPlaying ? "pause.fill" : "play.fill", size: 20, help: "Пауза / воспроизведение") {
                        player.togglePlayPause()
                    }
                    .contentTransition(.symbolEffect(.replace))
                    IconButton(systemName: "forward.fill", size: 13, help: "Следующий трек") { player.next() }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
            .animation(Theme.content, value: track)
        }
    }
}

private struct PlaybackProgress: View {
    let player: NowPlayingService

    @State var dragFraction: Double?
    @State var hovering = false

    var body: some View {
        // Раз в секунду + линейная анимация между тиками: плавно, но почти без нагрузки.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = max(player.track?.duration ?? 0, 0)
            let position = player.position(at: context.date)
            let fraction = dragFraction ?? (duration > 0 ? min(max(position / duration, 0), 1) : 0)
            let active = hovering || dragFraction != nil

            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule()
                            .fill(Color.white.opacity(active ? 1 : 0.85))
                            .frame(width: max(active ? 7 : 4, geo.size.width * fraction))
                            .animation(dragFraction == nil ? .linear(duration: 1) : nil, value: fraction)
                    }
                    .frame(height: active ? 7 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0, geo.size.width > 0 else { return }
                                dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            }
                            .onEnded { value in
                                guard duration > 0, geo.size.width > 0 else { return }
                                let target = min(max(value.location.x / geo.size.width, 0), 1)
                                player.seek(to: target * duration)
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 10)

                HStack {
                    Text(TimerService.format(fraction * duration))
                    Spacer()
                    Text("−" + TimerService.format(max(0, duration - fraction * duration)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiaryText)
                .opacity(duration > 0 ? 1 : 0)
            }
        }
        .onHover { value in
            withAnimation(Theme.hover) { hovering = value }
        }
    }
}

/// Плеер, который не сообщает название трека (Яндекс Музыка): только управление.
private struct ExternalPlayerView: View {
    let player: NowPlayingService
    let external: ExternalPlayer

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface)
                if let icon = external.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 60, height: 60)
                }
            }
            .frame(width: 104, height: 104)
            .onTapGesture { player.openSourceApp() }

            VStack(alignment: .leading, spacing: 4) {
                Text(external.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(player.canControlAnyPlayer
                     ? "Название трека это приложение не сообщает, но кнопки работают."
                     : "Разреши «Универсальный доступ», чтобы переключать треки из чёлки.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 6)

                if player.canControlAnyPlayer {
                    HStack(spacing: 20) {
                        IconButton(systemName: "backward.fill", size: 13, help: "Предыдущий трек") { player.previous() }
                        IconButton(systemName: "playpause.fill", size: 18, help: "Пауза / воспроизведение") { player.togglePlayPause() }
                        IconButton(systemName: "forward.fill", size: 13, help: "Следующий трек") { player.next() }
                    }
                } else {
                    CapsuleButton(title: "Разрешить управление", systemImage: "hand.raised.fill", prominent: true) {
                        player.requestControlAccess()
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct EmptyMusicView: View {
    @Environment(NotchViewModel.self) var vm
    @AppStorage(Pref.browserMusic) var browserMusic = false

    var body: some View {
        let player = vm.nowPlaying
        HStack(spacing: 16) {
            ArtworkView(image: nil, size: 104, corner: 16)
            VStack(alignment: .leading, spacing: 5) {
                Text("Ничего не играет")
                    .font(.system(size: 15, weight: .semibold))
                Text(browserMusic
                     ? "Включи музыку в Spotify, Музыке или в браузере."
                     : "Включи музыку в Spotify или Музыке. Слушаешь в браузере? Включи это ниже.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    ForEach(player.installedPlayers, id: \.bundleID) { app in
                        CapsuleButton(title: player.displayName(for: app), systemImage: nil) {
                            player.launch(app)
                        }
                    }
                    if !browserMusic {
                        CapsuleButton(title: "Браузер", systemImage: "globe") {
                            browserMusic = true
                        }
                        .help("Яндекс Музыка, YouTube, SoundCloud, VK в браузере")
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
        ZStack {
            if timer.isActive {
                VStack(spacing: 8) {
                    ZStack {
                        TimerRing(progress: timer.progress, color: .orange, lineWidth: 4.5)
                        VStack(spacing: 0) {
                            Text(timer.remainingText)
                                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                                .contentTransition(.numericText(countsDown: true))
                                .animation(Theme.micro, value: timer.remainingText)
                            Text(timer.state == .paused ? "пауза" : "осталось")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    .frame(width: 82, height: 82)

                    HStack(spacing: 4) {
                        IconButton(systemName: timer.state == .paused ? "play.fill" : "pause.fill", size: 10.5, help: "Пауза") {
                            timer.toggle()
                        }
                        .contentTransition(.symbolEffect(.replace))
                        IconButton(systemName: "plus", size: 10.5, help: "Добавить минуту") { timer.addMinute() }
                        IconButton(systemName: "xmark", size: 10.5, help: "Остановить") {
                            withAnimation(Theme.content) { timer.stop() }
                        }
                    }
                }
                .transition(RevealTransition(blur: 6, scale: 0.92, offset: .zero))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ТАЙМЕР").sectionLabelStyle()
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(Self.presets, id: \.self) { minutes in
                            PresetButton(minutes: minutes) {
                                withAnimation(Theme.content) { timer.start(minutes: minutes) }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .transition(RevealTransition(blur: 6, scale: 0.96, offset: .zero))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text("мин")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                    .fill(hovering ? Color.orange.opacity(0.28) : Color.white.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .onHover { value in
            withAnimation(Theme.micro) { hovering = value }
        }
    }
}
