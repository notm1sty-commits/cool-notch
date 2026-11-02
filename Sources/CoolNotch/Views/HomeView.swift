import SwiftUI

struct HomeView: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        content(cardHeight: Theme.playerHeight)
            .frame(maxHeight: .infinity, alignment: .top)
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
            .frame(maxWidth: .infinity)
            .animation(Theme.content, value: vm.nowPlaying.items.isEmpty)
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
            let cardHeight = Theme.playerHeight
            VStack(spacing: 7) {
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
                    HStack(spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Capsule()
                                .fill(Color.white.opacity(index == vm.deckIndex ? 1 : 0.3))
                                .frame(width: index == vm.deckIndex ? 13 : 4.5, height: 4.5)
                                // Попасть по маленькой точке легче: зона нажатия больше самой точки.
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .onTapGesture { vm.selectDeck(index) }
                                .help(item.sourceLabel)
                        }
                    }
                    .frame(height: 6)
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
    /// Прежняя обложка: новый трек часто приходит без неё, и она догружается чуть позже.
    /// Пока ждём, показываем прежнюю приглушённой, а не серую заглушку.
    @State var heldArtwork: NSImage?
    @State var holdTask: Task<Void, Never>?

    private var shownArtwork: NSImage? { item.artwork ?? heldArtwork }
    private var switchingNow: Bool { vm.nowPlaying.switching[item.id] != nil }
    private var direction: CGFloat { CGFloat(vm.nowPlaying.lastSkipDirection) }
    private var artworkLoading: Bool { switchingNow || (item.artwork == nil && heldArtwork != nil) }

    var body: some View {
        HStack(spacing: 14) {
            artwork
            meta
        }
        .frame(height: Theme.playerHeight)
        .onChange(of: item.artwork.map { ObjectIdentifier($0) }) { _, _ in holdArtwork() }
        .onAppear {
            heldArtwork = item.artwork
            if depth {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9).delay(0.08)) { appeared = true }
            } else {
                appeared = true
            }
        }
    }

    private func holdArtwork() {
        holdTask?.cancel()
        if let image = item.artwork {
            heldArtwork = image
            return
        }
        // Обложки так и нет — через полторы секунды честно показываем заглушку.
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.track) { heldArtwork = nil }
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
                if let image = shownArtwork {
                    // Своя «личность» у каждой картинки — новая обложка плавно проявляется поверх старой.
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .id(ObjectIdentifier(image))
                        .transition(.opacity.combined(with: .scale(scale: 1.06)))
                } else {
                    LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: item.isVideo ? "play.rectangle.fill" : "music.note")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                if item.isVideo { videoOverlay }
            }
            .frame(width: size.width, height: size.height)
            .brightness(artworkLoading ? -0.14 : 0)
            .saturation(artworkLoading ? 0.6 : 1)
            .animation(Theme.track, value: shownArtwork.map { ObjectIdentifier($0) })
            .animation(Theme.track, value: artworkLoading)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
            .rotation3DEffect(.degrees(depth ? Double(tilt.width) * 8 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(depth ? Double(-tilt.height) * 8 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .scaleEffect(item.isPlaying || item.isVideo ? 1 : 0.92)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: item.isPlaying)
            // Нажали «следующий» — обложка чуть «отходит», пока плеер не пришлёт новый трек.
            .scaleEffect(switchingNow ? 0.95 : 1)
            .animation(Theme.track, value: switchingNow)
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
        VStack(alignment: .leading, spacing: 0) {
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
                // Цвет «Играет» плавно перетекает вместе с эквалайзером при смене трека.
                .animation(.easeInOut(duration: 0.8), value: item.accent)
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(height: 16)

            HStack(spacing: 9) {
                // Новое название въезжает с той стороны, куда листали, старое уезжает в другую.
                ZStack(alignment: .leading) {
                    Text(item.title)
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(-0.4)
                        .lineLimit(1)
                        .id(item.title)
                        .transition(TrackSlide(direction: direction))
                }
                .modifier(SwitchingLook(active: switchingNow, direction: direction))
                if item.isPlaying {
                    EqualizerView(color: item.accent, isPlaying: true, lowPower: vm.lowPower)
                        .frame(width: 20, height: 12)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(height: 24)
            .padding(.top, 4)
            .animation(Theme.track, value: item.title)
            .animation(Theme.track, value: switchingNow)

            if let issue = vm.nowPlaying.controlIssues[item.id] {
                ControlIssueRow(issue: issue) { vm.nowPlaying.enableBrowserJavaScript(for: item) }
                    .frame(height: 18, alignment: .leading)
                    .transition(.opacity)
            } else {
                ZStack(alignment: .leading) {
                    Text(item.subtitle.isEmpty ? " " : item.subtitle)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .id(item.subtitle)
                        .transition(TrackSlide(direction: direction, distance: 12))
                }
                .frame(height: 18)
                .modifier(SwitchingLook(active: switchingNow, direction: direction))
                // Исполнитель — на долю мгновения позже названия: смена читается как одно движение.
                .animation(Theme.track.delay(0.03), value: item.subtitle)
                .animation(Theme.track, value: switchingNow)
            }

            ProgressRow(item: item)
                .frame(height: 14)
                .padding(.top, 8)

            controls
                .frame(height: 32)
                .padding(.top, 8)
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
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
                    .glass(16)
            }
            .buttonStyle(PressableButtonStyle(scale: 0.84))
            .help(item.isPlaying ? "Пауза" : "Играть")
            controlButton(item.isVideo ? "goforward.10" : "forward.fill", help: item.isVideo ? "Вперёд на 10 секунд" : "Следующий трек") {
                vm.nowPlaying.skip(item, forward: true)
            }
            if let mode = item.repeatMode {
                Button {
                    vm.nowPlaying.cycleRepeat(item)
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(mode == .off ? Color.white.opacity(0.4) : Color(nsColor: item.accent))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(mode == .off ? 0 : 0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.8))
                .help(mode.help)
                .animation(Theme.micro, value: mode)
                .transition(.opacity)
            }
            VolumeControl(volume: vm.volume, tint: Color(nsColor: item.accent))
                .padding(.leading, 10)
            Spacer(minLength: 8)
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

            Button {
                withAnimation(Theme.content) { vm.nowPlaying.dismiss(item) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.09)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.85))
            .padding(.leading, 4)
            .help("Убрать из чёлки — вернётся, когда снова заиграет")
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

/// Громкость Мака: значок (нажми — без звука) и тонкий ползунок. Тянуть можно за любую точку.
private struct VolumeControl: View {
    let volume: SystemVolume
    var tint: Color

    @State private var hovering = false
    @State private var dragging = false

    private var symbol: String {
        if volume.isMuted || volume.level < 0.01 { return "speaker.slash.fill" }
        if volume.level < 0.34 { return "speaker.wave.1.fill" }
        if volume.level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        if volume.isAvailable {
            HStack(spacing: 7) {
                Button {
                    volume.toggleMute()
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 20, height: 26, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.85))
                .help(volume.isMuted ? "Включить звук" : "Выключить звук")

                GeometryReader { geo in
                    let fraction = CGFloat(volume.isMuted ? 0 : volume.level)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule()
                            .fill(hovering || dragging ? tint : Color.white.opacity(0.85))
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                    .frame(height: hovering || dragging ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragging = true
                                volume.set(Float(min(max(value.location.x / geo.size.width, 0), 1)))
                            }
                            .onEnded { _ in dragging = false }
                    )
                }
                .frame(width: 84, height: 26)
                .onHover { inside in withAnimation(Theme.micro) { hovering = inside } }
                .animation(Theme.micro, value: hovering || dragging)
                .help("Громкость Мака: \(Int((volume.isMuted ? 0 : volume.level) * 100))%")
            }
        }
    }
}

/// Почему кнопка не сработала — одной строкой вместо исполнителя. Полный текст всплывает,
/// если задержать на ней курсор (обычные подсказки в окне чёлки macOS не показывает).
private struct ControlIssueRow: View {
    let issue: NowPlayingService.ControlIssue
    var enable: () -> Void

    @State private var hovering = false
    @State private var showBubble = false

    var body: some View {
        HStack(spacing: 6) {
            if issue == .enablingJavaScript {
                ProgressView().controlSize(.mini)
            }
            Text(short)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.orange)
                .lineLimit(1)
                .truncationMode(.tail)
            if let button {
                Button(button.title, action: button.action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.white))
                    .fixedSize()
            }
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    if hovering { withAnimation(Theme.micro) { showBubble = true } }
                }
            } else {
                withAnimation(Theme.micro) { showBubble = false }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showBubble {
                Text(full)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 250, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(white: 0.13))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                    )
                    .offset(y: -24)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                    .allowsHitTesting(false)
            }
        }
        .zIndex(10)
    }

    private var short: String {
        switch issue {
        case .browserJavaScript: return "Нужен JavaScript в браузере"
        case .enablingJavaScript: return "Включаю в меню браузера…"
        case .browserJavaScriptManual: return "Включи JavaScript в меню браузера"
        case .browserAutomation: return "Нет доступа к браузеру"
        case .noTab: return "Не нашёл вкладку с видео"
        case .failed: return "Браузер ответил ошибкой"
        case .notCurrent: return "Нажми ⏯ в самом приложении"
        }
    }

    private var full: String {
        switch issue {
        case .browserJavaScript:
            return "macOS управляет только «текущим» плеером. Чтобы запускать и перематывать видео из чёлки, когда играет другое, браузер должен разрешать JavaScript из Apple Events. «Включить» сделает это само."
        case .enablingJavaScript:
            return "Нажимаю пункт «Разрешить JavaScript из Apple Events» в меню браузера."
        case .browserJavaScriptManual:
            return "Не получилось нажать пункт меню автоматически. В браузере: «Вид» → «Разработчикам» → «Разрешить JavaScript из Apple Events» (в Safari — меню «Разработка»)."
        case .browserAutomation:
            return "macOS не разрешает Halo управлять этим браузером. «Настройки» откроет «Конфиденциальность» → «Автоматизация»: включи там браузер под Halo."
        case .noTab:
            return "Не нашёл открытую вкладку с этим видео. Если вкладку закрыли или перезагрузили — карточка обновится сама."
        case .failed(let message):
            return "Браузер ответил: \(message)"
        case .notCurrent:
            return "macOS отдаёт команды только «текущему» плееру, а у этого приложения нет своего управления. Нажми ⏯ в самом приложении — после этого им можно управлять из чёлки."
        }
    }

    private var button: (title: String, action: () -> Void)? {
        switch issue {
        case .browserJavaScript, .browserJavaScriptManual:
            return ("Включить", enable)
        case .browserAutomation:
            return ("Настройки", { Permissions.openPane("Privacy_Automation") })
        default:
            return nil
        }
    }
}

private struct ProgressRow: View {
    let item: MediaItem
    @Environment(NotchViewModel.self) var vm
    @State var dragFraction: Double?
    @State var hovering = false
    /// Позиция прыгнула (перемотка, новый трек) — сразу на место, а не медленным «доездом» за секунду.
    @State var snapUntil = Date.distantPast

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
                            .animation(
                                dragFraction != nil ? nil
                                    : context.date < snapUntil ? .snappy(duration: 0.22) : .linear(duration: 1),
                                value: fraction
                            )
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
        .onChange(of: item.elapsed) { _, _ in snapUntil = Date().addingTimeInterval(1.1) }
        .onChange(of: item.title) { _, _ in snapUntil = Date().addingTimeInterval(1.1) }
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
