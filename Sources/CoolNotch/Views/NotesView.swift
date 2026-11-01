import SwiftUI

/// Быстрые заметки: пишешь внизу, отправляешь — появляется в списке.
/// «Изменить» включает перетаскивание и удаление.
struct NotesView: View {
    @Environment(NotchViewModel.self) var vm
    @State var draft = ""
    @State var editing = false
    @State var copiedID: UUID?
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
                }
            }

            ZStack {
                if store.notes.isEmpty {
                    PlaceholderView(
                        icon: "note.text",
                        title: "Пока пусто",
                        subtitle: "Напиши заметку внизу и нажми ↑ или Enter"
                    )
                    .transition(.opacity)
                } else {
                    list(store: store)
                }
            }
            .frame(maxHeight: .infinity)

            composer(store: store)
        }
        .animation(Theme.content, value: store.notes)
    }

    private func list(store: NotesStore) -> some View {
        List {
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
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                .moveDisabled(!editing)
            }
            .onMove { source, destination in
                store.move(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .environment(\.defaultMinListRowHeight, 10)
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
