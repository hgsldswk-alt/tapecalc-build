import Foundation
import StoreKit
import Security
import SwiftUI

private actor PurchaseVault {
    private let key: [String: String] = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: "com.hgsldswk.tapecalc",
        kSecAttrAccount as String: "entitlement-v1"
    ]
    private var savedRevision = 0

    func load() throws -> Entitlement? {
        var query: [String: Any] = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw TapeIssue.storage }
        return try JSONDecoder().decode(Entitlement.self, from: data)
    }

    func save(_ entitlement: Entitlement, revision: Int) throws {
        guard revision > savedRevision else { return }
        let data = try JSONEncoder().encode(entitlement)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(key as CFDictionary, update)
        if status == errSecItemNotFound {
            var addition: [String: Any] = key
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(key as CFDictionary, update) }
        }
        guard status == errSecSuccess else { throw TapeIssue.storage }
        savedRevision = revision
    }
}

@MainActor final class Purchases: ObservableObject {
    static let proID = "com.hgsldswk.tapecalc.pro"
    static let trialID = "com.hgsldswk.tapecalc.trial"

    @Published private(set) var entitlement = Entitlement()
    @Published private(set) var products: [Product] = []
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var now = Date()
    @Published var error: String?
    private let vault = PurchaseVault()
    private var revision = 0
    private var updates: Task<Void, Never>?
    private var starting = false
    private var expiryTask: Task<Void, Never>?

    deinit {
        updates?.cancel()
        expiryTask?.cancel()
    }

    var hasPro: Bool {
        Launch.isFree || ready && entitlement.hasPro(at: now, free: false)
    }

    func start() async {
        guard !ready, !starting else { return }
        starting = true
        defer { starting = false }
        now = Date()
        if Launch.testing {
            entitlement.startPaidMode(at: Launch.has("-expired")
                ? now.addingTimeInterval(-31 * 86_400) : now)
            ready = true
            return
        }

        do {
            entitlement = try await vault.load() ?? Entitlement(firstOpen: now)
            if !Launch.isFree { entitlement.startPaidMode(at: now) }
            try await persist()
        } catch {
            self.error = L.t("purchaseStorage")
            return
        }
        if Launch.isFree {
            ready = true
            return
        }
        updates = Task { [weak self] in
            for await verification in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let self, case .verified(let transaction) = verification else { continue }
                await self.refresh()
                await transaction.finish()
            }
        }
        await refresh()
        ready = true
    }

    func tick() {
        now = Date()
        expiryTask?.cancel()
        let delay = entitlement.trialEnd.timeIntervalSince(now)
        guard delay > 0, !Launch.isFree else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.now = Date()
        }
    }

    func loadProducts() async {
        guard !Launch.testing, !Launch.isFree, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            products = try await Product.products(for: [Self.proID, Self.trialID])
            if products.isEmpty { error = L.t("storeUnavailable") }
        } catch {
            self.error = L.t("storeUnavailable")
        }
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    func buy(_ product: Product) async {
        guard !busy, !Launch.testing, !Launch.isFree else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    self.error = L.t("purchaseFailed")
                    return
                }
                await refresh()
                await transaction.finish()
            case .pending:
                self.error = L.t("purchasePending")
            case .userCancelled:
                break
            @unknown default:
                self.error = L.t("purchaseFailed")
            }
        } catch {
            self.error = L.t("purchaseFailed")
        }
    }

    func restore() async {
        guard !busy, !Launch.testing, !Launch.isFree else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh()
            if !entitlement.purchasedPro && entitlement.trialClaimedAt == nil { error = L.t("nothingToRestore") }
        } catch {
            self.error = L.t("purchaseFailed")
        }
    }

    private var refreshRevision = 0

    private func refresh() async {
        refreshRevision += 1
        let requested = refreshRevision
        var purchased = false
        var trial: Date?
        for await verification in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification, transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case Self.proID: purchased = true
            case Self.trialID: trial = transaction.originalPurchaseDate
            default: break
            }
        }
        guard requested == refreshRevision else { return }
        entitlement.purchasedPro = purchased
        if let trial { entitlement.recordTrialReceipt(trial) }
        tick()
        do { try await persist() }
        catch { self.error = L.t("purchaseStorage") }
    }

    private func persist() async throws {
        revision += 1
        try await vault.save(entitlement, revision: revision)
    }
}
