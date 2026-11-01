import SwiftUI

struct HomeView: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        GeometryReader { geo in
            content(cardHeight: max(100, geo.size.height - 14))
        }
    }

    private func content(cardHeight: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 14) {
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

            // Таймер без своей плашки: тонкий разделитель и содержимое по тем же линиям, что и плеер.
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: cardHeight - 20)
                .frame(height: cardHeight)

            TimerCard()
                .frame(width: 156, height: cardHeight)
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
    /// Порядок карточек замораживается, пока чёлка открыта: нажал паузу — карточка
    /// остаётся на месте, а не уезжает в конец списка.
    @State var order: [PlayerSource] = []

    var body: some View {
        let items = ordered(vm.nowPlaying.items)
        let depth = vm.fx3D && !reduceMotion && !vm.lowPower
        GeometryReader { geo in
            let cardWidth = max(220, geo.size.width - 100)
            let cardHeight = max(100, geo.size.height - 14)
            VStack(spacing: 4) {
                ZStack {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        MediaCard(item: item, depth: depth)
                            .frame(width: cardWidth, height: cardHeight)
                            .modifier(DeckCardEffect(position: position, index: index, spacing: cardWidth * 1.04, depth: depth))
                    }
                }
                .frame(width: geo.size.width, height: cardHeight)
                .mask {
                    // Соседние карточки исчезают у краёв, а не наезжают на таймер.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.05),
                            .init(color: .black, location: 0.95),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .padding(.vertical, -40)
                }
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
        .onAppear {
            order = vm.nowPlaying.items.map(\.id)
            position = Double(vm.deckIndex)
        }
        .onChange(of: vm.deckIndex) { _, newValue in
            withAnimation(Theme.deck) { position = Double(newValue) }
        }
        .onChange(of: vm.nowPlaying.items.map(\.id)) { oldIDs, ids in
            // Выбранная карточка остаётся выбранной, даже если источники поменялись местами.
            let before = Self.merge(order, oldIDs)
            let selected = before.indices.contains(vm.deckIndex) ? before[vm.deckIndex] : nil
            order = Self.merge(order, ids)
            let index = selected.flatMap { order.firstIndex(of: $0) } ?? min(vm.deckIndex, max(order.count - 1, 0))
            vm.selectDeck(index)
            withAnimation(Theme.deck) { position = Double(index) }
        }
    }

    private static func merge(_ order: [PlayerSource], _ ids: [PlayerSource]) -> [PlayerSource] {
        let kept = order.filter { ids.contains($0) }
        return kept + ids.filter { !kept.contains($0) }
    }

    private func ordered(_ items: [MediaItem]) -> [MediaItem] {
        guard !order.isEmpty else { return items }
        var result = order.compactMap { id in items.first { $0.id == id } }
        for item in items where !order.contains(item.id) { result.append(item) }
        return result
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
            .rotation3DEffect(.degrees(depth ? -offset * 14 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .scaleEffect(1 - amount * 0.05)
            .opacity(1 - amount)
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
    @State var appeared = false
    @State var opened = false

    var body: some View {
        HStack(spacing: 14) {
            artwork
            meta
        }
        .onAppear {
            if depth {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9).delay(0.08)) { appeared = true }
            } else {
                appeared = true
            }
        }
    }

    // MARK: Artwork

    private var artSize: CGSize { item.isVideo ? CGSize(width: 140, height: 79) : CGSize(width: 112, height: 112) }
    private var artRadius: CGFloat { item.isVideo ? 13 : 18 }

    private var artwork: some View {
        let size = artSize
        let shape = RoundedRectangle(cornerRadius: artRadius, style: .continuous)
        return ZStack {
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
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
            .rotation3DEffect(.degrees(depth ? Double(tilt.width) * 8 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(depth ? Double(-tilt.height) * 8 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .scaleEffect(item.isPlaying || item.isVideo ? 1 : 0.92)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: item.isPlaying)
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(appeared ? 1 : 0.96)
        .opacity(appeared ? 1 : 0)
        .contentShape(shape)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    tilt = CGSize(width: point.x / size.width - 0.5, height: point.y / size.height - 0.5)
                }
            case .ended:
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    tilt = .zero
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
                // «Играет» — цветом обложки, как эквалайзер.
                let tint = Color(nsColor: item.accent)
                HStack(spacing: 4) {
                    Circle()
                        .fill(item.isPlaying ? tint : Color.white.opacity(0.45))
                        .frame(width: 5, height: 5)
                    Text(item.isPlaying ? "Играет" : "Пауза")
                        .foregroundStyle(item.isPlaying ? tint : Theme.tertiaryText)
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
                    EqualizerView(color: item.accent, isPlaying: true, lowPower: vm.lowPower)
                        .frame(width: 20, height: 12)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.top, 3)

            if let issue = vm.nowPlaying.controlIssues[item.id] {
                ControlIssueRow(issue: issue) { vm.nowPlaying.enableBrowserJavaScript(for: item) }
                    .transition(.opacity)
            } else {
                Text(item.subtitle.isEmpty ? " " : item.subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            ProgressRow(item: item)
                .padding(.top, 9)

            controls
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.content, value: item.isPlaying)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            controlButton(item.isVideo ? "gobackward.10" : "backward.fill", help: item.isVideo ? "Назад на 10 секунд" : "Предыдущий трек") {
                vm.nowPlaying.skip(item, forward: false)
            }
            Button {
                vm.nowPlaying.toggle(item)
            } label: {
                Image(systemName: item.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .glass(18)
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
                        .lineLimit(1)
                }
                .fixedSize()
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.8))
        .help(help)
    }
}

/// Почему кнопка не сработала — одной строкой вместо исполнителя, с кнопкой «Включить».
private struct ControlIssueRow: View {
    let issue: NowPlayingService.ControlIssue
    var enable: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch issue {
            case .browserJavaScript:
                message("Чтобы управлять видео отсюда, нужен JavaScript в браузере")
                Button("Включить", action: enable)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.white))
                    .fixedSize()
            case .enablingJavaScript:
                ProgressView().controlSize(.mini)
                message("Включаю в меню браузера…")
            case .browserJavaScriptManual:
                message("В меню браузера: Вид → Разработчикам → Разрешить JavaScript из Apple Events")
            case .notCurrent:
                message("macOS сейчас управляет другим плеером — нажми ⏯ в самом приложении")
            }
        }
        .frame(height: 18)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .help(text)
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
                            .fill(Color.white)
                            .frame(width: max(active ? 8 : 5, geo.size.width * fraction))
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
    @AppStorage("timerPresetSeconds") var preset = 300
    @State var editing = false
    @State var draft = ""
    @FocusState var fieldFocused: Bool

    private static let presets = [5, 15, 25, 45]

    var body: some View {
        let timer = vm.timer
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Таймер").sectionLabelStyle()
                Spacer()
                if timer.isActive {
                    Text(TimerService.durationText(timer.total)).sectionLabelStyle()
                        .transition(.opacity)
                }
            }

            if timer.isActive {
                Text(timer.remainingText)
                    .font(.system(size: 32, weight: .regular).monospacedDigit())
                    .tracking(-0.5)
                    .foregroundStyle(Theme.orange)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Theme.micro, value: timer.remainingText)
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
                HStack(spacing: 8) {
                    pill(systemName: "xmark", tint: .white, help: "Отменить") {
                        withAnimation(Theme.content) { timer.stop() }
                    }
                    pill(systemName: timer.state == .paused ? "play.fill" : "pause.fill", tint: Theme.orange, help: "Пауза") {
                        timer.toggle()
                    }
                }
            } else {
                HStack(spacing: 4) {
                    stepButton("minus") { adjust(-60) }
                    timeField
                        .frame(maxWidth: .infinity)
                    stepButton("plus") { adjust(60) }
                }
                HStack(spacing: 4) {
                    ForEach(Self.presets, id: \.self) { minutes in
                        Button {
                            withAnimation(Theme.micro) { preset = minutes * 60 }
                        } label: {
                            Text("\(minutes)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(preset == minutes * 60 ? Theme.orange : .white)
                                .frame(maxWidth: .infinity, minHeight: 22)
                                .background(Capsule().fill(preset == minutes * 60 ? Theme.orange.opacity(0.24) : Color.white.opacity(0.1)))
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.88))
                    }
                }
                // Сразу под пресетами, а не прижата к низу — без пустого провала посередине.
                Button {
                    commitDraft()
                    withAnimation(Theme.content) { timer.start(seconds: TimeInterval(preset)) }
                } label: {
                    Text("Старт")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.orange)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(Capsule().fill(Theme.orange.opacity(0.22)))
                }
                .buttonStyle(PressableButtonStyle(scale: 0.94))
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Theme.content, value: timer.isActive)
    }

    /// Цифры: клик — ввод с клавиатуры («90» — 90 минут, «1:30» — 1 мин 30 с, «1:30:00» — 1,5 часа).
    @ViewBuilder
    private var timeField: some View {
        if editing {
            TextField("мм или мм:сс", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .light).monospacedDigit())
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
                .font(.system(size: 28, weight: .light).monospacedDigit())
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
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .glass(12)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.85))
    }

    private func pill(systemName: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(Capsule().fill(tint == .white ? Color.white.opacity(0.14) : tint.opacity(0.24)))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .help(help)
    }
}
