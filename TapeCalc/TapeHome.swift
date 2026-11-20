import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let sumTape = UTType(exportedAs: "com.hgsldswk.tapecalc.sumtape", conformingTo: .json)
}

private enum Panel: String, Identifiable {
    case tapes, settings, paywall
    var id: String { rawValue }
}

@MainActor struct TapeHome: View {
    @StateObject private var model = TapeModel()
    @StateObject private var purchases = Purchases()
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview
    @State private var panel: Panel?
    @State private var confirmClear = false
    @State private var importing = false
    @State private var incoming: [URL] = []
    @State private var processingImports = false
    @State private var rename = false
    @State private var name = ""
    @State private var share: ShareRequest?
    @State private var shareBusy = false
    @State private var sharePreview: UIImage?
    @State private var shareMarker: String?
    @State private var amountInput = AmountInput()
    @State private var focusedAmount: UUID?
    @FocusState private var focusedNote: UUID?
    @State private var ratingOnForeground = false
    @State private var evaluatedLaunchRating = false

    var body: some View {
        Group {
            if model.ready {
                home
            } else if model.loadFailed {
                VStack(spacing: 16) {
                    Text(L.t("loadFailed")).multilineTextAlignment(.center)
                    Button(L.t("retry")) { Task { await model.load() } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("storage.retryLoad")
                }
                .padding(24)
            } else {
                ProgressView(L.t("loading"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas.ignoresSafeArea())
        .tint(Palette.link)
        .task {
            await model.load()
            await processImports()
        }
        .task {
            await purchases.start()
            if Launch.has("-paywall") { panel = .paywall }
        }
        .onChange(of: model.ready) { _, ready in
            if ready {
                if phase == .active { considerInitialRating() }
                Task { await processImports(); await importFixture() }
            }
        }
        .onChange(of: phase) { _, current in
            switch current {
            case .background:
                ratingOnForeground = model.book.canRequestRating && share == nil
                model.flushInBackground()
            case .active:
                purchases.tick()
                considerInitialRating()
                considerRating()
            default: break
            }
        }
        .onOpenURL { url in
            incoming.append(url)
            Task { await processImports() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.sumTape]) { result in
            switch result {
            case .success(let url):
                incoming.append(url)
                Task { await processImports() }
            case .failure:
                model.error = L.t("invalidFile")
            }
        }
        .sheet(item: $panel) { panel in
            switch panel {
            case .tapes: tapesPanel
            case .settings: settingsPanel
            case .paywall: Paywall(purchases: purchases)
            }
        }
        .sheet(item: $share) { request in
            ActivitySheet(request: request) { success in
                if request.details && success { model.sharedDetails() }
                if let directory = request.temporaryDirectory {
                    Task.detached { try? FileManager.default.removeItem(at: directory) }
                }
                if share?.id == request.id { share = nil }
            }
        }
        .sheet(isPresented: Binding(
            get: { sharePreview != nil },
            set: { if !$0 { sharePreview = nil } }
        )) {
            if let image = sharePreview {
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 14) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .accessibilityLabel(L.t("shareImage"))
                            shareFeedback
                        }
                        .padding(20)
                    }
                    .background(Palette.canvas)
                    .navigationTitle(L.t("shareImage"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L.t("done")) { sharePreview = nil }.accessibilityIdentifier("preview.done")
                        }
                    }
                }
            }
        }
        .alert(L.t("clearTitle"), isPresented: $confirmClear) {
            Button(L.t("clear"), role: .destructive) { stopEditing(); model.clear() }
            Button(L.t("cancel"), role: .cancel) {}
        }
        .alert(L.t("rename"), isPresented: $rename) {
            TextField(L.t("tapeName"), text: $name)
            Button(L.t("save")) { model.rename(name) }
            Button(L.t("cancel"), role: .cancel) {}
        }
        .alert(L.t("unable"), isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button(L.t("ok")) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var home: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    stopEditing()
                    panel = .tapes
                } label: {
                    HStack(spacing: 9) {
                        Text(model.title(for: model.tape)).font(.title3.weight(.bold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                    }
                    .foregroundStyle(Palette.ink)
                    .frame(minHeight: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L.t("switchTape"))
                .accessibilityIdentifier("home.tapes")
                Spacer(minLength: 4)
                moreMenu
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            totalCard
                .padding(.horizontal, 20)
            tapeList
            if model.saveFailed {
                HStack {
                    Text(L.t("saveFailed")).font(.footnote)
                    Spacer()
                    Button(L.t("retry")) { Task { await model.flush() } }.accessibilityIdentifier("storage.retrySave")
                }
                .padding(.horizontal, 20)
            }
            if model.notice != nil || model.hasUndo {
                HStack {
                    if let notice = model.notice { Text(notice).font(.footnote).accessibilityIdentifier("home.notice") }
                    Spacer(minLength: 2)
                    if model.hasUndo {
                        Button(L.t("undo")) { stopEditing(); model.undo() }
                            .font(.footnote.weight(.bold))
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("home.undo")
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 35)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
            }
            if sharePreview == nil { shareFeedback }
            actions
            if focusedAmount != nil {
                AmountKeypad(input: amountInput, next: nextAmount, done: stopEditing)
            } else if focusedNote != nil {
                Button(L.t("done"), action: stopEditing)
                    .font(.footnote.weight(.bold)).frame(minHeight: 44)
                    .accessibilityIdentifier("note.done")
            }
        }
        .foregroundStyle(Palette.ink)
    }

    private var totalCard: some View {
        let summary = model.summary
        let pending = summary.invalid > 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(L.t(pending ? "subtotal" : "total"))
                Spacer()
                Text(pending ? L.f("pending", summary.invalid) : L.f("count", summary.valid))
                    .foregroundStyle(pending ? Palette.error : Color.white)
                    .accessibilityIdentifier("home.count")
            }
            .font(.footnote.weight(.semibold))
            Text(model.tape.formatted(summary.value))
                .font(.system(size: 56, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.38)
                .accessibilityIdentifier("home.total")
        }
        .foregroundStyle(pending ? Palette.ink : .white)
        .padding(.horizontal, 22)
        .padding(.vertical, focusedAmount == nil ? 18 : 10)
        .background(pending ? Palette.pale : Palette.blue, in: RoundedRectangle(cornerRadius: 25))
    }

    private var tapeList: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    HStack {
                        Text(L.t("note"))
                        Spacer()
                        Text(L.t("amount"))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
                    .listRowBackground(Palette.paper)
                    .listRowInsets(EdgeInsets(top: 0, leading: 15, bottom: 0, trailing: 15))

                    ForEach(Array(model.tape.lines.enumerated()), id: \.element.id) { index, line in
                        row(line, index: index)
                            .id(line.id)
                            .listRowBackground(line.canonical == nil && !line.input.trimmed.isEmpty ? Palette.errorPale : Palette.paper)
                            .listRowInsets(EdgeInsets(top: 0, leading: 15, bottom: 0, trailing: 15))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    if focusedAmount == line.id || focusedNote == line.id { stopEditing() }
                                    model.remove(line.id)
                                } label: {
                                    Label(L.t("delete"), systemImage: "trash")
                                }
                                .accessibilityIdentifier("row.delete.\(index)")
                            }
                    }

