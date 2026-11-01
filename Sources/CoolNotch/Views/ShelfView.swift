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

            ZStack {
                if shelf.items.isEmpty {
                    DropHint(active: vm.isDropTargeted, hovering: hovering)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.pickFilesForShelf() }
                        .transition(.opacity)
                } else {
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
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 6) {
                            AddButton { vm.pickFilesForShelf() }
                            CapsuleButton(title: "Очистить", systemImage: nil) {
                                withAnimation(Theme.content) { shelf.clear() }
                            }
                        }
                        .padding(8)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glass(Theme.cardRadius, highlighted: vm.isDropTargeted || hovering, soft: true)
            .onHover { inside in withAnimation(Theme.micro) { hovering = inside } }
            .animation(Theme.content, value: shelf.items)
            .animation(Theme.micro, value: vm.isDropTargeted)
        }
        .onAppear { shelf.pruneMissing() }
    }
}

private struct DropHint: View {
    var active: Bool
    var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(active ? 0.55 : (hovering ? 0.23 : 0.14)),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
                .padding(0.5)
            PlaceholderView(
                title: active ? "Отпускай" : (hovering ? "Нажми, чтобы выбрать файлы" : "Перетащи файлы на чёлку"),
                subtitle: hovering && !active ? "или перетащи их сюда — подождут, пока не понадобятся" : "Они подождут здесь, пока не понадобятся",
                fill: .white.opacity(active ? 0.16 : (hovering ? 0.13 : 0.08)),
                layout: .horizontal
            ) {
                Image(systemName: active ? "tray.and.arrow.down.fill" : (hovering ? "plus" : "tray"))
                    .font(.system(size: 16, weight: hovering && !active ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(active || hovering ? 1 : 0.62))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        // Без масштаба: раньше рамка увеличивалась и вылезала за фон блока, а пружина дёргалась.
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
            subtitle: "Брось файл сюда",
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
        .glass(Theme.cardRadius, highlighted: targeted || hovering, tint: targeted ? Color(red: 0.35, green: 0.68, blue: 1) : .white, soft: true)
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
