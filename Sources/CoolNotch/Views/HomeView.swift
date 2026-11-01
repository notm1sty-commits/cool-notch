import SwiftUI

struct HomeView: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if vm.nowPlaying.items.isEmpty {
                    if let external = vm.nowPlaying.externalPlayer {
                        ExternalPlayerView(player: vm.nowPlaying, external: external)
                            .padding(.horizontal, 24)
                    } else {
                        EmptyMusicView()
                            .padding(.horizontal, 24)
                    }
                } else {
                    MediaDeck()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.content, value: vm.nowPlaying.items.isEmpty)

            TimerCard()
                .frame(width: 172)
                .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Deck

/// Карусель всего, что играет или на паузе: стрелки, свайп, точки и 3D-поворот при смене.
private struct MediaDeck: View {
    @Environment(NotchViewModel.self) var vm
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var position: Double = 0
    @State var dragOrigin: Double?

    var body: some View {
        let items = vm.nowPlaying.items
        let depth = vm.fx3D && !reduceMotion && !vm.lowPower
        GeometryReader { geo in
            let cardWidth = max(220, geo.size.width - 64)
            let cardHeight = max(100, geo.size.height - 16)
            VStack(spacing: 4) {
                ZStack {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        MediaCard(item: item, depth: depth)
                            .frame(width: cardWidth, height: cardHeight)
                            .modifier(DeckCardEffect(position: position, index: index, spacing: cardWidth * 1.04, depth: depth))
                    }
                }
                .frame(width: geo.size.width, height: cardHeight)
                .contentShape(Rectangle())
                .gesture(dragGesture(cardWidth: cardWidth, count: items.count))
                .overlay(alignment: .leading) {
                    navButton(systemName: "chevron.left", enabled: vm.deckIndex > 0) { vm.selectDeck(vm.deckIndex - 1) }
                }
                .overlay(alignment: .trailing) {
                    navButton(systemName: "chevron.right", enabled: vm.deckIndex < items.count - 1) { vm.selectDeck(vm.deckIndex + 1) }
                }

                if items.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Capsule()
                                .fill(Color.white.opacity(index == vm.deckIndex ? 1 : 0.3))
                                .frame(width: index == vm.deckIndex ? 18 : 6, height: 6)
                                .contentShape(Rectangle())
                                .onTapGesture { vm.selectDeck(index) }
                                .help(item.sourceLabel)
                        }
                    }
                    .frame(height: 10)
                    .animation(Theme.bouncy, value: vm.deckIndex)
                }
            }
        }
        .onAppear { position = Double(vm.deckIndex) }
        .onChange(of: vm.deckIndex) { _, newValue in
            withAnimation(Theme.deck) { position = Double(newValue) }
        }
        .onChange(of: items.map(\.id)) { _, _ in
            vm.selectDeck(vm.deckIndex)
            withAnimation(Theme.deck) { position = Double(vm.deckIndex) }
        }
    }

    private func dragGesture(cardWidth: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = position }
                var x = (dragOrigin ?? 0) - Double(value.translation.width / cardWidth)
                let maxIndex = Double(max(count - 1, 0))
                if x < 0 { x *= 0.35 } else if x > maxIndex { x = maxIndex + (x - maxIndex) * 0.35 }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { position = x }
            }
            .onEnded { value in
                let predicted = (dragOrigin ?? position) - Double(value.predictedEndTranslation.width / cardWidth)
                dragOrigin = nil
                let target = min(max(Int(predicted.rounded()), 0), max(count - 1, 0))
                if target == vm.deckIndex {
                    withAnimation(Theme.deck) { position = Double(target) }
                } else {
                    vm.selectDeck(target)
                }
            }
    }

    private func navButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .glass(13)
        }
        .buttonStyle(PressableButtonStyle())
        .opacity(enabled ? 1 : 0.22)
        .disabled(!enabled)
        .animation(Theme.micro, value: enabled)
    }
}

