import SwiftUI

struct ClipboardView: View {
    @Environment(NotchViewModel.self) var vm
    @State var copiedID: UUID?
    @State var editing = false
    @State var spin = 0.0

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        let clipboard = vm.clipboard
        VStack(spacing: 6) {
            if clipboard.isEnabled {
                header(clipboard)
            }
            if clipboard.isEnabled, clipboard.screenshotAccess == false, Pref.bool(Pref.screenshotsInHistory) {
                ScreenshotAccessRow { clipboard.fixScreenshotAccess() }
                    .transition(.opacity)
            }
            list(clipboard)
        }
        .overlay { emptyState(clipboard) }
        .animation(Theme.content, value: clipboard.screenshotAccess)
        .onChange(of: clipboard.entries.isEmpty) { _, empty in if empty { editing = false } }
    }

    /// Пустое состояние — по центру всей панели, на той же высоте, что на полке и в заметках.
    @ViewBuilder
    private func emptyState(_ clipboard: ClipboardService) -> some View {
        if !clipboard.isEnabled {
            PlaceholderView(
                icon: "doc.on.clipboard",
                title: "История буфера выключена",
                subtitle: "Включить можно в настройках",
                layout: .horizontal
            )
            .allowsHitTesting(false)
        } else if clipboard.entries.isEmpty {
            PlaceholderView(
                icon: "doc.on.clipboard",
                title: "Скопируй текст или сделай скриншот",
                subtitle: "Они появятся здесь. Пароли не сохраняются.",
                layout: .horizontal
            )
            .allowsHitTesting(false)
        }
    }

    /// «Проверить» — перечитать буфер и скриншоты сразу; «Изменить» — удалять лишнее.
    private func header(_ clipboard: ClipboardService) -> some View {
        HStack(spacing: 8) {
            Text("История").sectionLabelStyle()
            if !clipboard.entries.isEmpty {
                Text("\(clipboard.entries.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                    .contentTransition(.numericText())
            }
            Spacer()
            if editing {
                Button("Очистить всё") {
                    withAnimation(Theme.content) { clipboard.clear() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.9))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .glass(11)
                .transition(.opacity)
            } else {
                Button {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { spin += 360 }
                    clipboard.checkNow()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(spin))
                        Text("Проверить")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .glass(11)
                }
                .buttonStyle(.plain)
                .help("Сразу проверить буфер обмена и новые скриншоты")
                .transition(.opacity)
            }
            if !clipboard.entries.isEmpty {
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
        .frame(height: 24)
    }

    @ViewBuilder
    private func list(_ clipboard: ClipboardService) -> some View {
        ZStack {
            if !clipboard.isEnabled || clipboard.entries.isEmpty {
                Color.clear
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(clipboard.entries) { entry in
                            ClipRow(entry: entry, copied: copiedID == entry.id, editing: editing) {
                                if editing {
                                    withAnimation(Theme.content) { clipboard.remove(entry) }
                                    return
                                }
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

/// macOS не пускает в папку со скриншотами — объясняем и даём починить в один клик.
private struct ScreenshotAccessRow: View {
    var action: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Скриншоты не видны: нет доступа к папке")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("После обновления macOS иногда забывает разрешение")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer(minLength: 6)
            Button("Разрешить", action: action)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(Color.white))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glass(12)
    }
}

private struct ClipRow: View {
    let entry: ClipboardService.Entry
    var copied: Bool
    var editing = false
    var onCopy: () -> Void
    var onDelete: () -> Void

    @State var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 9) {
                if editing {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.red)
                        .transition(.scale.combined(with: .opacity))
                }
                leading
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
            .padding(.horizontal, entry.isImage ? 6 : 10)
            .padding(.vertical, entry.isImage ? 4 : 7)
            .frame(minHeight: 40)
            .glass(14, highlighted: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .onHover { value in
            withAnimation(Theme.micro) { hovering = value }
        }
        .help(entry.isImage ? "Нажми, чтобы скопировать картинку, или перетащи её" : String(entry.text.prefix(500)))
        .onDrag {
            // Во время перетаскивания наведение не сообщается — снимаем подсветку сразу.
            hovering = false
            if let url = entry.fileURL { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            if let image = entry.image { return NSItemProvider(object: image) }
            return NSItemProvider(object: entry.text as NSString)
        }
        .contextMenu {
            Button("Скопировать", action: onCopy)
            if let url = entry.fileURL {
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Удалить из истории", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let image = entry.image {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                if copied {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 44, height: 30)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        } else {
            Image(systemName: copied ? "checkmark" : icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Color.green : Theme.tertiaryText)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16)
        }
    }

    private var preview: String {
        if entry.isImage, let image = entry.image {
            let size = image.representations.first.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? ""
            return entry.fileURL == nil ? "Изображение \(size)" : "Скриншот \(size)"
        }
        return entry.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
    }

    private var icon: String {
        if entry.isImage { return "photo" }
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
