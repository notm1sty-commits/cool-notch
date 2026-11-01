import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @Environment(NotchViewModel.self) var vm
    @State private var hovering = false

    var body: some View {
        let shelf = vm.shelf
        HStack(spacing: 12) {
            AirDropZone()
                .frame(width: 128)

            // Без плашек, как у таймера: тонкий разделитель между AirDrop и полкой.
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .padding(.vertical, 14)

            ZStack {
                if shelf.items.isEmpty {
                    DropHint(active: vm.isDropTargeted, hovering: hovering)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.pickFilesForShelf() }
                        .transition(.opacity)
                } else {
                    // Кнопки — отдельной строкой над файлами, чтобы не налезать на крестики удаления.
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Полка").sectionLabelStyle()
                            Text("\(shelf.items.count)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.tertiaryText)
                                .contentTransition(.numericText())
                            Spacer()
                            AddButton { vm.pickFilesForShelf() }
                            CapsuleButton(title: "Очистить", systemImage: nil) {
                                withAnimation(Theme.content) { shelf.clear() }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(shelf.items) { item in
                                    ShelfItemTile(item: item, shelf: shelf)
                                        .transition(RevealTransition(scale: 0.8, offset: .zero))
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(maxHeight: .infinity)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Фон появляется только когда над полкой держат файл — чтобы было видно, куда бросать.
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color.white.opacity(vm.isDropTargeted ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Theme.micro) { hovering = inside } }
            .animation(Theme.content, value: shelf.items)
            .animation(Theme.micro, value: vm.isDropTargeted)
        }
        .onAppear { shelf.pruneMissing() }
    }
}

/// Пустая полка — как карточка AirDrop: без пунктира, текст не меняется, при наведении
/// значок становится плюсиком (нажми — выбери файлы).
private struct DropHint: View {
    var active: Bool
    var hovering = false

    var body: some View {
        PlaceholderView(
            title: "Перетащи файлы на чёлку",
            subtitle: "или выбери нужные",
            fill: .white.opacity(active ? 0.16 : (hovering ? 0.13 : 0.08)),
            layout: .horizontal
        ) {
            ZStack {
                Image(systemName: active ? "tray.and.arrow.down.fill" : "tray")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(active ? 1 : 0.62))
                    .opacity(hovering && !active ? 0 : 1)
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(hovering && !active ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: 0.15), value: active)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Маленький «+» рядом с «Очистить»: добавить файлы на полку через окно Finder.
private struct AddButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .onHover { value in withAnimation(Theme.micro) { hovering = value } }
        .help("Добавить файлы")
    }
}

private struct AirDropZone: View {
    @Environment(NotchViewModel.self) var vm
    @State var targeted = false
    @State var hovering = false

    var body: some View {
        // При наведении — плюсик: нажми и выбери, что отправить. Файл с полки можно просто
        // перетащить сюда. Подпись одна и та же, чтобы ничего не прыгало.
        let picking = hovering && !targeted
        PlaceholderView(
            title: "AirDrop",
            subtitle: "Перетащи или выбери файл",
            fill: Color(red: 0.12, green: 0.5, blue: 1),
            layout: .vertical
        ) {
            ZStack {
                AirDropGlyph()
                    .opacity(picking ? 0 : 1)
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(picking ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color(red: 0.35, green: 0.68, blue: 1).opacity(targeted ? 0.12 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onTapGesture { vm.pickFilesForAirDrop() }
        .onHover { hovering = $0 }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            vm.handleAirDrop(providers)
        }
        .animation(Theme.hover, value: targeted)
        .animation(Theme.micro, value: hovering)
    }
}

private struct ShelfItemTile: View {
    let item: ShelfStore.Item
    let shelf: ShelfStore
    @State var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 50, height: 50)
                .scaleEffect(hovering ? 1.06 : 1)
            Text(item.url.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: 76, height: 26, alignment: .top)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.09 : 0))
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    withAnimation(Theme.content) { shelf.remove(item) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.28))
                }
                .buttonStyle(PressableButtonStyle())
                .offset(x: 2, y: -2)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { value in
            withAnimation(Theme.micro) { hovering = value }
        }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .onTapGesture(count: 2) { shelf.open(item) }
        .help(item.url.path)
        .contextMenu {
            Button("Открыть") { shelf.open(item) }
            Button("Показать в Finder") { shelf.reveal(item) }
            Button("Отправить по AirDrop") { ShelfStore.airDrop([item.url]) }
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Divider()
            Button("Убрать с полки", role: .destructive) { shelf.remove(item) }
        }
    }
}
