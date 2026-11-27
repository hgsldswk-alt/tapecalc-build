import Foundation

enum Currency: String, Codable {
    case yuan = "¥", dollar = "$"
}

struct Amount {
    let value: Decimal
    let currency: Currency?
    var canonical: String { NSDecimalNumber(decimal: value).stringValue }

    static let locale = Locale(identifier: "en_US_POSIX")
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(?:([¥$])([+-]?)|([+-]?)([¥$]?))([0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(\.[0-9]{1,4})?$"#
    )

    static func parse(_ raw: String, integerLimit: Int = 12) -> Amount? {
        let text = raw.folding(options: .widthInsensitive, locale: locale)
            .replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String {
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
        let integer = group(5).replacingOccurrences(of: ",", with: "")
        guard integer.count <= integerLimit, let value = Decimal(string: group(2) + group(3) + integer + group(6), locale: locale) else {
            return nil
        }
        return Amount(value: value, currency: Currency(rawValue: group(1) + group(4)))
    }

    static func display(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value).stringValue
        if let point = number.firstIndex(of: ".") {
            return number.distance(from: point, to: number.endIndex) == 2 ? number + "0" : number
        }
        return number + ".00"
    }
}

struct Line: Codable, Equatable, Identifiable {
    var id = UUID()
    var original = ""
    var input = ""
    var note = ""
    var canonical: String?

    var isEmpty: Bool { input.trimmed.isEmpty && note.trimmed.isEmpty }
}

struct Tape: Codable, Equatable, Identifiable {
    static let limit = 500

    var id = UUID()
    var title = ""
    var currency: Currency?
    var created = Date()
    var updated = Date()
    var lines: [Line] = [Line()]

    var summary: Summary {
        var result = Summary()
        for line in lines {
            if let canonical = line.canonical, let amount = Decimal(string: canonical, locale: Amount.locale) {
                result.value += amount
                result.valid += 1
            } else if !line.input.trimmed.isEmpty {
                result.invalid += 1
            }
        }
        return result
    }

    var remaining: Int { Self.limit - lines.filter { !$0.isEmpty }.count }

    mutating func recalculate() {
        if let currency,
           !lines.contains(where: { line in
               guard let amount = Amount.parse(line.input) else { return false }
               return amount.currency == nil || amount.currency == currency
           }) {
            self.currency = nil
        }
        for index in lines.indices {
            lines[index].canonical = nil
            guard let amount = Amount.parse(lines[index].input) else { continue }
            if let explicit = amount.currency {
                if let currency, currency != explicit { continue }
                currency = explicit
            }
            lines[index].canonical = amount.canonical
        }
        updated = Date()
    }

    mutating func append(_ additions: [Line]) throws {
        guard additions.count <= remaining else { throw TapeIssue.capacity(remaining) }
        lines.removeAll(where: \.isEmpty)
        lines.append(contentsOf: additions)
        recalculate()
    }

    func formatted(_ value: Decimal) -> String {
        (currency?.rawValue ?? "") + Amount.display(value)
    }
}

struct Summary: Equatable {
    var value: Decimal = 0
    var valid = 0
    var invalid = 0
    var isComplete: Bool { valid > 0 && invalid == 0 }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum TapeIssue: Error, Equatable {
    case capacity(Int), empty, tooLarge, version, invalidFile, currency, incomplete, storage

    var message: String {
        switch self {
        case .capacity(let remaining): return L.f("capacity", remaining)
        case .empty: return L.t("emptyPaste")
        case .tooLarge: return L.t("tooLarge")
        case .version: return L.t("fileVersion")
        case .invalidFile: return L.t("invalidFile")
        case .currency: return L.t("fileCurrency")
        case .incomplete: return L.t("incomplete")
        case .storage: return L.t("saveFailed")
        }
    }
}

struct TapeBook: Codable, Equatable {
    var version = 1
    var tapes: [Tape]
    var currentID: UUID
    var useDays: Set<String> = []
    var detailShares = 0
    var ratingRequested = false
    var coreReviewProgress: CoreReviewProgress?

    init() {
        let first = Tape()
        tapes = [first]
        currentID = first.id
    }

    mutating func recordUse(_ now: Date, calendar: Calendar = .current) {
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        useDays.insert("\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)")
    }

    var canRequestRating: Bool { useDays.count >= 3 && detailShares >= 2 && !ratingRequested }
    var hasMilestone: Bool { useDays.count >= 10 }
}
