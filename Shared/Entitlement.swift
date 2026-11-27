import Foundation

struct Entitlement: Codable, Equatable {
    var firstOpen: Date
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    init(firstOpen: Date = Date()) { self.firstOpen = firstOpen }

    var trialStart: Date {
        let localStart = proStartedAt ?? firstOpen
        return min(trialClaimedAt ?? localStart, localStart)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }

    mutating func startPaidMode(at date: Date) {
        if proStartedAt == nil { proStartedAt = date }
    }

    mutating func recordTrialReceipt(_ original: Date) {
        trialClaimedAt = min(trialClaimedAt ?? original, original)
    }

    func hasPro(at now: Date, free: Bool) -> Bool {
        free || purchasedPro || (now >= trialStart && now < trialEnd)
    }
}
