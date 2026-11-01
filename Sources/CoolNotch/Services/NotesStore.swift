import AppKit
import Observation

/// Быстрые заметки: список, как история копирований. Хранятся в UserDefaults.
@MainActor
@Observable
final class NotesStore {
    struct Note: Identifiable, Codable, Equatable {
        var id = UUID()
        var text: String
        var date: Date
    }

    private(set) var notes: [Note] = []

    private static let key = "quickNotes"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Note].self, from: data) {
            notes = saved
        } else if let legacy = UserDefaults.standard.string(forKey: Pref.notesText),
                  !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Переносим старую одиночную заметку в новый список.
            notes = [Note(text: legacy, date: Date())]
            save()
        }
    }

    @discardableResult
    func add(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        notes.insert(Note(text: trimmed, date: Date()), at: 0)
        save()
        return true
    }

    func remove(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    func removeAll() {
        notes.removeAll()
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        notes.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func copy(_ note: Note) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
    }

    func replaceAll(_ newNotes: [Note]) {
        notes = newNotes
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