/// Положение карточки в карусели. Анимируется сама «позиция», поэтому
/// сдвиг, поворот, масштаб и прозрачность всегда согласованы между собой.
private struct DeckCardEffect: ViewModifier, Animatable {
    var position: Double
    let index: Int
    let spacing: CGFloat
    let depth: Bool

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    func body(content: Content) -> some View {
        let offset = Double(index) - position
        let amount = min(1, abs(offset))
        content
            .rotation3DEffect(.degrees(depth ? -offset * 32 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
            .scaleEffect(1 - amount * 0.06)
            .blur(radius: depth && amount > 0.01 ? amount * 5 : 0)
            .opacity(1 - amount * 0.9)
            .offset(x: CGFloat(offset) * spacing)
            .allowsHitTesting(abs(offset) < 0.5)
            .zIndex(1 - amount)
    }
}

// MARK: - Card

private struct MediaCard: View {
    @Environment(NotchViewModel.self) var vm
    let item: MediaItem
    let depth: Bool

    @State var tilt = CGSize.zero
    @State var shine = UnitPoint(x: 0.3, y: 0.2)
    @State var appeared = false
    @State var opened = false

    var body: some View {
        HStack(spacing: 14) {
            artwork
            meta
        }
        .onAppear {
            if depth {
                withAnimation(.spring(response: 0.85, dampingFraction: 0.68).delay(0.1)) { appeared = true }
            } else {
                appeared = true
            }
        }
    }

    // MARK: Artwork

    private var artSize: CGSize { item.isVideo ? CGSize(width: 150, height: 84) : CGSize(width: 112, height: 112) }
    private var artRadius: CGFloat { item.isVideo ? 13 : 18 }

    private var artwork: some View {
        let size = artSize
        let shape = RoundedRectangle(cornerRadius: artRadius, style: .continuous)
        return ZStack {
            // Цветное свечение из заранее размытой обложки — без размытия на лету.
            if let backdrop = item.backdrop {
                Image(nsImage: backdrop)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width * 0.92, height: size.height * 0.92)
                    .clipShape(shape)
                    .blur(radius: 14)
                    .opacity(item.isPlaying ? 0.75 : 0.25)
                    .offset(y: 10)
            }
            ZStack {
                if let image = item.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: item.isVideo ? "play.rectangle.fill" : "music.note")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                if item.isVideo { videoOverlay }
                RadialGradient(colors: [.white.opacity(0.35), .clear], center: shine, startRadius: 0, endRadius: size.width * 0.8)
                    .blendMode(.softLight)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
            .rotation3DEffect(.degrees(depth ? Double(tilt.width) * 22 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(depth ? Double(-tilt.height) * 22 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .scaleEffect(item.isPlaying || item.isVideo ? 1 : 0.92)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: item.isPlaying)
        }
        .frame(width: size.width, height: size.height)
        .rotation3DEffect(.degrees(appeared ? 0 : -38), axis: (x: 0.35, y: 1, z: 0), perspective: 0.55)
        .scaleEffect(appeared ? 1 : 0.82)
        .opacity(appeared ? 1 : 0)
        .contentShape(shape)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    tilt = CGSize(width: point.x / size.width - 0.5, height: point.y / size.height - 0.5)
                    shine = UnitPoint(x: point.x / size.width, y: point.y / size.height)
                }
            case .ended:
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    tilt = .zero
                    shine = UnitPoint(x: 0.3, y: 0.2)
                }
            }
        }
        .onTapGesture { vm.nowPlaying.open(item) }
        .help("Открыть \(item.sourceLabel)")
    }

    private var videoOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let fraction = item.duration > 0 ? min(max(item.position(at: context.date) / item.duration, 0), 1) : 0
            ZStack {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                    .scaleEffect(item.isPlaying ? 0.5 : 1)
                    .opacity(item.isPlaying ? 0 : 1)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: item.isPlaying)
                if item.duration > 0 {
                    Text(TimerService.format(item.duration))
                        .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.6)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                }
                GeometryReader { geo in
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.25))
                            Rectangle().fill(Color(red: 1, green: 0.23, blue: 0.19)).frame(width: geo.size.width * fraction)
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
    }

    // MARK: Meta

    private var meta: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let icon = item.sourceIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(item.sourceLabel)
                    .lineLimit(1)
                    .foregroundStyle(Theme.secondaryText)
                HStack(spacing: 4) {
                    Circle()
                        .fill(item.isPlaying ? Theme.liveGreen : Color.white.opacity(0.45))
                        .frame(width: 5, height: 5)
                        .shadow(color: item.isPlaying ? Theme.liveGreen : .clear, radius: 3)
                    Text(item.isPlaying ? "Играет" : "Пауза")
                        .foregroundStyle(item.isPlaying ? Theme.liveGreen : Theme.tertiaryText)
                        .contentTransition(.opacity)
                }
                .fixedSize()
            }
            .font(.system(size: 11, weight: .semibold))

            HStack(spacing: 9) {
                Text(item.title)
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.4)
                    .lineLimit(1)
                if item.isPlaying {
                    EqualizerView(color: item.accent, isPlaying: true, animated: !vm.lowPower)
                        .frame(width: 20, height: 12)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.top, 3)

            Text(item.subtitle.isEmpty ? " " : item.subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)

            ProgressRow(item: item)
                .padding(.top, 9)

            controls
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.content, value: item.isPlaying)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            controlButton(item.isVideo ? "gobackward.10" : "backward.fill", help: item.isVideo ? "Назад на 10 секунд" : "Предыдущий трек") {
                vm.nowPlaying.skip(item, forward: false)
            }
            Button {
                vm.nowPlaying.toggle(item)
            } label: {
                Image(systemName: item.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 42, height: 42)
                    .glass(21)
            }
            .buttonStyle(PressableButtonStyle(scale: 0.84))
            .help(item.isPlaying ? "Пауза" : "Играть")
            controlButton(item.isVideo ? "goforward.10" : "forward.fill", help: item.isVideo ? "Вперёд на 10 секунд" : "Следующий трек") {
                vm.nowPlaying.skip(item, forward: true)
            }
            Spacer(minLength: 0)
            Button {
                vm.nowPlaying.open(item)
                withAnimation(Theme.bouncy) { opened = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(Theme.content) { opened = false }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: opened ? "checkmark" : "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(opened ? "Открыто" : "Открыть")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(opened ? Theme.liveGreen : .white)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .glass(14)
            }
            .buttonStyle(PressableButtonStyle(scale: 0.92))
            .help(item.isVideo ? "Перейти к вкладке с видео" : "Открыть плеер")
        }
    }

    private func controlButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.8))
        .help(help)
    }
}

