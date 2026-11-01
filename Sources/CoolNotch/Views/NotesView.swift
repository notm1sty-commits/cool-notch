import SwiftUI

/// Быстрые заметки: пишешь внизу, отправляешь — появляется в списке.
/// «Изменить» включает перетаскивание и удаление.
struct NotesView: View {
    @Environment(NotchViewModel.self) var vm
    @State var draft = ""
    @State var editing = false
    @State var copiedID: UUID?
    /// Перестановка в режиме «Изменить»: заметка едет за курсором, соседи раздвигаются,
    /// а порядок записывается, когда отпускаешь, — где бы ни отпустил.
    @State var drag: NoteDrag?
    /// Где стоит каждая карточка (в координатах списка) — чтобы понять, куда её тянут.
    @State var rowFrames: [UUID: CGRect] = [:]
    @FocusState var composerFocused: Bool

    struct NoteDrag: Equatable {
        let id: UUID
        let startIndex: Int
        var translation: CGFloat
        var targetIndex: Int
    }

    private static let rowSpacing: CGFloat = 6

    var body: some View {
        let store = vm.notes
        VStack(spacing: 8) {
            HStack {
                Text("Быстрые заметки").sectionLabelStyle()
                if !store.notes.isEmpty {
                    Text("\(store.notes.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                        .contentTransition(.numericText())
                }
                Spacer()
                // Как в «Копиях»: в режиме «Изменить» — «Очистить всё».
                if editing, !store.notes.isEmpty {
                    Button("Очистить всё") {
                        withAnimation(Theme.content) {
                            store.removeAll()
                            editing = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .glass(11)
                    .transition(.opacity)
                }
                if !store.notes.isEmpty {
                    Button(editing ? "Готово" : "Изменить") {
                        withAnimation(Theme.content) { editing.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(editing ? Theme.orange : .white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .glass(11)
                    .transition(.opacity)
                }
            }
            .frame(height: 24)

            ZStack {
                if !store.notes.isEmpty {
                    list(store: store)
                }
            }
            .frame(maxHeight: .infinity)

            composer(store: store)
        }
        // Пустое состояние — по центру всей панели, на той же высоте, что на полке и в буфере,
        // чтобы при перелистывании разделов глаз не прыгал.
        .overlay {
            if store.notes.isEmpty {
                PlaceholderView(
                    icon: "note.text",
                    title: "Пока пусто",
                    subtitle: "Напиши заметку внизу и нажми ↑ или Enter",
                    layout: .horizontal
                )
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(Theme.content, value: store.notes)
        .onChange(of: editing) { _, _ in drag = nil }
    }

    /// Свой список вместо системного: тот добавлял поля слева и справа, и карточки
    /// были уже остальных элементов. Порядок меняется перетаскиванием в режиме «Изменить».
    private func list(store: NotesStore) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: Self.rowSpacing) {
                ForEach(Array(store.notes.enumerated()), id: \.element.id) { index, note in
                    let isDragged = drag?.id == note.id
                    NoteRow(note: note, editing: editing, copied: copiedID == note.id, lifted: isDragged) {
                        store.copy(note)
                        withAnimation(Theme.micro) { copiedID = note.id }
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.4))
                            if copiedID == note.id { withAnimation(Theme.micro) { copiedID = nil } }
                        }
                    } onDelete: {
                        withAnimation(Theme.content) { store.remove(note) }
                    }
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(key: NoteFramesKey.self, value: [note.id: geo.frame(in: .named("notes"))])
                        }
                    }
                    .offset(y: isDragged ? (drag?.translation ?? 0) : shift(for: index, note: note))
                    .zIndex(isDragged ? 1 : 0)
                    // Сдвиг соседей — пружиной, сама карточка идёт за курсором без задержки.
                    .animation(isDragged ? nil : Theme.content, value: drag?.targetIndex)
                    .modifier(NoteDragModifier(
                        editing: editing,
                        text: note.text,
                        onChanged: { translation in dragChanged(note: note, index: index, translation: translation, store: store) },
                        onEnded: { dragEnded(store: store) }
                    ))
                }
            }
            .coordinateSpace(name: "notes")
            .onPreferenceChange(NoteFramesKey.self) { rowFrames = $0 }
            .frame(maxWidth: .infinity)
        }
    }

