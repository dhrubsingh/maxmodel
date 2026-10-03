import SwiftUI
import HearthCore

enum CatalogLayout: String, CaseIterable { case cards = "Cards", benchmarks = "Benchmarks" }

struct ModelsView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Color.clear.frame(height: 0).id("assistants-top")
                    if store.filter != .recommended {
                        HStack {
                            Button { store.filter = .recommended } label: { Label("Best fit", systemImage: "chevron.left") }.buttonStyle(QuietButton())
                            Spacer()
                            if store.filter == .all && !store.libraryModels.isEmpty {
                                Button("On this Mac (\(store.libraryModels.count))") { store.filter = .installed }.buttonStyle(QuietButton())
                            }
                        }
                    }
                    switch store.filter {
                    case .recommended: DiscoveryView()
                    case .all: AssistantCatalog()
                    case .installed: AssistantLibrary()
                    }
                }.padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 30)
                    .frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }.onChange(of: store.filter) { _, _ in proxy.scrollTo("assistants-top", anchor: .top) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.filter == .all && !store.comparison.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.split.3x1").foregroundStyle(Theme.ember)
                    Text("\(store.comparison.count) of 3 to compare").font(.system(size: 12.5, weight: .medium))
                    Button("Clear") { withAnimation { store.comparison.removeAll() } }.buttonStyle(QuietButton())
                    Spacer()
                    Button("Compare side by side") { store.comparisonMode = .overview; store.showComparison = true }
                        .buttonStyle(PrimaryButton()).disabled(store.comparison.count < 2)
                }.padding(.horizontal, 40).padding(.vertical, 13).background(.regularMaterial)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }.animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.comparison.isEmpty)
    }
}