private struct ProgressRow: View {
    let item: MediaItem
    @Environment(NotchViewModel.self) var vm
    @State var dragFraction: Double?
    @State var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = max(item.duration, 0)
            let position = item.position(at: context.date)
            let fraction = dragFraction ?? (duration > 0 ? min(max(position / duration, 0), 1) : 0)
            let active = hovering || dragFraction != nil

            HStack(spacing: 8) {
                Text(TimerService.format(fraction * duration))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule()
                            .fill(LinearGradient(colors: [.white.opacity(0.75), .white], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(active ? 8 : 5, geo.size.width * fraction))
                            .shadow(color: .white.opacity(0.4), radius: 5)
                            .animation(dragFraction == nil ? .linear(duration: 1) : nil, value: fraction)
                    }
                    .frame(height: active ? 8 : 5)
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
                                vm.nowPlaying.seek(item, to: target * duration)
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 12)
                Text("−" + TimerService.format(max(0, duration - fraction * duration)))
            }
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.tertiaryText)
            .opacity(duration > 0 ? 1 : 0)
        }
        .onHover { inside in
            withAnimation(Theme.hover) { hovering = inside }
        }
    }
}

// MARK: - Empty states

/// Плеер, который не сообщает название трека (Яндекс Музыка без системного «Что играет»): только управление.
private struct ExternalPlayerView: View {
    let player: NowPlayingService
    let external: ExternalPlayer

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                if let icon = external.icon {
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                }
            }
            .frame(width: 112, height: 112)
            .glass(18)
            .onTapGesture { player.openSourceApp() }

            VStack(alignment: .leading, spacing: 5) {
                Text(external.name)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                Text(player.canControlAnyPlayer
                     ? "Название трека это приложение не сообщает, но кнопки работают."
                     : "Разреши «Универсальный доступ», чтобы переключать треки из чёлки.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if player.canControlAnyPlayer {
                    HStack(spacing: 10) {
                        roundButton("backward.fill") { player.previous() }
                        roundButton("playpause.fill") { player.togglePlayPause() }
                        roundButton("forward.fill") { player.next() }
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

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .glass(19)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private struct EmptyMusicView: View {
    @Environment(NotchViewModel.self) var vm
    @AppStorage(Pref.browserMusic) var browserMusic = false

    var body: some View {
        let player = vm.nowPlaying
        HStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 112, height: 112)
                .glass(18)
            VStack(alignment: .leading, spacing: 6) {
                Text("Ничего не играет")
                    .font(.system(size: 18, weight: .semibold))
                Text("Включи музыку или видео — всё, что играет или стоит на паузе, появится здесь.")
                    .font(.system(size: 12))
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
                        CapsuleButton(title: "Браузер", systemImage: "globe") { browserMusic = true }
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
    @AppStorage("timerPresetMinutes") var preset = 5

    private static let presets = [1, 5, 15, 25]

    var body: some View {
        let timer = vm.timer
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Таймер").sectionLabelStyle()
                Spacer()
                if timer.isActive {
                    Text("\(Int((timer.total / 60).rounded())) мин").sectionLabelStyle()
                        .transition(.opacity)
                }
            }

            Text(timer.isActive ? timer.remainingText : TimerService.format(Double(preset * 60)))
                .font(.system(size: 34, weight: timer.isActive ? .regular : .light).monospacedDigit())
                .tracking(-0.5)
                .foregroundStyle(timer.isActive ? Theme.orange : .white)
                .contentTransition(.numericText(countsDown: timer.isActive))
                .animation(Theme.micro, value: timer.isActive ? timer.remainingText : "\(preset)")

            Spacer(minLength: 0)

            if timer.isActive {
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
                    .transition(.opacity)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button {
                        withAnimation(Theme.content) { timer.stop() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.92))
                    .help("Отменить")
                    Button {
                        timer.toggle()
                    } label: {
                        Image(systemName: timer.state == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 12, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(Theme.orange)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(Capsule().fill(Theme.orange.opacity(0.24)))
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.92))
                    .help(timer.state == .paused ? "Продолжить" : "Пауза")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 5) {
                    ForEach(Self.presets, id: \.self) { minutes in
                        Button {
                            withAnimation(Theme.micro) { preset = minutes }
                        } label: {
                            Text("\(minutes)")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(preset == minutes ? Theme.orange : .white)
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .background(Capsule().fill(preset == minutes ? Theme.orange.opacity(0.25) : Color.white.opacity(0.1)))
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.88))
                    }
                }
                .transition(.opacity)
                Spacer(minLength: 0)
                Button {
                    withAnimation(Theme.content) { timer.start(minutes: preset) }
                } label: {
                    Text("Старт")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.orange)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(Capsule().fill(Theme.orange.opacity(0.24)))
                }
                .buttonStyle(PressableButtonStyle(scale: 0.94))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(Theme.cardRadius)
        .animation(Theme.content, value: timer.isActive)
    }
}
