import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @Environment(NotchViewModel.self) var vm

    var body: some View {
        let shelf = vm.shelf
        HStack(spacing: 12) {
            AirDropZone()
                .frame(width: 104)

            Group {
                if shelf.items.isEmpty {
                    DropHint(active: vm.isDropTargeted)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(shelf.items) { item in
                                ShelfItemTile(item: item, shelf: shelf)
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(maxHeight: .infinity)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            withAnimation(.snappy) { shelf.clear() }
                        } label: {
                            Text("Очистить")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(vm.isDropTargeted ? 0.1 : 0.04))
            )
        }
        .onAppear { shelf.pruneMissing() }
    }
}

private struct DropHint: View {
    var active: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(active ? 0.6 : 0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
            VStack(spacing: 6) {
                Image(systemName: active ? "tray.and.arrow.down.fill" : "tray")
                    .font(.system(size: 24, weight: .medium))
                    .symbolEffect(.bounce, value: active)
                Text(active ? "Отпускай!" : "Перетащи файлы на чёлку")
                    .font(.system(size: 13, weight: .semibold))
                Text("Они подождут здесь, пока не понадобятся")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .foregroundStyle(.white.opacity(active ? 1 : 0.7))
        }
    }
}

private struct AirDropZone: View {
    @Environment(NotchViewModel.self) var vm
    @State var targeted = false

    var body: some View {
        let hasItems = !vm.shelf.items.isEmpty
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.2, green: 0.6, blue: 1), Color(red: 0.1, green: 0.35, blue: 0.95)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 44, height: 44)
                    .shadow(color: .blue.opacity(targeted ? 0.8 : 0.3), radius: targeted ? 14 : 6)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: targeted)
            }
            .scaleEffect(targeted ? 1.12 : 1)
            Text("AirDrop")
                .font(.system(size: 12, weight: .bold))
            Text(targeted ? "Отпусти, чтобы отправить" : (hasItems ? "Нажми — отправить всё" : "Перетащи сюда"))
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.blue.opacity(targeted ? 0.22 : 0.08))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { if hasItems { vm.shelf.airDropAll() } }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            vm.handleAirDrop(providers)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
    }
}

private struct ShelfItemTile: View {
    let item: ShelfStore.Item
    let shelf: ShelfStore
    @State var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 50, height: 50)
            Text(item.url.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: 76, height: 26, alignment: .top)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.1 : 0))
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    withAnimation(.snappy) { shelf.remove(item) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.3))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
            }
        }
        .onHover { hovering = $0 }
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
