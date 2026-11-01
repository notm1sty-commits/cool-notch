import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let shelf = vm.shelf
        HStack(spacing: 12) {
            AirDropZone()
                .frame(width: 128)

            ZStack {
                if shelf.items.isEmpty {
                    DropHint(active: vm.isDropTargeted)
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
                        CapsuleButton(title: "Очистить", systemImage: nil) {
                            withAnimation(Theme.content) { shelf.clear() }
                        }
                        .padding(8)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glass(Theme.cardRadius, highlighted: vm.isDropTargeted)
            .animation(Theme.content, value: shelf.items)
            .animation(Theme.micro, value: vm.isDropTargeted)
        }
        .onAppear { shelf.pruneMissing() }
    }
}

private struct DropHint: View {
    var active: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(active ? 0.5 : 0.14),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
            PlaceholderView(
                title: active ? "Отпускай" : "Перетащи файлы на чёлку",
                subtitle: "Они подождут здесь, пока не понадобятся",
                fill: .white.opacity(active ? 0.16 : 0.08)
            ) {
                Image(systemName: active ? "tray.and.arrow.down.fill" : "tray")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(active ? 1 : 0.62))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .scaleEffect(active ? 1.02 : 1)
        .animation(Theme.hover, value: active)
    }
}

private struct AirDropZone: View {
    @Environment(NotchViewModel.self) var vm
    @State var targeted = false
    @State var hovering = false

    var body: some View {
        let hasItems = !vm.shelf.items.isEmpty
        PlaceholderView(
            title: "AirDrop",
            subtitle: targeted ? "Отпусти — отправлю" : (hasItems ? "Нажми — отправлю всё" : "Брось файл сюда"),
            fill: Color(red: 0.12, green: 0.5, blue: 1)
        ) {
            AirDropGlyph()
        }
        .scaleEffect(targeted ? 1.06 : (hovering && hasItems ? 1.03 : 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glass(Theme.cardRadius, highlighted: targeted || (hovering && hasItems), tint: targeted ? Color(red: 0.35, green: 0.68, blue: 1) : .white)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onTapGesture { if hasItems { vm.shelf.airDropAll() } }
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
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
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
