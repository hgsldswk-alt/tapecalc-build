import StoreKit
import SwiftUI

struct Paywall: View {
    @ObservedObject var purchases: Purchases
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PurchaseContent(purchases: purchases)
                .navigationTitle(L.t("pro"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L.t("done")) { dismiss() }.accessibilityIdentifier("paywall.done")
                    }
                }
        }
    }
}

struct PurchaseContent: View {
    @ObservedObject var purchases: Purchases

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 30)).foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(Palette.blue, in: RoundedRectangle(cornerRadius: 17))
                    .accessibilityHidden(true)
                Text(L.t("lifetime")).font(.largeTitle.weight(.bold)).accessibilityIdentifier("paywall.title")
                Text(L.t("proFeatures")).font(.body)
                Text(status).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.link)
                    .accessibilityIdentifier("paywall.status")
                Text(L.t("trialTerms")).font(.footnote).foregroundStyle(Palette.muted)
                if !purchases.entitlement.purchasedPro {
                    purchaseButton(Purchases.proID, key: "buy", price: "demoPrice")
                        .buttonStyle(.borderedProminent)
                    if purchases.entitlement.trialClaimedAt == nil && purchases.hasPro {
                        purchaseButton(Purchases.trialID, key: "claim", price: "demoZero")
                            .buttonStyle(.bordered)
                    }
                }
                Button(L.t("restore")) { Task { await purchases.restore() } }
                    .disabled(purchases.busy)
                    .accessibilityIdentifier("paywall.restore")
                if purchases.busy { ProgressView() }
                if let message = purchases.error {
                    Text(message).font(.footnote)
                    Button(L.t("retry")) {
                        Task {
                            await purchases.start()
                            await purchases.loadProducts()
                        }
                    }
                    .accessibilityIdentifier("paywall.retry")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Palette.canvas)
        .task { await purchases.loadProducts() }
    }

    private var status: String {
        if !purchases.ready { return L.t("loading") }
        if purchases.entitlement.purchasedPro { return L.t("unlocked") }
        if !purchases.hasPro { return L.t("expired") }
        return L.f("trialEnds", purchases.entitlement.trialEnd.formatted(date: .abbreviated, time: .omitted))
    }

    private func purchaseButton(_ id: String, key: String, price: String) -> some View {
        let product = purchases.product(id)
        let displayedPrice = product?.displayPrice ?? (Launch.testing ? L.t(price) : "")
        return Button {
            if let product { Task { await purchases.buy(product) } }
        } label: {
            HStack {
                Text(L.t(key))
                Spacer()
                if !displayedPrice.isEmpty { Text(displayedPrice) }
            }
            .frame(minHeight: 32)
        }
        .disabled(purchases.busy || product == nil && !Launch.testing)
        .accessibilityIdentifier("paywall." + key)
    }
}
