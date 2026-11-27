import Foundation
import CoreImage
import XCTest

final class CoreTests: XCTestCase {
    func testExactDecimalAndPendingSubtotal() throws {
        var tape = Tape()
        XCTAssertEqual(try TapeTransfer.paste("0.1\n0.2\n0\n−0.0001\n１２３．４５６７", into: &tape), 5)
        XCTAssertEqual(tape.summary, Summary(value: Decimal(string: "123.7566")!, valid: 5, invalid: 0))
        XCTAssertEqual(tape.formatted(tape.summary.value), "123.7566")

        tape = Tape()
        try TapeTransfer.paste("高铁 128\r\n午饭 65\r\n打车 32.5.0\r\n退款 -10", into: &tape)
        XCTAssertEqual(tape.summary, Summary(value: 183, valid: 3, invalid: 1))
        XCTAssertEqual(tape.lines[2].note, "打车")
        XCTAssertFalse(tape.summary.isComplete)
        tape.lines[2].input = "32.50"
        tape.recalculate()
        XCTAssertEqual(tape.formatted(tape.summary.value), "215.50")
        XCTAssertTrue(tape.summary.isComplete)
        XCTAssertEqual(Amount.display(Decimal(string: "0.3")!), "0.30")
    }

    func testAmountLimitsAndFirstExplicitCurrency() throws {
        for input in ["12,50", "1,23,456", "1234567890123", "0.00001", "+-2", "1e4", "＄¥12", "2\n3"] {
            XCTAssertNil(Amount.parse(input), input)
        }
        XCTAssertEqual(Amount.parse("－￥１，２３４．５")?.canonical, "-1234.5")
        XCTAssertEqual(Amount.parse("$9")?.currency, .dollar)
        XCTAssertEqual(Amount.parse("999999999999.9999")?.canonical, "999999999999.9999")
        var tape = Tape()
        try TapeTransfer.paste("10\n¥3\n$2\n￥5", into: &tape)
        XCTAssertEqual(tape.currency, .yuan)
        XCTAssertEqual(tape.summary, Summary(value: 18, valid: 3, invalid: 1))
        tape.lines.removeAll { $0.canonical == nil }
        tape.lines.removeAll()
        tape.recalculate()
        XCTAssertNil(tape.currency)
    }

    func testPasteSplitsWithoutGuessingNumbers() throws {
        var tape = Tape()
        try TapeTransfer.paste("\r\n15 Lunch\r\n午餐：20\n$4\tBus 23\n3 4\n12:30 Taxi 7\nRoom 3 4\n", into: &tape)
        XCTAssertEqual(tape.lines.map(\.note), ["Lunch", "午餐", "Bus 23", "", "", ""])
        XCTAssertEqual(tape.lines.map(\.input), ["15", "20", "$4", "3 4", "12:30 Taxi 7", "Room 3 4"])
        XCTAssertEqual(tape.summary, Summary(value: 39, valid: 3, invalid: 3))
    }

    func testCopyRoundsTripWithLargeVerifiedTotalAndNumericNote() throws {
        var original = Tape()
        try TapeTransfer.paste("999999999999.9999\tRoom 203\n¥999999999999.9999\tTable 4", into: &original)
        XCTAssertEqual(original.summary.valid, 2)
        for (header, total) in [("Amount\tNote", "Total"), ("金额\t备注", "合计"), ("金額\t備註", "合計")] {
            let copy = TapeTransfer.text(original, header: header, total: total)
            var received = Tape()
            XCTAssertEqual(try TapeTransfer.paste(copy, into: &received), 2)
            XCTAssertEqual(received.summary, original.summary)
            XCTAssertEqual(received.currency, .yuan)
            XCTAssertEqual(received.lines.map(\.note), ["Room 203", "Table 4"])
            let corrupted = copy.replacingOccurrences(of: "¥1999999999999.9998", with: "¥100.00")
            var invalid = Tape()
            XCTAssertEqual(try TapeTransfer.paste(corrupted, into: &invalid), 3)
            XCTAssertEqual(invalid.summary.invalid, 1)
        }
    }

