import SwiftUI

struct ClipboardView: View {
    @Environment(NotchViewModel.self) var vm
    @State var copiedID: UUID?

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        let clipboard = vm.clipboard
        ZStack {
            if !clipboard.isEnabled {
                PlaceholderView(
                    icon: "doc.on.clipboard",
                    title: "История буфера выключена",
                    subtitle: "Включить можно в настройках"
                )
            } else if clipboard.entries.isEmpty {
                PlaceholderView(
                    icon: "doc.on.clipboard",
                    title: "Скопируй любой текст",
                    subtitle: "Последние 30 копирований появятся здесь. Пароли не сохраняются."
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(clipboard.entries) { entry in
                            ClipRow(entry: entry, copied: copiedID == entry.id) {
                                clipboard.copy(entry)
                                withAnimation(Theme.micro) { copiedID = clipboard.entries.first?.id }
                                if Pref.bool(Pref.haptics) {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                                }
                            } onDelete: {
                                withAnimation(Theme.content) { clipboard.remove(entry) }
                            }
                        }
                    }
                }
            }
        }
        .animation(Theme.content, value: clipboard.entries.map(\.id))
    }
}

private struct ClipRow: View {
    let entry: ClipboardService.Entry
    var copied: Bool
    var onCopy: () -> Void
    var onDelete: () -> Void

    @State var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 9) {
                Image(systemName: copied ? "checkmark" : icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? Color.green : Theme.tertiaryText)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preview)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(copied ? "Скопировано" : subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(copied ? Color.green.opacity(0.8) : Theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glass(14, highlighted: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .onHover { value in
            withAnimation(Theme.micro) { hovering = value }
        }
        .help(String(entry.text.prefix(500)))
        .contextMenu {
            Button("Скопировать", action: onCopy)
            Button("Удалить из истории", role: .destructive, action: onDelete)
        }
    }

    private var preview: String {
        entry.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
    }

    private var icon: String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return "link" }
        if text.contains("@"), !text.contains(" "), text.count < 80 { return "at" }
        if Double(text.replacingOccurrences(of: " ", with: "")) != nil { return "number" }
        return "text.alignleft"
    }

    private var subtitle: String {
        let time = entry.date.formatted(date: .omitted, time: .shortened)
        if let app = entry.appName { return "\(app) · \(time)" }
        return time
    }
}
