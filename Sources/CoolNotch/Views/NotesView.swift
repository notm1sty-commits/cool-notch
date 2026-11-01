import SwiftUI
import UniformTypeIdentifiers

/// Быстрые заметки: пишешь внизу, отправляешь — появляется в списке.
/// «Изменить» включает перетаскивание и удаление.
struct NotesView: View {
    @Environment(NotchViewModel.self) var vm
    @State var draft = ""
    @State var editing = false
    @State var copiedID: UUID?
    @State var dragging: NotesStore.Note?
    @FocusState var composerFocused: Bool

    var body: some View {
        let store = vm.notes
        VStack(spacing: 8) {
            HStack {
                Text("Заметки").sectionLabelStyle()
                if !store.notes.isEmpty {
                    Text("\(store.notes.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                        .contentTransition(.numericText())
                }
                Spacer()
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
                if store.notes.isEmpty {
                    PlaceholderView(
                        icon: "note.text",
                        title: "Пока пусто",
                        subtitle: "Напиши заметку внизу и нажми ↑ или Enter",
                        layout: .horizontal
                    )
                    // Поле ввода снизу визуально «тянет» вниз — поднимаем, чтобы выглядело по центру.
                    .padding(.bottom, 16)
                    .transition(.opacity)
                } else {
                    list(store: store)
                }
            }
            .frame(maxHeight: .infinity)

            composer(store: store)
        }
        .animation(Theme.content, value: store.notes)
        .onChange(of: editing) { _, _ in dragging = nil }
    }

    /// Свой список вместо системного: тот добавлял поля слева и справа, и карточки
    /// были уже остальных элементов. Порядок меняется перетаскиванием в режиме «Изменить».
    private func list(store: NotesStore) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 6) {
                ForEach(store.notes) { note in
                    NoteRow(note: note, editing: editing, copied: copiedID == note.id) {
                        store.copy(note)
                        withAnimation(Theme.micro) { copiedID = note.id }
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.4))
                            if copiedID == note.id { withAnimation(Theme.micro) { copiedID = nil } }
                        }
                    } onDelete: {
                        withAnimation(Theme.content) { store.remove(note) }
                    }
                    .opacity(editing && dragging?.id == note.id ? 0.4 : 1)
                    .onDrag {
                        // В режиме «Изменить» тянем, чтобы поменять порядок, иначе — сам текст заметки
                        // можно перетащить в любое приложение.
                        if editing { dragging = note }
                        return NSItemProvider(object: note.text as NSString)
                    }
                    .onDrop(of: [UTType.text], delegate: NoteDropDelegate(target: note, store: store, dragging: $dragging))
                }
            }
            .frame(maxWidth: .infinity)
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
        .glass(14, highlighted: hovering && !editing)
        .contentShape(Rectangle())
        .onTapGesture { if !editing { onCopy() } }
        .onHover { inside in withAnimation(Theme.micro) { hovering = inside } }
        .contextMenu {
            Button("Скопировать", action: onCopy)
            Button("Удалить", role: .destructive, action: onDelete)
        }
    }
}

/// Перестановка заметок перетаскиванием: карточка «раздвигает» соседей прямо во время движения.
private struct NoteDropDelegate: DropDelegate {
    let target: NotesStore.Note
    let store: NotesStore
    @Binding var dragging: NotesStore.Note?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != target.id,
              let from = store.notes.firstIndex(where: { $0.id == dragging.id }),
              let to = store.notes.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(Theme.content) {
            store.move(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