    func testCapacityAndFileValidationAreAtomic() throws {
        var tape = Tape()
        try TapeTransfer.paste(Array(repeating: "1", count: 499).joined(separator: "\n"), into: &tape)
        let before = tape
        XCTAssertThrowsError(try TapeTransfer.paste("2\n3", into: &tape)) {
            XCTAssertEqual($0 as? TapeIssue, .capacity(1))
        }
        let missingNote = #"{"version":1,"lines":[{"amount":"2","note":""},{"amount":"1"}]}"#
        for (data, expected) in [
            (Data(missingNote.utf8), TapeIssue.invalidFile),
            (Data(#"{"version":2}"#.utf8), .version),
            (Data(repeating: 0, count: TapeTransfer.fileLimit + 1), .tooLarge),
            (Data(#"{"version":1,"lines":[{"amount":"2.00000","note":""}]}"#.utf8), .invalidFile)
        ] {
            XCTAssertThrowsError(try TapeTransfer.importFile(data, into: &tape)) {
                XCTAssertEqual($0 as? TapeIssue, expected)
            }
            XCTAssertEqual(tape, before)
        }
    }

    func testBatchUndoKeepsLaterEditsOnOriginalRows() throws {
        var before = Tape()
        try TapeTransfer.paste("12", into: &before)
        var after = before
        try TapeTransfer.paste("3\n4", into: &after)
        let action = TapeUndo(before: before, after: after)
        XCTAssertEqual(try action.apply(to: after), before)
        after.lines[0].input = "14"
        after.recalculate()
        let restored = try action.apply(to: after)
        XCTAssertEqual(restored.lines.count, 1)
        XCTAssertEqual(restored.summary.value, 14)
    }

    func testFileRoundTripAndPrivateCSVNotes() throws {
        var tape = Tape()
        tape.lines = [Line(input: "$1.25", note: "  =SUM(2,3)\n\"receipt\""), Line(input: "-2", note: "refund")]
        tape.recalculate()
        let file = try TapeTransfer.file(tape)
        var received = Tape()
        XCTAssertEqual(try TapeTransfer.importFile(file, into: &received), 2)
        XCTAssertEqual(received.lines.map(\.note), tape.lines.map(\.note))
        XCTAssertEqual(received.summary, tape.summary)
        XCTAssertEqual(received.currency, .dollar)
        let csv = String(decoding: TapeTransfer.csv(tape, amount: "Amount", note: "Note"), as: UTF8.self)
        XCTAssertTrue(csv.contains("1.25,\"'  =SUM(2,3)\n\"\"receipt\"\"\""))
        XCTAssertTrue(csv.contains("-2,\"refund\""))

        var other = Tape()
        try TapeTransfer.paste("¥10", into: &other)
        let before = other
        XCTAssertThrowsError(try TapeTransfer.importFile(file, into: &other)) {
            XCTAssertEqual($0 as? TapeIssue, .currency)
        }
        XCTAssertEqual(other, before)
        tape.lines[0].note = String(repeating: "a", count: TapeTransfer.fileLimit)
        XCTAssertThrowsError(try TapeTransfer.file(tape)) {
            XCTAssertEqual($0 as? TapeIssue, .tooLarge)
        }
    }

    func testAtomicStorageAndIncompleteEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tapes.json")
        let store = TapeStore(url: url)
        let initial = try await store.load()
        XCTAssertEqual(initial.tapes.count, 1)
        var expected = initial
        try TapeTransfer.paste("1\nTaxi 32.5.0", into: &expected.tapes[0])
        try await store.save(expected, revision: 2)
        try await store.save(initial, revision: 1)
        let reopened = try await TapeStore(url: url).load()
        XCTAssertEqual(reopened, expected)
        XCTAssertEqual(reopened.tapes[0].lines[1].input, "32.5.0")

        let blocked = TapeStore(url: url.appendingPathComponent("bad.json"))
        do {
            try await blocked.save(expected, revision: 1)
            XCTFail("Expected an atomic write failure where the parent is a file")
        } catch {
            let preserved = try await store.load()
            XCTAssertEqual(preserved, expected)
        }
    }

    func testStorageMigratesAndPreservesBadFile() async throws {
        let book = TapeBook()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        json.removeValue(forKey: "version")
        json.removeValue(forKey: "useDays")
        let legacy = try TapeStore.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.currentID, book.currentID)
        XCTAssertEqual(legacy.useDays, [])
        json["version"] = 999
        XCTAssertThrowsError(try TapeStore.decode(JSONSerialization.data(withJSONObject: json)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: url)
        do {
            _ = try await TapeStore(url: url).load()
            XCTFail("Expected read error")
        } catch {
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
        }
    }

    func testTrialStartsWithFirstPaidLaunchAndExpiresExactly() throws {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let day: TimeInterval = 86_400
        var entitlement = Entitlement(firstOpen: start.addingTimeInterval(-100 * day))
        XCTAssertTrue(entitlement.hasPro(at: start, free: true))
        XCTAssertFalse(entitlement.hasPro(at: start, free: false))
        entitlement.startPaidMode(at: start)
        entitlement.startPaidMode(at: start.addingTimeInterval(day))
        XCTAssertTrue(entitlement.hasPro(at: start.addingTimeInterval(29 * day), free: false))
        XCTAssertFalse(entitlement.hasPro(at: start.addingTimeInterval(30 * day), free: false))
        entitlement.recordTrialReceipt(start.addingTimeInterval(day))
        XCTAssertEqual(entitlement.trialStart, start, "Claiming later must not extend the local trial")
        var restored = Entitlement(firstOpen: start.addingTimeInterval(31 * day))
        restored.startPaidMode(at: restored.firstOpen)
        restored.recordTrialReceipt(start)
        let data = try JSONEncoder().encode(restored)
        restored = try JSONDecoder().decode(Entitlement.self, from: data)
        XCTAssertFalse(restored.hasPro(at: restored.firstOpen, free: false))
        restored.purchasedPro = true
        XCTAssertTrue(restored.hasPro(at: restored.firstOpen, free: false))
        restored.purchasedPro = false
        XCTAssertFalse(restored.hasPro(at: restored.firstOpen, free: false))
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testMilestoneAndRatingCountDistinctLocalDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        var book = TapeBook()
        book.recordUse(start, calendar: calendar)
        book.recordUse(start.addingTimeInterval(60), calendar: calendar)
        XCTAssertEqual(book.useDays.count, 1)
        for days in 1...9 {
            book.recordUse(calendar.date(byAdding: .day, value: days, to: start)!, calendar: calendar)
            XCTAssertEqual(book.hasMilestone, days == 9)
        }
        book.detailShares = 1
        XCTAssertFalse(book.canRequestRating)
        book.detailShares = 2
        XCTAssertTrue(book.canRequestRating)
        book.ratingRequested = true
        XCTAssertFalse(book.canRequestRating)
    }

    func testShareLimitAndQRCodeRoundTrip() throws {
        XCTAssertTrue(ShareRules.prefersImage(rows: 12, height: 790))
        XCTAssertFalse(ShareRules.prefersImage(rows: 13, height: 780))
        XCTAssertFalse(ShareRules.prefersImage(rows: 1, height: 791))
        XCTAssertNil(ShareQR.storeURL(appID: ""))
        XCTAssertNil(ShareQR.storeURL(appID: "__APP_STORE_ID__"))
        let url = try XCTUnwrap(ShareQR.storeURL(appID: "1234567890"))
        let code = try XCTUnwrap(ShareQR.image(for: url.absoluteString))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let decoded = detector.features(in: CIImage(cgImage: code)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(decoded, ["https://apps.apple.com/app/id1234567890"])
    }
}