private struct AssistantCatalog: View {
    @Environment(AppStore.self) private var store
    @State private var layout = CatalogLayout.cards
    private var hasFilters: Bool { !store.search.isEmpty || !store.familyFilter.isEmpty || !store.categoryFilter.isEmpty || store.licenseFilter != .all }
    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("Models")
                    Text(store.showsFullCatalog ? (store.fitsOnly ? "Everything that fits." : "The whole catalog.") : "Top picks for this Mac.")
                        .font(.display(32)).tracking(-0.8)
                    Text("Ranked by published benchmarks, sized to this Mac. Pick one to chat, or select up to three to compare.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                Picker("Layout", selection: $layout) {
                    ForEach(CatalogLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    .onChange(of: layout) { _, value in if value == .benchmarks { store.showsFullCatalog = true } }
            }
            toolbar
            if layout == .benchmarks {
                BenchmarkTable(models: store.filteredModels).frame(height: 560)
                Text("Score combines MMLU-Pro (50%), IFEval (30%) and GPQA Diamond (20%) from publisher results for full-precision weights; “—” means not published. Speed is estimated from this Mac’s memory speed until measured here. Double-click a row for details.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else if !store.showsFullCatalog {
                if store.discoveryPicks.isEmpty {
                    Text("Our usual picks need more room than this Mac has right now. Show everything to explore smaller options.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                grid(store.discoveryPicks.map { ([$0.model], $0.title) })
                Button { withAnimation { store.showsFullCatalog = true } } label: {
                    Label("Show all \(store.catalogGroupCount) model families", systemImage: "chevron.down")
                }.buttonStyle(SoftButton())
            } else {
                HStack {
                    Text("\(store.filteredGroups.count) model families").font(.mono(11))
                    if hasFilters { Button("Reset filters") { store.resetCatalogFilters() }.buttonStyle(QuietButton()) }
                    Spacer()
                    Button("Back to top picks") { store.showsFullCatalog = false; store.resetCatalogFilters() }.buttonStyle(QuietButton())
                }.foregroundStyle(Theme.muted)
                grid(store.filteredGroups.map { ($0.models, nil) })
                if store.filteredModels.isEmpty {
                    ContentUnavailableView("Nothing matches", systemImage: "magnifyingglass", description: Text("Try another search, or include models for larger Macs."))
                        .frame(minHeight: 200)
                }
            }
        }
    }

    private struct CardItem: Identifiable { let models: [LocalModel]; let reason: String?; var id: String { models.first?.id ?? "" } }
    private func grid(_ items: [([LocalModel], String?)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
            ForEach(items.map { CardItem(models: $0.0, reason: $0.1) }) { item in ModelCard(models: item.models, reason: item.reason) }
        }
    }

    private var toolbar: some View {
        @Bindable var store = store
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search models or makers", text: $store.search).textFieldStyle(.plain).accessibilityIdentifier("catalog-search")
                    .onSubmit { store.showsFullCatalog = true }
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel("Clear search")
                }
            }.font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                .onChange(of: store.search) { _, value in if !value.isEmpty { store.showsFullCatalog = true } }
            Button { withAnimation(.spring(response: 0.3)) { store.fitsOnly.toggle() } } label: {
                Label("Fits this Mac", systemImage: store.fitsOnly ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(store.fitsOnly ? Theme.ember : Theme.muted)
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(store.fitsOnly ? Theme.emberSoft : Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(store.fitsOnly ? Theme.ember.opacity(0.4) : Theme.line))
            }.buttonStyle(.plain).accessibilityAddTraits(store.fitsOnly ? .isSelected : [])
            filterMenu("Maker", selection: $store.familyFilter, options: [("All makers", "")] + store.families.map { ($0, $0) })
            filterMenu("Use", selection: $store.categoryFilter, options: [("All uses", ""), ("Everyday", "Everyday"), ("Coding", "Coding"), ("Reasoning", "Reasoning")])
            Menu {
                Picker("License", selection: $store.licenseFilter) { ForEach(LicenseFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Sort", selection: $store.catalogSort) { ForEach(CatalogSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Optimize for", selection: Binding(get: { store.recommendationGoal }, set: store.setRecommendationGoal)) {
                    ForEach(RecommendationGoal.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Divider()
                Toggle("Show technical details", isOn: $store.showsTechnicalDetails)
            } label: { Label("More", systemImage: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("catalog-options")
        }.font(.system(size: 12))
    }
    private func filterMenu(_ title: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        Menu {
            Picker(title, selection: selection) { ForEach(options, id: \.1) { Text($0.0).tag($0.1) } }.pickerStyle(.inline).labelsHidden()
        } label: {
            Text(selection.wrappedValue.isEmpty ? title : selection.wrappedValue)
        }.menuStyle(.borderlessButton).fixedSize()
            .onChange(of: selection.wrappedValue) { _, value in if !value.isEmpty { store.showsFullCatalog = true } }
    }
}

/// A model family as a card: name, precision/size, how it fits, and one action.
private struct ModelCard: View {
    @Environment(AppStore.self) private var store
    let models: [LocalModel]
    var reason: String? = nil
    @State private var hovering = false
    private var model: LocalModel { models.first { $0.id == store.variantSelections[$0.groupID] } ?? store.preferredModel(in: models) }
    private var downloaded: Bool { store.installed.contains(model.id) }
    private var comparing: Bool { store.comparison.contains(model.id) }
    var body: some View {
        let assessment = store.assessment(model)
        let fit = store.modelFit(model)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Eyebrow(reason ?? model.taskCategory, color: reason?.hasPrefix("Recommended") == true ? Theme.ember : Theme.muted)
                Spacer(minLength: 6)
                Button { withAnimation(.spring(response: 0.3)) { store.toggleComparison(model) } } label: {
                    Image(systemName: comparing ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 15)).foregroundStyle(comparing ? Theme.ember : Theme.faint)
                        .contentTransition(.symbolEffect(.replace))
                }.buttonStyle(.plain).accessibilityLabel(comparing ? "Remove \(model.name) from comparison" : "Compare \(model.name)").help("Compare")
                    .disabled(!comparing && store.comparison.count >= 3)
            }
            HStack(spacing: 8) {
                Text(models.count == 1 ? model.baseName : model.groupID).font(.display(21)).tracking(-0.5).lineLimit(1)
                if downloaded { Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.ember).help("Downloaded") }
                Spacer(minLength: 0)
            }
            if models.count > 1 {
                Picker("Size", selection: Binding(get: { model.id }, set: { value in withAnimation(.spring(response: 0.4)) { store.variantSelections[model.groupID] = value } })) {
                    ForEach(models) { item in Text("\(item.name.components(separatedBy: " · ").dropFirst().joined(separator: " · ")) · \(item.diskLabel)").tag(item.id) }
                }.labelsHidden().font(.system(size: 11.5)).fixedSize()
            }
            Text(model.strengths).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineSpacing(2).lineLimit(2)
                .frame(minHeight: 34, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 8) {
                FitMeter(hardware: store.hardware, model: model, profile: store.profile(for: model), compact: true)
                HStack(spacing: 6) {
                    Text(assistantFit(fit)).foregroundStyle(fit == .tight ? Theme.caution : Theme.ink)
                    Text("·").foregroundStyle(Theme.faint)
                    Text(model.diskLabel).font(.mono(11))
                    if let assessment {
                        Text("·").foregroundStyle(Theme.faint)
                        Text(readingSpeed(assessment.expectedTokensPerSecond, technical: store.showsTechnicalDetails)).font(.mono(11))
                    }
                }.font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            if store.showsTechnicalDetails, let assessment {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(model.quantization) · \(Precision.shortName(model.quantization)) precision · \(assessment.profile.contextTokens.formatted()) context")
                    Text("Score \(assessment.publishedCapability.map { String(format: "%.1f", $0) } ?? "—") · " + (assessment.evidence?.metrics.map { "\($0.name) \(String(format: "%.0f", $0.value))" }.joined(separator: " · ") ?? "no published benchmarks"))
                    Text("≈ \(LocalModel.size(assessment.estimatedMemory)) memory · \(model.license)")
                    ModelKnowledgeLabel(model: model).id(model.id)
                }.font(.mono(10)).foregroundStyle(Theme.muted)
                    .padding(11).frame(maxWidth: .infinity, alignment: .leading).background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            }
            if model.needsLicenseReview { Label("Custom license", systemImage: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            Spacer(minLength: 0)
            if store.downloadID == model.id { DownloadRow(model: model) }
            else {
                HStack(spacing: 14) {
                    AssistantDownloadButton(model: model)
                    AboutAssistantButton(model: model, title: "Details")
                    Spacer(minLength: 0)
                }
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(comparing ? Theme.ember.opacity(0.6) : hovering ? Theme.faint.opacity(0.6) : Theme.line, lineWidth: comparing ? 1.5 : 1))
            .shadow(color: .black.opacity(hovering ? 0.06 : 0), radius: 14, y: 6)
            .offset(y: hovering ? -2 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct AssistantDownloadButton: View {
    @Environment(AppStore.self) private var store
    let model: LocalModel
    private var downloaded: Bool { store.installed.contains(model.id) }
    var body: some View {
        Button(downloaded ? "Chat" : (store.partials[model.id] ?? 0) > 0 ? "Resume" : "Get · \(model.diskLabel)") {
            if downloaded { store.openAssistant(model) } else { store.requestDownload(model) }
        }.buttonStyle(PrimaryButton())
            .disabled(downloaded ? (store.busy && store.selectedModel?.id != model.id) : (store.downloadID != nil || store.data.offlineOnly || !store.hasRoom(model)))
            .help(!downloaded && store.data.offlineOnly ? "Download lock is on in This Mac" : !store.hasRoom(model) ? "Not enough free storage" : model.name)
    }
}

/// Every model as rows of numbers, for people who want to compare closely.
private struct BenchmarkTable: View {
    @Environment(AppStore.self) private var store
    let models: [LocalModel]
    @State private var sortOrder = [KeyPathComparator(\BenchmarkRow.score, order: .reverse)]
    @State private var selection = Set<String>()
    struct BenchmarkRow: Identifiable {
        let id: String, name: String, precision: String
        let score: Double, mmluPro: Double, gpqa: Double, ifeval: Double
        let memory: Double, speed: Double, fits: Bool, best: Bool, downloaded: Bool
    }
    private var rows: [BenchmarkRow] {
        let sorted = unsortedRows.sorted(using: sortOrder)
        // Unpublished figures (−1) always sink to the bottom, whichever way the column is sorted.
        guard let column = sortOrder.first?.keyPath as? KeyPath<BenchmarkRow, Double> else { return sorted }
        return sorted.filter { $0[keyPath: column] >= 0 } + sorted.filter { $0[keyPath: column] < 0 }
    }
    private var unsortedRows: [BenchmarkRow] {
        models.compactMap { model in
            guard let assessment = store.assessment(model) else { return nil }
            func metric(_ name: String) -> Double { assessment.evidence?.metrics.first { $0.name == name }?.value ?? -1 }
            return BenchmarkRow(id: model.id, name: model.baseName, precision: model.quantization,
                                score: assessment.publishedCapability ?? -1, mmluPro: metric("MMLU-Pro"), gpqa: metric("GPQA Diamond"), ifeval: metric("IFEval"),
                                memory: assessment.estimatedMemory, speed: assessment.expectedTokensPerSecond,
                                fits: store.modelFit(model) != .tight, best: store.recommended?.id == model.id, downloaded: store.installed.contains(model.id))
        }
    }
    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.name) { row in
                HStack(spacing: 6) {
                    if row.best { Circle().fill(Theme.ember).frame(width: 6, height: 6).help("Best fit") }
                    Text(row.name).fontWeight(row.best ? .semibold : .regular)
                    if row.downloaded { Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.ember).font(.system(size: 10)) }
                }
            }.width(min: 150, ideal: 190)
            TableColumn("Precision", value: \.precision) { Text($0.precision).font(.mono(11)) }.width(90)
            TableColumn("Score", value: \.score) { number($0.score, bold: true) }.width(56)
            TableColumn("MMLU-Pro", value: \.mmluPro) { number($0.mmluPro) }.width(70)
            TableColumn("GPQA", value: \.gpqa) { number($0.gpqa) }.width(54)
            TableColumn("IFEval", value: \.ifeval) { number($0.ifeval) }.width(54)
            TableColumn("Memory", value: \.memory) { Text(LocalModel.size($0.memory)).font(.mono(11)) }.width(70)
            TableColumn("Speed", value: \.speed) { Text(String(format: "%.0f tok/s", $0.speed)).font(.mono(11)) }.width(76)
            TableColumn("Fits") { row in
                Image(systemName: row.fits ? "checkmark" : "xmark").foregroundStyle(row.fits ? Theme.ink : Theme.caution).font(.system(size: 10, weight: .bold))
            }.width(34)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let model = store.catalog.first(where: { $0.id == id }) {
                Button("Details") { store.requestedDetails = model }
                Button(store.comparison.contains(id) ? "Remove from comparison" : "Add to comparison") { store.toggleComparison(model) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let model = store.catalog.first(where: { $0.id == id }) { store.requestedDetails = model }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
    }
    private func number(_ value: Double, bold: Bool = false) -> some View {
        Text(value < 0 ? "—" : String(format: "%.1f", value)).font(.mono(11, bold ? .semibold : .regular))
            .foregroundStyle(value < 0 ? Theme.faint : Theme.ink)
    }
}

private struct AssistantLibrary: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("On this Mac")
                Text("Your models.").font(.display(32)).tracking(-0.8)
                Text("Keep favourites, make room when you need it. Removing a model keeps your conversations.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(LocalModel.size(store.totalDiskUsed)).font(.mono(22, .medium))
                    Text("used by models").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(LocalModel.size(Double(store.hardware.freeDisk))) free").font(.mono(12)).foregroundStyle(Theme.muted)
                }
                StorageBar(models: store.libraryModels)
                HStack {
                    Spacer()
                    Button("Find more models") { store.openCatalog() }.buttonStyle(SoftButton())
                }
            }.card()
            if store.libraryModels.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "square.stack.3d.up", description: Text("Models you download appear here."))
            }
            ForEach(store.libraryModels) { model in LibraryAssistantRow(model: model) }
        }
    }
}

