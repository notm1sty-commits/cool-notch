import SwiftUI

struct NotesView: View {
    @AppStorage(Pref.notesText) var text = ""
    @FocusState var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 13, design: .rounded))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
            if text.isEmpty {
                Text("Быстрая заметка… Сохраняется сама.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(focused ? 0.09 : 0.05))
        )
        .overlay(alignment: .bottomTrailing) {
            if !text.isEmpty {
                HStack(spacing: 4) {
                    Text("\(text.count) симв.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                    IconButton(systemName: "doc.on.doc", size: 9, help: "Скопировать заметку") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    IconButton(systemName: "trash", size: 9, help: "Очистить") { text = "" }
                }
                .padding(6)
            }
        }
    }
}