                    Button(action: addAmount) {
                        Label(L.t(model.tape.lines.isEmpty ? "firstAmount" : "add"), systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                            .foregroundStyle(Palette.link)
                            .font(.subheadline.weight(.semibold))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(L.t("paste")) { pasteClipboard() }.accessibilityIdentifier("empty.paste")
                    }
                    .accessibilityIdentifier("home.add")
                    .listRowBackground(Palette.paper)
                    .listRowInsets(EdgeInsets(top: 0, leading: 15, bottom: 0, trailing: 15))
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 15, for: .scrollContent)
            .contentMargins(.bottom, 5, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.never)
            .environment(\.defaultMinListRowHeight, 37)
            .onChange(of: focusedAmount) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func row(_ line: Line, index: Int) -> some View {
        let invalid = line.canonical == nil && !line.input.trimmed.isEmpty
        let amountText = line.canonical.flatMap { Decimal(string: $0, locale: Amount.locale) }
        let display = focusedAmount == line.id ? line.input : amountText.map(model.tape.formatted) ?? line.input
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                TextField(L.t("note"), text: Binding(
                    get: { model.tape.lines.first(where: { $0.id == line.id })?.note ?? "" },
                    set: { model.edit(line.id, note: $0) }
                ))
                .focused($focusedNote, equals: line.id)
                .foregroundStyle(Palette.ink)
                .font(.subheadline)
                .submitLabel(.done)
                .onSubmit { focusedNote = nil }
                .onChange(of: focusedNote) { _, target in
                    if target == line.id { focusedAmount = nil }
                }
                .accessibilityLabel(L.f("noteRow", index + 1))
                .accessibilityIdentifier("row.note.\(index)")
                if invalid {
                    Text(L.t(line.input.filter { $0 == "." || $0 == "．" }.count > 1 ? "oneDecimal" : "checkAmount"))
                        .font(.caption2.weight(.semibold)).foregroundStyle(Palette.error)
                }
            }
            AmountField(id: line.id, index: index, value: display, invalid: invalid, focused: focusedAmount,
                        input: amountInput, onValue: { model.edit(line.id, input: $0) },
                        onFocus: { id in focusedNote = nil; focusedAmount = id },
                        onPaste: { text in stopEditing(); model.paste(text) })
                .padding(.horizontal, invalid ? 7 : 0)
                .frame(minWidth: 90, idealWidth: 140, maxWidth: 172, minHeight: 46)
                .background(alignment: .trailing) {
                    if invalid {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Palette.error, lineWidth: 1)
                            .frame(width: 90, height: 35)
                    }
                }
        }
        .frame(minHeight: 52)
    }

    private var moreMenu: some View {
        Menu {
            Button(L.t("publicCard")) {
                let card = CardContent(title: L.f("checkedCount", model.summary.valid), subtitle: nil)
                Task { await shareCard(card, details: false) }
            }
            .disabled(!model.summary.isComplete)
            .accessibilityIdentifier("more.public")
            if model.book.hasMilestone {
                Button(L.t("milestone")) {
                    Task {
                        await shareCard(CardContent(title: L.t("milestoneTitle"), subtitle: nil, topic: L.t("milestoneTopic")),
                                        details: false)
                    }
                }
                .accessibilityIdentifier("more.milestone")
            }
            Menu(L.t("export")) {
                Button(L.t("exportTape")) { requirePro { Task { await export(csv: false) } } }
                    .accessibilityIdentifier("export.sumtape")
                Button(L.t("exportCSV")) { requirePro { Task { await export(csv: true) } } }
                    .accessibilityIdentifier("export.csv")
            }
            .disabled(!model.summary.isComplete)
            .accessibilityIdentifier("more.export")
            Button(L.t("importFile")) { stopEditing(); importing = true }.accessibilityIdentifier("more.import")
            Button(L.t("copyTopics")) { UIPasteboard.general.string = L.t("topics"); model.copied() }
                .accessibilityIdentifier("more.topics")
            Button(L.t("rename")) { stopEditing(); name = model.title(for: model.tape); rename = true }
                .accessibilityIdentifier("more.rename")
            Button(L.t("settings")) { stopEditing(); panel = .settings }.accessibilityIdentifier("more.settings")
            Button(L.t("clear"), role: .destructive) { confirmClear = true }
                .disabled(model.tape.lines.allSatisfy(\.isEmpty))
                .accessibilityIdentifier("more.clear")
        } label: {
            Text(L.t("more")).font(.subheadline.weight(.bold))
                .frame(minWidth: 48, minHeight: 46).contentShape(Rectangle())
        }
        .accessibilityIdentifier("home.more")
    }

    private var actions: some View {
        GeometryReader { geometry in
            HStack(spacing: 8) {
                let usable = geometry.size.width - 16
                action("paste", primary: true, perform: pasteClipboard).frame(width: usable * 1.35 / 3.35)
                action("copy", label: "copyDetails", enabled: model.summary.isComplete) {
                    UIPasteboard.general.string = model.text()
                    model.copied()
                }
                action("share", label: "shareDetails", enabled: model.summary.isComplete && !shareBusy) {
                    let card = CardContent.details(model.tape, title: model.title(for: model.tape))
                    let text = model.text()
                    Task { await shareCard(card, details: true, text: text) }
                }
            }
        }
        .frame(height: 49)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func action(_ key: String, label: String? = nil, primary: Bool = false,
                        enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(L.t(key))
                .font(.subheadline.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.65)
                .foregroundStyle(primary ? Color.white : enabled ? Palette.link : Palette.muted)
                .frame(maxWidth: .infinity, minHeight: 49)
                .padding(.horizontal, primary ? 12 : 2)
                .background(primary ? Palette.blue : Palette.pale.opacity(enabled ? 1 : 0.55),
                            in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(L.t(label ?? key))
        .accessibilityIdentifier("home." + key)
    }

    @ViewBuilder private var shareFeedback: some View {
        if let shareMarker {
            Text(shareMarker)
                .font(.footnote).foregroundStyle(Palette.link)
                .accessibilityIdentifier("share.requested")
        }
    }

    private var tapesPanel: some View {
        NavigationStack {
            List {
                Section(L.t("tapes")) {
                    ForEach(Array(model.book.tapes.enumerated()), id: \.element.id) { index, tape in
                        Button {
                            model.select(tape.id)
                            panel = nil
                        } label: {
                            HStack {
                                Text(model.title(for: tape))
                                Spacer()
                                if tape.id == model.book.currentID { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityIdentifier("tape.select.\(index)")
                    }
                }
                Section {
                    Button(L.t("newTape")) { create() }.accessibilityIdentifier("tape.new")
                    Button(L.t("mealTemplate")) { create("mealTemplate", notes: ["meal", "drinks", "transport"]) }
                        .accessibilityIdentifier("tape.meal")
                    Button(L.t("expenseTemplate")) { create("expenseTemplate", notes: ["transport", "meal", "other"]) }
                        .accessibilityIdentifier("tape.expenses")
                }
            }
            .navigationTitle(L.t("tapes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closePanel }
        }
    }

    private var settingsPanel: some View {
        NavigationStack {
            Form {
                Section(L.t("privacy")) { Text(L.t("privacyBody")) }
                Button(L.t("rate")) { requestReview() }.accessibilityIdentifier("settings.rate")
                if !Launch.isFree {
                    NavigationLink {
                        PurchaseContent(purchases: purchases)
                            .navigationTitle(L.t("pro"))
                    } label: {
                        Text(L.t("pro"))
                    }
                    .accessibilityIdentifier("settings.pro")
                    Button(L.t("restore")) { Task { await purchases.restore() } }
                        .disabled(purchases.busy)
                        .accessibilityIdentifier("settings.restore")
                    if let error = purchases.error {
                        Text(error).font(.footnote).accessibilityIdentifier("settings.purchaseStatus")
                    }
                }
            }
            .navigationTitle(L.t("settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closePanel }
        }
    }

    private var closePanel: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(L.t("done")) { panel = nil }.accessibilityIdentifier("panel.done")
        }
    }

    private func create(_ title: String? = nil, notes: [String] = []) {
        requirePro {
            let name = title.map(L.t) ?? L.f("numberedTape", model.book.tapes.count + 1)
            model.create(name, notes: notes.map(L.t))
            panel = nil
        }
    }

    private func requirePro(_ perform: () -> Void) {
        stopEditing()
        purchases.tick()
        if purchases.hasPro { perform() }
        else { panel = .paywall }
    }

    private func addAmount() {
        focusedNote = nil
        if let row = model.add() { focusedAmount = row }
    }

    private func nextAmount() {
        guard let id = focusedAmount, let index = model.tape.lines.firstIndex(where: { $0.id == id }) else { return }
        if model.tape.lines.indices.contains(index + 1) {
            focusedAmount = model.tape.lines[index + 1].id
        } else {
            addAmount()
        }
    }

    private func stopEditing() {
        focusedAmount = nil
        focusedNote = nil
        amountInput.field?.resignFirstResponder()
    }

    private func pasteClipboard() {
        stopEditing()
        let contents = Launch.testing ? ProcessInfo.processInfo.environment["TAPECALC_PASTE"] ?? UIPasteboard.general.string
            : UIPasteboard.general.string
        model.paste(contents ?? "")
    }

    private func processImports() async {
        guard model.ready, !processingImports else { return }
        processingImports = true
        defer { processingImports = false }
        while !incoming.isEmpty {
            stopEditing()
            await model.importFile(incoming.removeFirst())
        }
    }

    private func importFixture() async {
        guard Launch.has("-import-fixture"), let raw = ProcessInfo.processInfo.environment["TAPECALC_IMPORT"] else { return }
        do {
            let url = try await Task.detached {
                try Self.stage(Data(raw.utf8), extension: "sumtape")
            }.value
            await model.importFile(url)
            Task.detached { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        } catch {
            model.error = L.t("invalidFile")
        }
    }

    private func shareCard(_ card: CardContent, details: Bool, text: String? = nil) async {
        guard !shareBusy, share == nil else { return }
        stopEditing()
        shareBusy = true
        shareMarker = nil
        defer { shareBusy = false }
        let image = card.rows.count <= ShareRules.maxRows ? await CardRenderer.image(card, demo: Launch.has("-store-demo")) : nil
        if let image, let png = image.pngData() {
            do {
                let url = try await Task.detached { try Self.stage(png, extension: "png") }.value
                publish(ShareRequest(items: [url], details: details, temporaryDirectory: url.deletingLastPathComponent()),
                        kind: "shareImage", preview: image)
            } catch {
                if let text { publish(ShareRequest(items: [text], details: details), kind: "shareText") }
                else { model.error = L.t("shareFailed") }
            }
        } else if let text {
            publish(ShareRequest(items: [text], details: details), kind: "shareText")
        } else {
            model.error = L.t("shareFailed")
        }
    }

    private func export(csv: Bool) async {
        guard !shareBusy, share == nil, model.summary.isComplete else { return }
        shareBusy = true
        shareMarker = nil
        defer { shareBusy = false }
        let tape = model.tape
        let amount = L.t("amount")
        let note = L.t("note")
        do {
            let url = try await Task.detached {
                let data = csv ? TapeTransfer.csv(tape, amount: amount, note: note) : try TapeTransfer.file(tape)
                return try Self.stage(data, extension: csv ? "csv" : "sumtape")
            }.value
            publish(ShareRequest(items: [url], temporaryDirectory: url.deletingLastPathComponent()), kind: "shareFile")
        } catch {
            model.error = (error as? TapeIssue)?.message ?? L.t("shareFailed")
        }
    }

    private nonisolated static func stage(_ data: Data, extension suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("TapeCalc").appendingPathExtension(suffix)
        do { try data.write(to: url, options: .atomic) }
        catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return url
    }

    private func publish(_ request: ShareRequest, kind: String, preview: UIImage? = nil) {
        if Launch.testing {
            shareMarker = L.t(kind)
            if Launch.has("-store-demo") { sharePreview = preview }
            if let directory = request.temporaryDirectory {
                Task.detached { try? FileManager.default.removeItem(at: directory) }
            }
            return
        }
        share = request
    }

    private func considerInitialRating() {
        guard model.ready, !evaluatedLaunchRating else { return }
        evaluatedLaunchRating = true
        ratingOnForeground = model.book.canRequestRating
        considerRating()
    }

    private func considerRating() {
        guard ratingOnForeground else { return }
        ratingOnForeground = false
        guard !Launch.testing, model.book.canRequestRating, model.ready,
              model.error == nil, !model.saveFailed, model.summary.invalid == 0,
              panel == nil, share == nil, !shareBusy, !importing, !processingImports, incoming.isEmpty,
              focusedAmount == nil, focusedNote == nil, !confirmClear, !rename else { return }
        model.markRatingRequested()
        requestReview()
    }
}
