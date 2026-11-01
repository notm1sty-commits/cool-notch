import AppKit
import Observation

/// «Полка»: временное место для файлов прямо в чёлке.
@MainActor
@Observable
final class ShelfStore {
    struct Item: Identifiable, Hashable {
        let id = UUID()
        let url: URL
    }

    private(set) var items: [Item] = []

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Pref.shelfPaths) ?? []
        items = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Item(url: $0) }
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(Item(url: url))
        }
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Убираем с полки файлы, которые удалили или переместили.
    func pruneMissing() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        if items.count != before { save() }
    }

    func open(_ item: Item) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func airDropAll() {
        Self.airDrop(items.map(\.url))
    }

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: Pref.shelfPaths)
    }
}