    /// Насколько сдвинуть соседа, чтобы освободить место перетаскиваемой карточке.
    private func shift(for index: Int, note: NotesStore.Note) -> CGFloat {
        guard let drag, let height = rowFrames[drag.id]?.height else { return 0 }
        let gap = height + Self.rowSpacing
        if drag.startIndex < drag.targetIndex, index > drag.startIndex, index <= drag.targetIndex { return -gap }
        if drag.targetIndex < drag.startIndex, index >= drag.targetIndex, index < drag.startIndex { return gap }
        return 0
    }

    private func dragChanged(note: NotesStore.Note, index: Int, translation: CGFloat, store: NotesStore) {
        var current = drag ?? NoteDrag(id: note.id, startIndex: index, translation: 0, targetIndex: index)
        guard current.id == note.id else { return }
        current.translation = translation
        // Куда попадает середина карточки — столько соседей она уже «обогнала».
        if let frame = rowFrames[note.id] {
            let center = frame.midY + translation
            var target = 0
            for otherNote in store.notes where otherNote.id != note.id {
                guard let otherFrame = rowFrames[otherNote.id] else { continue }
                if otherFrame.midY < center { target += 1 }
            }
            current.targetIndex = min(max(target, 0), store.notes.count - 1)
        }
        if drag != current { drag = current }
    }

    /// Отпустили — записываем новый порядок. Соседи уже стоят на своих местах, а сама карточка
    /// мягко «садится» в своё место. Отпустить можно где угодно: состояние всегда сбрасывается.
    private func dragEnded(store: NotesStore) {
        guard let finished = drag else { return }
        withAnimation(Theme.content) {
            if finished.targetIndex != finished.startIndex {
                let destination = finished.targetIndex > finished.startIndex ? finished.targetIndex + 1 : finished.targetIndex
                store.move(from: IndexSet(integer: finished.startIndex), to: destination)
            }
            drag = nil
        }
    }

    private func composer(store: NotesStore) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Новая заметка…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...3)
                .focused($composerFocused)
                .onSubmit { send(store) }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glass(16, highlighted: composerFocused)
                .onChange(of: composerFocused) { _, focused in
                    if focused { vm.beginTyping() } else { vm.endTyping() }
                }
                .simultaneousGesture(TapGesture().onEnded {
                    vm.beginTyping()
                    composerFocused = true
                })

            Button {
                send(store)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.white.opacity(0.4) : Color.black)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.white.opacity(0.12) : Theme.orange))
            }
            .buttonStyle(PressableButtonStyle(scale: 0.85))
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Отправить (Enter)")
            .animation(Theme.micro, value: draft.isEmpty)
        }
    }

    private func send(_ store: NotesStore) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
            if store.add(draft) { draft = "" }
        }
        composerFocused = true
    }
}

private struct NoteRow: View {
    let note: NotesStore.Note
    let editing: Bool
    let copied: Bool
    /// Карточку сейчас тянут — она чуть приподнята и с тенью.
    var lifted = false
    var onCopy: () -> Void
    var onDelete: () -> Void

    @State var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if editing {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.red)
                }
                .buttonStyle(PressableButtonStyle())
                .transition(.scale.combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(note.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(copied ? "Скопировано" : note.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9.5))
                    .foregroundStyle(copied ? Theme.liveGreen : Theme.tertiaryText)
            }
            if editing {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .transition(.opacity)
                    .help("Перетащи, чтобы поменять порядок")
            } else if hovering {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? Theme.liveGreen : Theme.secondaryText)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glass(14, highlighted: (hovering && !editing) || lifted)
        .scaleEffect(lifted ? 1.02 : 1)
        .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: lifted ? 12 : 0, y: lifted ? 6 : 0)
        .animation(Theme.micro, value: lifted)
        .contentShape(Rectangle())
        .onTapGesture { if !editing { onCopy() } }
        .onHover { inside in withAnimation(Theme.micro) { hovering = inside } }
        .contextMenu {
            Button("Скопировать", action: onCopy)
            Button("Удалить", role: .destructive, action: onDelete)
        }
    }
}

/// В режиме «Изменить» карточку тянут мышью внутри списка (своё перетаскивание, без системного:
/// никаких «залипших» полупрозрачных карточек, если отпустить мимо). Вне режима заметку можно
/// перетащить в любое приложение как текст.
private struct NoteDragModifier: ViewModifier {
    let editing: Bool
    let text: String
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    func body(content: Content) -> some View {
        if editing {
            content.gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("notes"))
                    .onChanged { value in onChanged(value.translation.height) }
                    .onEnded { _ in onEnded() }
            )
        } else {
            content.onDrag { NSItemProvider(object: text as NSString) }
        }
    }
}

private struct NoteFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
