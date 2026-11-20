import Foundation

enum TapeTransfer {
    static let fileLimit = 1_048_576
    private static let headers = ["金额\t备注", "金額\t備註", "Amount\tNote"]
    private static let totals = ["合计", "合計", "Total"]
    private static let number = try! NSRegularExpression(pattern: #"\p{N}"#)

    static func paste(_ text: String, into tape: inout Tape) throws -> Int {
        let rows = text.components(separatedBy: .newlines).filter { !$0.trimmed.isEmpty }
        guard let first = rows.first else { throw TapeIssue.empty }
        let table = headers.contains(first.trimmed)
        var content = table ? Array(rows.dropFirst()) : rows
        let footer = table && content.last.map {
            totals.contains(String($0.split(separator: "\t", omittingEmptySubsequences: false).first ?? "").trimmed)
        } == true ? content.popLast() : nil

        var additions = content.map { table ? tableLine($0) : parseLine($0) }
        guard !additions.isEmpty || footer != nil else { throw TapeIssue.empty }
        if let footer {
            let fields = footer.split(separator: "\t", omittingEmptySubsequences: false)
            let amount = fields.count == 2 ? Amount.parse(String(fields[1]), integerLimit: 15) : nil
            var incoming = Tape()
            incoming.lines = additions
            incoming.recalculate()
            let sum = incoming.summary
            if !sum.isComplete || amount?.value != sum.value || amount?.currency != incoming.currency {
                additions.append(Line(original: footer, input: footer))
            }
        }
        try tape.append(additions)
        return additions.count
    }

    private static func tableLine(_ raw: String) -> Line {
        let columns = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        let amount = String(columns[0]).trimmed
        guard !amount.isEmpty else { return Line(original: raw, input: raw.trimmed) }
        return Line(original: raw, input: amount, note: columns.count == 2 ? String(columns[1]) : "")
    }

    private static func parseLine(_ raw: String) -> Line {
        let text = raw.trimmed
        if Amount.parse(text) != nil { return Line(original: raw, input: text) }
        let tabs = text.components(separatedBy: "\t")
        if tabs.count == 2, let line = split(tabs, raw: raw, explicit: true) { return line }

        let colons = text.components(separatedBy: CharacterSet(charactersIn: ":："))
        if colons.count == 2, let line = split(colons, raw: raw, explicit: false) { return line }

        if let first = text.firstIndex(where: \.isWhitespace),
           let last = text.lastIndex(where: \.isWhitespace) {
            if let line = split([String(text[..<first]), String(text[first...])], raw: raw, explicit: false) { return line }
            if let line = split([String(text[..<last]), String(text[last...])], raw: raw, explicit: false) { return line }
        }
        return Line(original: raw, input: text)
    }

    private static func split(_ columns: [String], raw: String, explicit: Bool) -> Line? {
        let fields = columns.map(\.trimmed)
        let parsed = fields.map { Amount.parse($0) }
        if parsed[0] != nil && parsed[1] != nil { return nil }
        for index in fields.indices {
            let amount = fields[index], note = fields[1 - index]
            guard !amount.isEmpty, !note.isEmpty else { continue }
            let normalized = amount.folding(options: .widthInsensitive, locale: Amount.locale)
            let looksNumeric = normalized.rangeOfCharacter(from: .decimalDigits) != nil &&
                normalized.allSatisfy { "0123456789.,-+−¥$".contains($0) }
            let noteHasDigits = number.firstMatch(in: note, range: NSRange(note.startIndex..., in: note)) != nil
            if (parsed[index] != nil || looksNumeric) && (!noteHasDigits || explicit && parsed[index] != nil) {
                return Line(original: raw, input: amount, note: note)
            }
        }
        return nil
    }

    static func text(_ tape: Tape, header: String, total: String) -> String {
        let rows = tape.lines.compactMap { line -> String? in
            guard let amount = line.canonical.flatMap({ Decimal(string: $0, locale: Amount.locale) }) else { return nil }
            let note = line.note.components(separatedBy: .newlines.union(.init(charactersIn: "\t"))).joined(separator: " ")
            return tape.formatted(amount) + "\t" + note
        }
        return ([header] + rows + [total + "\t" + tape.formatted(tape.summary.value)]).joined(separator: "\n")
    }

    private struct File: Codable {
        struct Item: Codable {
            let amount: String
            let note: String
        }
        var version = 1
        let currency: Currency?
        let lines: [Item]
    }

    static func file(_ tape: Tape) throws -> Data {
        guard tape.summary.isComplete else { throw TapeIssue.incomplete }
        let items = tape.lines.compactMap { line in line.canonical.map { File.Item(amount: $0, note: line.note) } }
        let data = try JSONEncoder().encode(File(currency: tape.currency, lines: items))
        guard data.count <= fileLimit else { throw TapeIssue.tooLarge }
        return data
    }

    static func importFile(_ data: Data, into tape: inout Tape) throws -> Int {
        guard data.count <= fileLimit else { throw TapeIssue.tooLarge }
        struct Version: Decodable { let version: Int }
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(Version.self, from: data) else { throw TapeIssue.invalidFile }
        guard version.version == 1 else { throw TapeIssue.version }
        guard let file = try? decoder.decode(File.self, from: data), !file.lines.isEmpty else { throw TapeIssue.invalidFile }
        guard file.lines.count <= tape.remaining else { throw TapeIssue.capacity(tape.remaining) }
        if let unit = tape.currency, let incoming = file.currency, unit != incoming { throw TapeIssue.currency }
        let lines = try file.lines.map { item in
            guard let amount = Amount.parse(item.amount), amount.currency == nil, amount.canonical == item.amount else {
                throw TapeIssue.invalidFile
            }
            return Line(original: item.amount, input: (file.currency?.rawValue ?? "") + item.amount, note: item.note)
        }
        try tape.append(lines)
        return lines.count
    }

    static func csv(_ tape: Tape, amount: String, note: String) -> Data {
        func field(_ raw: String) -> String { "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = tape.lines.compactMap { line -> String? in
            guard let number = line.canonical else { return nil }
            let value = line.note
            let first = value.trimmed.first
            let unsafe = first.map { "=+-@＝＋－＠−".contains($0) } == true ||
                value.first.map { "\t\r\n".contains($0) } == true
            return number + "," + field(unsafe ? "'" + value : value)
        }
        return Data(("\u{FEFF}" + ([field(amount) + "," + field(note)] + rows).joined(separator: "\r\n") + "\r\n").utf8)
    }
}
