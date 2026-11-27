import SwiftUI
import UIKit

enum Palette {
    static let blue = Color(red: 35 / 255, green: 74 / 255, blue: 216 / 255)
    static let pale = adaptive(0xeaf0ff, 0x253151)
    static let canvas = adaptive(0xf4f6fa, 0x111723)
    static let paper = adaptive(0xffffff, 0x1b2333)
    static let ink = adaptive(0x17223a, 0xecf1ff)
    static let muted = adaptive(0x53617a, 0xb4c0d7)
    static let link = adaptive(0x1b39ad, 0xb2c2ff)
    static let error = adaptive(0xa22338, 0xffa5b3)
    static let errorPale = adaptive(0xfff0f2, 0x3a202b)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

struct CardRow: Identifiable {
    let id: UUID
    let note: String
    let amount: String
}

struct CardContent {
    let title: String
    let subtitle: String?
    var rows: [CardRow] = []
    var total: String?
    var topic = L.t("topics")

    static func details(_ tape: Tape, title: String) -> CardContent {
        CardContent(title: title, subtitle: L.f("detailCount", tape.summary.valid),
                    rows: tape.lines.compactMap { line in
                        guard let canonical = line.canonical,
                              let number = Decimal(string: canonical, locale: Amount.locale) else { return nil }
                        return CardRow(id: line.id, note: line.note, amount: tape.formatted(number))
                    }, total: tape.formatted(tape.summary.value))
    }
}

struct ShareCard: View {
    let content: CardContent
    let qr: CGImage?
    let demo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(content.title).font(.system(size: 22, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                if let subtitle = content.subtitle {
                    Text(subtitle).font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.blue)

            if let total = content.total {
                VStack(spacing: 0) {
                    ForEach(content.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.note).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 2)
                            Text(row.amount).font(.system(size: 16, weight: .semibold).monospacedDigit())
                                .fixedSize()
                        }
                        .padding(.vertical, 11)
                        Divider()
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(L.t("total")).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text(total).font(.system(size: 28, weight: .bold).monospacedDigit()).foregroundStyle(Palette.link)
                    }
                    .padding(.vertical, 14)
                }
                .padding(.horizontal, 19)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("appName")).font(.system(size: 14, weight: .bold))
                    Text(content.topic).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    if demo || qr == nil {
                        Text(L.t(demo ? "qrSample" : "qrPlaceholder"))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 0)
                if let qr {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none).resizable().frame(width: 84, height: 84)
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 33)).foregroundStyle(Palette.muted)
                        .frame(width: 84, height: 84)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.pale)
        }
        .foregroundStyle(Palette.ink)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 21))
        .background(RoundedRectangle(cornerRadius: 21).fill(.white))
        .environment(\.colorScheme, .light)
    }
}

@MainActor enum CardRenderer {
    static func image(_ card: CardContent, demo: Bool = false) async -> UIImage? {
        let appID = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String ?? ""
        let address = demo ? "TapeCalc demo" : ShareQR.storeURL(appID: appID)?.absoluteString
        let qr = await Task.detached(priority: .userInitiated) { address.flatMap { ShareQR.image(for: $0) } }.value
        let view = ShareCard(content: card, qr: qr, demo: demo).frame(width: 353)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: 353, height: nil)
        var fits = false
        renderer.render { size, _ in fits = ShareRules.prefersImage(rows: card.rows.count, height: Double(size.height)) }
        guard fits else { return nil }
        return renderer.uiImage
    }
}

struct ShareRequest: Identifiable {
    let id = UUID()
    let items: [Any]
    var details = false
    var temporaryDirectory: URL?
}

struct ActivitySheet: UIViewControllerRepresentable {
    let request: ShareRequest
    let complete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: request.items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, success, _, _ in
            DispatchQueue.main.async { complete(success) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
