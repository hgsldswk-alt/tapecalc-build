import SwiftUI
import UIKit

@MainActor final class TapeModel: ObservableObject {
    @Published private(set) var book = TapeBook()
    @Published private(set) var ready = false
    @Published private(set) var saveFailed = false
    @Published private(set) var loadFailed = false
    @Published var notice: String?
    @Published var error: String?
    @Published private var lastAction: TapeUndo?

    private var store: TapeStore?
    private var revision = 0
    private var reviewEdits: Set<UUID> = []
    private var coreActionRevision: Int?
    private var lastSaved = 0
    private var loading = false
    private var backgroundSave = UIBackgroundTaskIdentifier.invalid
    private var backgroundToken: UUID?

    var index: Int { book.tapes.firstIndex { $0.id == book.currentID } ?? 0 }
    var tape: Tape { book.tapes[index] }
    var summary: Summary { tape.summary }
    var hasUndo: Bool { lastAction?.before.id == tape.id }
    var hasChanges: Bool { revision > lastSaved }

    func load() async {
        guard !ready, !loading else { return }
        loading = true
        defer { loading = false }
        let url = await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let file = base.appendingPathComponent(Launch.testing ? "TapeCalc-UI" : "TapeCalc")
                .appendingPathComponent("tapes.json")
            if Launch.has("-reset"), manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
            return file
        }.result
        do {
            let store = TapeStore(url: try url.get())
            book = try await store.load()
            self.store = store
            loadFailed = false
            ready = true
            seedIfNeeded()
        } catch {
            loadFailed = true
        }
    }

    func title(for tape: Tape) -> String { tape.title.isEmpty ? L.t("defaultTape") : tape.title }

    func select(_ id: UUID) {
        guard book.currentID != id, book.tapes.contains(where: { $0.id == id }) else { return }
        book.currentID = id
        lastAction = nil
        notice = nil
        save()
    }

    func create(_ title: String, notes: [String] = []) {
        let created = Tape(title: title, lines: notes.map { Line(note: $0) })
        book.tapes.append(created)
        select(created.id)
    }

    func rename(_ name: String) {
        guard !name.trimmed.isEmpty else { return }
        var updated = tape
        updated.title = name.trimmed
        updated.updated = Date()
        replace(updated)
    }

    func add() -> UUID? {
        if let empty = tape.lines.last, empty.isEmpty { return empty.id }
        guard tape.remaining > 0 else {
            error = TapeIssue.capacity(tape.remaining).message
            return nil
        }
        var updated = tape
        let line = Line()
        updated.lines.append(line)
        replace(updated)
        return line.id
    }

    func edit(_ id: UUID, input: String? = nil, note: String? = nil) {
        var updated = tape
        guard let row = updated.lines.firstIndex(where: { $0.id == id }) else { return }
        let old = updated.lines[row]
        if let input { updated.lines[row].input = input }
        if let note { updated.lines[row].note = note }
        guard old != updated.lines[row] else { return }
        if old.isEmpty && !updated.lines[row].isEmpty && updated.remaining < 0 {
            error = TapeIssue.capacity(0).message
            return
        }
        updated.recalculate()
        if input != nil { reviewEdits.insert(id) }
        replace(updated, countUse: input != nil && updated.lines[row].canonical != nil)
    }

    func remove(_ id: UUID) {
        var updated = tape
        updated.lines.removeAll { $0.id == id }
        updated.recalculate()
        lastAction = TapeUndo(before: tape, after: updated)
        notice = L.t("deleted")
        replace(updated)
    }

    func clear() {
        var updated = tape
        updated.lines = [Line()]
        updated.recalculate()
        lastAction = TapeUndo(before: tape, after: updated)
        notice = L.t("cleared")
        replace(updated)
    }

    func undo() {
        guard let lastAction, hasUndo else { return }
        do {
            let restored = try lastAction.apply(to: tape)
            self.lastAction = nil
            notice = L.t("undone")
            replace(restored)
        } catch {
            self.error = (error as? TapeIssue)?.message ?? L.t("saveFailed")
        }
    }

    func paste(_ input: String) {
        var updated = tape
        do {
            let count = try TapeTransfer.paste(input, into: &updated)
            let invalid = updated.lines.suffix(count).filter { $0.canonical == nil }.count
            lastAction = TapeUndo(before: tape, after: updated)
            notice = invalid == 0 ? L.f("pasted", count) : L.f("pastedInvalid", count, invalid)
            replace(updated, countUse: updated.lines.suffix(count).contains { $0.canonical != nil })
        } catch {
            self.error = (error as? TapeIssue)?.message ?? L.t("invalidFile")
        }
    }

    func importFile(_ url: URL) async {
        do {
            let data = try await Task.detached(priority: .userInitiated) { try TapeStore.readImport(url) }.value
            var updated = tape
            let count = try TapeTransfer.importFile(data, into: &updated)
            lastAction = TapeUndo(before: tape, after: updated)
            notice = L.f("imported", count)
            replace(updated, countUse: true)
        } catch {
            self.error = (error as? TapeIssue)?.message ?? L.t("invalidFile")
        }
    }

    func text() -> String {
        TapeTransfer.text(tape, header: L.t("amount") + "\t" + L.t("note"), total: L.t("total"))
    }

    func copied() { notice = L.t("copied") }

    func sharedDetails() {
        book.detailShares += 1
        save()
    }

    func markRatingRequested() {
        book.ratingRequested = true
        save()
    }

    private func replace(_ tape: Tape, countUse: Bool = false) {
        book.tapes[index] = tape
        if countUse && tape.summary.isComplete { book.recordUse(Date()) }
        save()
    }

    func finishCalculation(_ id: UUID) {
        guard reviewEdits.remove(id) != nil, !Launch.testing, summary.isComplete,
              tape.lines.contains(where: { $0.id == id && $0.canonical != nil }) else { return }
        book.coreReviewProgress = .recording(book.coreReviewProgress)
        save(coreAction: true)
    }

    private func save(coreAction: Bool = false) {
        revision += 1
        if coreAction { coreActionRevision = revision }
        Task { await flush() }
    }

    func flush() async {
        guard let store, hasChanges else { return }
        let pending = revision
        let snapshot = book
        do {
            try await store.save(snapshot, revision: pending)
            if let coreActionRevision, coreActionRevision <= pending {
                self.coreActionRevision = nil
                CoreReview.shared.record(snapshot.coreReviewProgress)
            }
            lastSaved = max(lastSaved, pending)
            if lastSaved == revision { saveFailed = false }
        } catch {
            if pending >= revision && pending > lastSaved { saveFailed = true }
        }
    }

    func flushInBackground() {
        guard hasChanges, backgroundToken == nil else { return }
        let token = UUID()
        backgroundToken = token
        backgroundSave = UIApplication.shared.beginBackgroundTask(withName: "Save tape") { [weak self] in
            Task { @MainActor in self?.endBackgroundSave(token) }
        }
        Task {
            await flush()
            endBackgroundSave(token)
        }
    }

    private func endBackgroundSave(_ token: UUID) {
        guard backgroundToken == token else { return }
        if backgroundSave != .invalid { UIApplication.shared.endBackgroundTask(backgroundSave) }
        backgroundSave = .invalid
        backgroundToken = nil
    }

    private func seedIfNeeded() {
        guard Launch.has("-store-demo") else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let demo = arguments.contains("-invalid-demo")
            ? [("demoTrain", "128"), ("demoLunch", "65"), ("demoTaxi", "32.5.0"), ("demoRefund", "-10")]
            : arguments.contains("-notes-demo")
            ? [("meal", "128"), ("drinks", "65"), ("transport", "32.50"), ("demoRefund", "-10")]
            : [("demoTrain", "128"), ("demoLunch", "65"), ("demoTaxi", "32.50"), ("demoRefund", "-10")]
        var updated = tape
        updated.title = arguments.contains("-notes-demo") ? L.t("mealTemplate") : L.t("demoTitle")
        updated.lines = demo.map { Line(input: $0.1, note: L.t($0.0)) }
        updated.recalculate()
        replace(updated)
    }
}
