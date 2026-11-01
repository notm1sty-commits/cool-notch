import SwiftUI

struct NotesView: View {
    @AppStorage(Pref.notesText) var text = ""
    @FocusState var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
            if text.isEmpty {
                Text("Быстрая заметка… Сохраняется сама.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(12)
        .surface(highlighted: focused)
        .overlay(alignment: .bottomTrailing) {
            if !text.isEmpty {
                HStack(spacing: 2) {
                    Text("\(text.count)")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.trailing, 4)
                    IconButton(systemName: "doc.on.doc", size: 9, help: "Скопировать заметку") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    IconButton(systemName: "trash", size: 9, help: "Очистить") {
                        withAnimation(Theme.content) { text = "" }
                    }
                }
                .padding(6)
                .transition(.opacity)
            }
        }
        .animation(Theme.micro, value: focused)
        .animation(Theme.content, value: text.isEmpty)
    }
}
