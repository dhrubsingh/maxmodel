import SwiftUI
import Charts
import HearthCore

/// "Why this one?": the recommendation, shown as evidence rather than asserted.
struct RecommendationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = ""
    @State private var showMethod = false
    @State private var showAdvanced = false
    private var report: RecommendationReport { store.recommendationReport }
    private var options: [LocalModel] {
        var seen = Set<String>()
        return (report.choices.map(\.model) + store.installedModels + store.catalog).filter { seen.insert($0.id).inserted }
    }
    private var model: LocalModel? { store.catalog.first { $0.id == selectedID } ?? report.recommended?.model ?? store.homeAssistant }
    private var ranked: [ModelAssessment] {
        report.assessments.filter(\.eligible).sorted { ($0.capability ?? 0) > ($1.capability ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(model?.id == report.recommended?.id ? "Why this one" : "How it compares", color: Theme.ember)
                    Text(model?.baseName ?? "No model fits yet").font(.display(26)).tracking(-0.6)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 28).padding(.vertical, 20)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !report.choices.isEmpty { choiceStrip }
                    if let model, let assessment = report.assessment(model.id) {
                        reasons(model, assessment)
                        comparisonChart(highlight: model)
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow("Fit on this Mac")
                            FitMeter(hardware: store.hardware, model: model, profile: assessment.profile, conditions: store.conditions)
                        }.card()
                        benchmarks(assessment)
                        actions(model)
                        advanced(model, assessment)
                    }
                    controls
                    method
                    HStack {
                        Label("Hardware checks and inference stay on this Mac.", systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Spacer()
                        Button("Refresh Mac check") { store.refresh() }.buttonStyle(QuietButton())
                    }
                }.padding(28)
            }
        }.frame(width: 760, height: 800).background(Theme.paper).foregroundStyle(Theme.ink).tint(Theme.ember)
            .onAppear { selectedID = store.recommendationDetailID ?? report.recommended?.id ?? store.homeAssistant?.id ?? "" }
            .onChange(of: store.recommendationGoal) { _, _ in selectedID = report.recommended?.id ?? selectedID }
    }

    private var choiceStrip: some View {
        HStack(spacing: 10) {
            ForEach(report.choices) { choice in
                let selected = model?.id == choice.id
                Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { selectedID = choice.id } } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Eyebrow(choice.id == report.recommended?.id ? "Our pick" : "Alternative", color: choice.id == report.recommended?.id ? Theme.ember : Theme.muted)
                        Text(choice.model.baseName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(Precision.shortName(choice.model.quantization)) · \(choice.model.diskLabel)").font(.mono(10.5)).foregroundStyle(Theme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(selected ? Theme.emberSoft : Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.ember.opacity(0.55) : Theme.line, lineWidth: selected ? 1.5 : 1))
                }.buttonStyle(.plain).accessibilityLabel("Inspect \(choice.model.name)")
            }
        }
    }

    private func reasons(_ model: LocalModel, _ assessment: ModelAssessment) -> some View {
        let rank = ranked.firstIndex { $0.id == model.id }.map { $0 + 1 }
        return HStack(alignment: .top, spacing: 12) {
            reason("trophy", "Smart", rank.map { "#\($0) of \(ranked.count)" } ?? "Unranked",
                   rank == nil ? "Not enough published benchmarks to rank it." : "among models that fit this Mac, on published benchmarks.")
            reason("memorychip", "Fits", "\(LocalModel.size(assessment.estimatedMemory))",
                   "of \(LocalModel.size(store.hardware.modelBudget)) this Mac can give AI.")
            reason("hare", "Quick enough", readingSpeed(assessment.expectedTokensPerSecond, technical: store.showsTechnicalDetails),
                   "\(firstAnswer(assessment).label.lowercased()) \(firstAnswer(assessment).value)\(assessment.profile.isThinking ? " on hard questions" : "")\(assessment.benchmark == nil ? " (estimated)" : " (measured)").")
        }
    }
    private func reason(_ icon: String, _ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ember)
            Text(value).font(.mono(22, .medium)).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .topLeading).card(padding: 16, radius: 14)
    }

    private struct ChartRow: Identifiable {
        let id: String, name: String, score: Double, kind: String
    }
    /// The best-scoring configuration of each model, with ones that don't fit shown for context.
    private func chartRows(highlight: LocalModel) -> [ChartRow] {
        var best: [String: ModelAssessment] = [:]
        for assessment in report.assessments where assessment.capability != nil {
            let key = assessment.model.baseModelID
            let fits = store.modelFit(assessment.model) != .tight
            if assessment.id == highlight.id { best[key] = assessment; continue }
            if let current = best[key] {
                if current.id == highlight.id { continue }
                let currentFits = store.modelFit(current.model) != .tight
                if (fits && !currentFits) || (fits == currentFits && (assessment.capability ?? 0) > (current.capability ?? 0)) { best[key] = assessment }
            } else { best[key] = assessment }
        }
        return best.values.sorted { ($0.capability ?? 0) > ($1.capability ?? 0) }.prefix(10).map { assessment in
            let kind = assessment.id == highlight.id ? "This model" : store.modelFit(assessment.model) == .tight ? "Too big for this Mac" : "Fits"
            return ChartRow(id: assessment.id, name: assessment.model.baseName, score: assessment.capability ?? 0, kind: kind)
        }
    }
    private func comparisonChart(highlight: LocalModel) -> some View {
        let rows = chartRows(highlight: highlight)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow("How it compares")
                Spacer()
                Text("Published benchmark score").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Chart(rows) { row in
                BarMark(x: .value("Score", row.score), y: .value("Model", row.name))
                    .foregroundStyle(by: .value("Kind", row.kind))
                    .cornerRadius(4)
                    .annotation(position: .trailing, spacing: 6) {
                        Text(String(format: "%.1f", row.score)).font(.mono(10.5, row.kind == "This model" ? .semibold : .regular))
                            .foregroundStyle(row.kind == "Too big for this Mac" ? Theme.faint : Theme.ink)
                    }
            }
            .chartForegroundStyleScale(["This model": Theme.ember, "Fits": Theme.ink.opacity(0.32), "Too big for this Mac": Theme.faint.opacity(0.35)])
            .chartXScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 11)) } }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: CGFloat(rows.count) * 28 + 40)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: highlight.id)
            Text("Larger is not automatically smarter: models are compared head to head on the benchmarks both have published.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.card()
    }

    private func benchmarks(_ assessment: ModelAssessment) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow("Published benchmarks")
                Spacer()
                Text(assessment.evidenceLabel).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            if let metrics = assessment.evidence?.metrics, !metrics.isEmpty {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(metric.name).font(.system(size: 12.5, weight: .semibold))
                            Text(metric.dimension).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            Spacer()
                            Text(String(format: "%.1f", metric.value)).font(.mono(13, .medium))
                            Link(destination: metric.sourceURL) { Image(systemName: "arrow.up.right.square") }.help("Source")
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.raised)
                                Capsule().fill(Theme.ember.opacity(0.85)).frame(width: geometry.size.width * metric.value / 100)
                            }
                        }.frame(height: 6)
                        Text(metric.setting).font(.system(size: 10.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(assessment.evidence?.note ?? "No reviewed evidence is available for this model yet. It can still be downloaded and compared.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.card()
    }

    @ViewBuilder private func actions(_ model: LocalModel) -> some View {
        if store.calibrationID == model.id {
            HStack(spacing: 8) { StatusLight(state: .working); Text(store.status).font(.system(size: 12)).shimmering(); Spacer(); Button("Stop check") { store.stopOperation() }.buttonStyle(SoftButton()) }
        } else {
            HStack(spacing: 14) {
                Button(store.installed.contains(model.id) ? "Chat with this model" : "Get it · \(model.diskLabel)") {
                    dismiss()
                    if store.installed.contains(model.id) { store.selectModel(model) }
                    else { store.requestDownload(model, startChat: true) }
                }.buttonStyle(PrimaryButton(large: true)).disabled(store.busy || (!store.installed.contains(model.id) && (store.downloadID != nil || store.data.offlineOnly || !store.hasRoom(model))))
                Text("\(model.license)\(model.needsLicenseReview ? " · custom terms" : "")\(model.attribution == "Built with Llama" ? " · Built with Llama" : "")")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Tune the recommendation")
            Picker("Optimize for", selection: Binding(get: { store.recommendationGoal }, set: store.setRecommendationGoal)) {
                ForEach(RecommendationGoal.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(store.busy).accessibilityIdentifier("recommendation-goal")
            Text(store.recommendationGoal.explanation).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            Picker("Look at another model", selection: $selectedID) {
                ForEach(options) { Text($0.name + (store.installed.contains($0.id) ? " · downloaded" : "")).tag($0.id) }
            }.font(.system(size: 12)).accessibilityIdentifier("recommendation-model")
        }.card()
    }

    private func advanced(_ model: LocalModel, _ assessment: ModelAssessment) -> some View {
        DisclosureGroup("Advanced · memory, local checks & tuning", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Conversation memory", selection: Binding(get: { store.conversationMemory }, set: store.setConversationMemory)) {
                        ForEach(ConversationMemory.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).disabled(store.busy).accessibilityIdentifier("conversation-memory")
                    Text(store.conversationMemory == .longer
                         ? "Keep more of a long chat in view: up to 64K tokens within this model’s limit and available memory. Reading long inputs takes longer."
                         : "A lighter window for everyday questions. Longer chats keep more earlier messages available to the model.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    if assessment.profile.cacheType == .q8_0 {
                        Label("Compact conversation cache · makes more room for this chat", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.ember)
                    }
                }
                if let benchmark = assessment.benchmark {
                    HStack {
                        Label(String(format: "%.0f tokens/s", benchmark.tokensPerSecond), systemImage: "speedometer")
                        if let memory = benchmark.processMemoryBytes { Text("· \(LocalModel.size(Double(memory))) process memory") }
                        Spacer()
                        Text(benchmark.date, style: .date)
                    }.font(.mono(10.5)).foregroundStyle(Theme.muted)
                    if let checks = benchmark.checks {
                        Text("Basic answer checks: \(checks.filter(\.passed).count) of \(checks.count) passed. These check simple instructions, arithmetic, and supplied facts—not overall intelligence.")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        ForEach(checks, id: \.name) { check in
                            Label(check.name, systemImage: check.passed ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.system(size: 10.5)).foregroundStyle(check.passed ? Theme.ink : Theme.caution)
                        }
                    }
                    if let check = benchmark.contextCheck {
                        Label("Long-memory check: \(check.matchedFacts)/\(check.totalFacts) facts found in \(check.promptTokens.formatted()) input tokens", systemImage: check.passed ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.system(size: 11)).foregroundStyle(check.passed ? Theme.ink : Theme.caution)
                        Text(String(format: "First answer %.1f s. A synthetic retrieval check, not proof of understanding every long document or the whole configured window.", check.firstAnswerSeconds))
                            .font(.system(size: 10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        if let response = check.response {
                            DisclosureGroup("See the check’s answer") {
                                Text(response).textSelection(.enabled).font(.mono(10)).padding(.top, 6)
                            }.font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                        }
                    }
                } else if store.data.benchmarks[model.id] != nil {
                    Text("An earlier test used a different configuration or is older than 30 days. Recheck to use it in this recommendation.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                if let optimization = store.optimization(for: model) {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Checked on this Mac", systemImage: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
                        Text(optimization.summary).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup("See what was tried") {
                            ForEach(Array(optimization.trials.enumerated()), id: \.offset) { _, trial in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(trial.name + (trial.samples.isEmpty ? "" : String(format: " · %.1f s", trial.seconds))).fontWeight(.medium)
                                    Text(trial.note).foregroundStyle(Theme.muted)
                                }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text("Timings cover three synthetic tasks, not all conversations. Results belong to these exact weights, settings, hardware, OS, and engine. They expire after 30 days. No extra model is downloaded.")
                                .foregroundStyle(Theme.muted).padding(.top, 5)
                            Button("Restore automatic settings") { store.resetOptimization(model) }.buttonStyle(QuietButton()).disabled(store.busy)
                        }.font(.system(size: 10.5))
                    }.padding(14).background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                }
                if store.installed.contains(model.id) && store.calibrationID != model.id {
                    HStack(spacing: 10) {
                        Button("Run local check") { store.runBenchmark(model) }.buttonStyle(SoftButton()).disabled(store.busy)
                        Button { store.optimizeModel(model) } label: { Label("Tune for this Mac", systemImage: "slider.horizontal.3") }
                            .buttonStyle(SoftButton()).disabled(store.busy).accessibilityIdentifier("optimize-model")
                    }
                    Text("An optional deeper check of CPU use, processing batches, GPU sampling, and compatible token drafting. Allow several minutes; you can stop at any time. Uses synthetic text, keeps your chats untouched, and retains only repeatable gains.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    if store.conversationMemory == .longer {
                        Button("Check longer memory on this Mac") { store.runBenchmark(model, includeContext: true) }.buttonStyle(QuietButton()).disabled(store.busy)
                        Text("Uses synthetic text only. This may take a few minutes; you can stop it.").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Allow compact conversation cache when it helps", isOn: Binding(get: { store.compactCache }, set: store.setCompactCache))
                        .disabled(store.busy).accessibilityIdentifier("compact-cache").foregroundStyle(Theme.ink)
                    Text("Q8 compresses the attention cache, not the model’s weights. It uses about 47% fewer cache bytes than FP16, with a possible accuracy tradeoff. Savings in total app memory vary by model; estimates are conservative for hybrid and sliding-window models.")
                    if let geometry = assessment.profile.cacheGeometry { Text(geometry.description) }
                    Text("At most two context checkpoints are retained to bound extra memory. This can require rereading more text after large edits to earlier context.")
                    Text("\(model.quantization) · llama.cpp b11146 · \(assessment.profile.cacheType.title) conversation cache").font(.mono(10))
                    Text("\(assessment.profile.threads) CPU threads · \(assessment.profile.thinkingTokens.formatted()) thinking-token budget · Metal GPU acceleration when supported").font(.mono(10))
                    Text(assessment.profile.execution.summary)
                    let generation = GenerationPolicy.forModel(model, thinking: assessment.profile.isThinking)
                    Text("\(generation.title) · temperature \(generation.temperature.formatted()) · top-p \(generation.topP.formatted()) · top-k \(generation.topK)").font(.mono(10))
                    if let source = generation.sourceURL { Link("Why these generation settings ↗", destination: source) }
                    Text("Budget for AI on this Mac: \(LocalModel.size(assessment.memoryBudget)), after a reserve for macOS. Available right now: \(LocalModel.size(store.conditions.budget(for: store.hardware))). Estimates, not guarantees.")
                    Text("Memory pressure: \(store.conditions.pressure >= 4 ? "high" : store.conditions.pressure >= 2 ? "elevated" : "normal"). \(store.conditions.lowPower ? "Low Power Mode is on." : "Low Power Mode is off.") \(store.conditions.thermal >= 2 ? "This Mac is warm; performance may be reduced." : "")")
                    if store.engine?.activeModelID == model.id, let active = store.engine?.activeProfile, active != assessment.profile {
                        Text("The current chat is still using its previous \(active.contextTokens.formatted())-token setup. Use this model again to apply the new plan.")
                    }
                    Text("One model is loaded at a time. Switching releases the previous model's memory and keeps your saved conversations.")
                }.font(.system(size: 10.5, weight: .regular)).foregroundStyle(Theme.muted)
            }.padding(.top, 14)
        }.font(.system(size: 12.5, weight: .semibold)).accessibilityIdentifier("advanced-settings").card(padding: 18)
    }

    private var method: some View {
        DisclosureGroup("How \(Theme.appName) makes a recommendation", isExpanded: $showMethod) {
            VStack(alignment: .leading, spacing: 14) {
                explanation("1", "Read this Mac", "Chip, memory, the GPU’s memory allowance, and free storage. The pick reflects what this Mac can run, not what happens to be free right now; if other apps hold memory, we say so separately. Your files and chats are never inspected.")
                explanation("2", "Find the smartest model that fits and keeps pace", "Models are compared head to head on reviewed knowledge, reasoning, and instruction benchmarks, then the exact download plus conversation memory is budgeted. Memory speed sets how fast a model can write, so speed is estimated too: a model must think long enough to earn its published results and still start answering within the goal’s wait.")
                explanation("3", "Check and tune it here", "Optional synthetic prompts measure response delay, speed, and process memory. Thinking time adapts to measured speed. Tune for this Mac compares compatible execution settings and keeps only repeatable gains. Results stay here and feed back into suggestions.")
                Text("\(report.rankedCount) of \(store.catalog.count) configurations have enough reviewed evidence to rank; \(report.eligibleCount) pass the current constraints. Evidence checked \(store.recommendationEvidence?.checkedAt ?? "unknown").")
                    .font(.system(size: 11, weight: .regular)).foregroundStyle(Theme.muted)
                Text("Ranking policy: MMLU-Pro 50%, IFEval 30%, GPQA Diamond 20%. Two models are compared only on the benchmarks both have published (at least two), so a missing test never helps or hurts either side; the model with the fewest head-to-head losses leads. Q4 and finer precisions rank equally, since their differences are within benchmark noise; more compressed files lose a disclosed allowance (IQ4 0.5 points, Q3 1.5, IQ3 2, Q2 7). Best answers treats models within \(RecommendationPlanner.capabilityTieBand.formatted()) points of the leader as tied and picks the fastest. Balanced chooses a less demanding model within 5 points of the leader; Light & quick uses a 15-point band. No missing score is invented.")
                    .font(.system(size: 10.5, weight: .regular)).foregroundStyle(Theme.muted)
                Text("Speed targets: at least \(Int(store.recommendationGoal.minimumSpeed)) tokens/s and a first answer within \(Int(store.recommendationGoal.maximumFirstAnswer)) seconds. Before download, speed is estimated as \(Int(SpeedEstimate.bandwidthEfficiency * 100))% of this chip’s rated memory bandwidth (\(Int(store.hardware.memoryBandwidth.gigabytesPerSecond)) GB/s\(store.hardware.memoryBandwidth.published ? "" : ", estimated for an unlisted chip")) divided by the weights read per token. Models that rely on thinking need room for at least \(RecommendationPlanner.minimumThinkingTokens) thinking tokens within the wait. A matching local test from the last 30 days replaces the estimate. A short check cannot establish overall intelligence or factual accuracy.")
                    .font(.system(size: 10.5, weight: .regular)).foregroundStyle(Theme.muted)
            }.padding(.top, 14)
        }.font(.system(size: 12.5, weight: .semibold)).card(padding: 18)
    }
    private func explanation(_ number: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.mono(11, .semibold)).foregroundStyle(Theme.ember).frame(width: 24, height: 24).background(Theme.emberSoft, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(text).font(.system(size: 11.5, weight: .regular)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Kept for screens that summarize measured performance in one line.
struct AssistantPerformanceLine: View {
    @Environment(AppStore.self) private var store
    let model: LocalModel
    var body: some View {
        if let assessment = store.assessment(model) {
            HStack(spacing: 8) {
                Image(systemName: assessment.benchmark == nil ? "gauge.with.dots.needle.33percent" : "checkmark.seal")
                Text(assessment.performanceLabel).lineLimit(2)
                Spacer(minLength: 4)
                Button("Why this one?") { store.recommendationDetailID = model.id; store.showRecommendation = true }.buttonStyle(QuietButton())
            }.font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
}