/// Disk usage per model, as one bar.
private struct StorageBar: View {
    @Environment(AppStore.self) private var store
    let models: [LocalModel]
    var body: some View {
        let sizes = models.map { store.installed.contains($0.id) ? Double($0.bytes) : Double(store.partials[$0.id] ?? 0) }
        let total = max(1, sizes.reduce(0, +) + Double(store.hardware.freeDisk))
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(sizes.enumerated()), id: \.offset) { index, size in
                    Rectangle().fill(Theme.ember.opacity(1 - Double(index % 3) * 0.25))
                        .frame(width: max(3, geometry.size.width * size / total))
                        .help(models[index].name)
                }
                Rectangle().fill(Theme.raised)
            }.clipShape(Capsule())
        }.frame(height: 10)
    }
}

private struct LibraryAssistantRow: View {
    @Environment(AppStore.self) private var store
    let model: LocalModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                EmberGlyph(size: 32, heat: store.activeID == model.id ? 1 : 0.4, pulsing: store.activeID == model.id && store.generating)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name).font(.system(size: 15, weight: .semibold))
                    Text(store.installed.contains(model.id) ? "\(model.diskLabel) on disk · \(store.activeID == model.id ? "in memory" : "ready offline")" : "\(LocalModel.size(Double(store.partials[model.id] ?? 0))) of \(model.diskLabel) · \(store.downloadID == model.id ? "downloading" : "paused")")
                        .font(.mono(11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if store.downloadID != model.id { AssistantDownloadButton(model: model) }
                Menu {
                    Button("Details") { store.requestedDetails = model }
                    if store.installed.contains(model.id) {
                        Button("Run local check") { store.runBenchmark(model) }.disabled(store.busy)
                        if store.activeID == model.id { Button("Release memory") { store.unload() }.disabled(store.busy) }
                    }
                    Divider()
                    Button("Remove download…", role: .destructive) { store.requestedDelete = model }.disabled(store.busy || store.downloadID == model.id)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Manage \(model.name)")
            }
            if store.downloadID == model.id { DownloadRow(model: model) }
            if let benchmark = store.assessment(model)?.benchmark {
                Text(String(format: "Measured here: %.0f tok/s · starts in %.1f s", benchmark.tokensPerSecond, benchmark.firstTokenSeconds)).font(.mono(10.5)).foregroundStyle(Theme.muted)
            }
            if store.benchmarkID == model.id {
                HStack(spacing: 8) { StatusLight(state: .working); Text(store.status).font(.system(size: 11.5)).shimmering(); Spacer(); Button("Stop") { store.stopOperation() }.buttonStyle(QuietButton()) }
            }
        }.card(padding: 18)
    }
}
