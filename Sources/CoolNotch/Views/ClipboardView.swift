import SwiftUI

struct ClipboardView: View {
    @Environment(NotchViewModel.self) var vm
    @State var copiedID: UUID?

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        let clipboard = vm.clipboard
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
                            copiedID = clipboard.entries.first?.id
                            if Pref.bool(Pref.haptics) {
                                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                            }
                        } onDelete: {
                            withAnimation(.snappy) { clipboard.remove(entry) }
                        }
                    }
                }
            }
        }
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
            HStack(spacing: 8) {
                Image(systemName: copied ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(copied ? Color.green : Color.white.opacity(0.5))
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(preview)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.12 : 0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
