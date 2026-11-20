import Foundation

struct TapeUndo {
    let before: Tape
    let after: Tape

    func apply(to current: Tape) throws -> Tape {
        guard current != after else { return before }
        let beforeIDs = Set(before.lines.map(\.id))
        let afterIDs = Set(after.lines.map(\.id))
        let added = afterIDs.subtracting(beforeIDs)
        var result = current
        result.lines.removeAll { added.contains($0.id) }

        for (index, line) in before.lines.enumerated() where !afterIDs.contains(line.id) {
            let following = Set(before.lines.dropFirst(index + 1).map(\.id))
            let insertion = result.lines.firstIndex { following.contains($0.id) } ?? result.lines.endIndex
            result.lines.insert(line, at: insertion)
        }
        guard result.remaining >= 0 else { throw TapeIssue.capacity(current.remaining) }
        if result.currency == after.currency { result.currency = before.currency }
        result.recalculate()
        return result
    }
}
