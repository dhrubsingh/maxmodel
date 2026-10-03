import SwiftUI
import HearthCore

struct ComparisonView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var exampleID = "email"
    private var models: [LocalModel] { store.catalog.filter { store.comparison.contains($0.id) } }
    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Side by side", color: Theme.ember)
                    Text("Which one feels right?").font(.display(26)).tracking(-0.6)
                }
                Spacer()
                Picker("Compare", selection: $store.comparisonMode) {
                    ForEach(ComparisonMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 380).disabled(store.answerComparison.running)
                if store.answerComparison.running { Button("Stop") { store.stopOperation() }.buttonStyle(SoftButton()) }
                Button("Done") { dismiss() }.buttonStyle(SoftButton()).disabled(store.answerComparison.running).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 28).padding(.vertical, 20)
            Rectangle().fill(Theme.line).frame(height: 1)
            Group {
                switch store.comparisonMode {
                case .overview: overview
                case .examples: examples
                case .live: liveComparison
                }
            }.padding(28)
        }.frame(width: models.count > 2 ? 1040 : 840, height: 780)
            .background(Theme.paper).foregroundStyle(Theme.ink).tint(Theme.ember)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Color.clear.frame(width: 120, height: 1)
                    ForEach(models) { model in column(model) }
                }
                group("At a glance") {
                    row("Good for") { Text($0.strengths) }
                    row("Tradeoff") { Text($0.limitations).foregroundStyle(Theme.muted) }
                    row("Knows up to") { ModelKnowledgeLabel(model: $0) }
                    row("License") { Text($0.license) }
                }
                group("On this Mac") {
                    row("Fit") { model in
                        VStack(alignment: .leading, spacing: 6) {
                            FitMeter(hardware: store.hardware, model: model, profile: store.profile(for: model), compact: true)
                            Text(assistantFit(store.modelFit(model))).foregroundStyle(store.modelFit(model) == .tight ? Theme.caution : Theme.ink)
                        }
                    }
                    row("Memory") { Text(LocalModel.size(store.profile(for: $0).memory(for: $0))).font(.mono(12)) }
                    row("Download") { Text($0.diskLabel).font(.mono(12)) }
                    row("Speed") { model in
                        Text(store.assessment(model).map { readingSpeed($0.expectedTokensPerSecond, technical: store.showsTechnicalDetails) + ($0.benchmark == nil ? " · est." : " · measured") } ?? "—").font(.mono(12))
                    }
                    row("First answer") { model in
                        Text(store.assessment(model).map { "\(firstAnswer($0).label.lowercased()) \(firstAnswer($0).value)" } ?? "—").font(.mono(12))
                    }
                    row("Window") { Text("\(store.profile(for: $0).contextTokens.formatted()) tokens").font(.mono(12)) }
                }
                group("Published benchmarks") {
                    row("Score") { model in bar(store.assessment(model)?.publishedCapability, emphasis: true) }
                    ForEach(["MMLU-Pro", "GPQA Diamond", "IFEval"], id: \.self) { name in
                        row(name) { model in bar(store.assessment(model)?.evidence?.metrics.first { $0.name == name }?.value) }
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Color.clear.frame(width: 120, height: 1)
                    ForEach(models) { model in modelAction(model).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(.top, 4)
                Text("Memory and speed are estimates until measured on this Mac. Benchmarks describe full-precision weights published upstream; “—” means not published. None of these models is guaranteed to be right.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func column(_ model: LocalModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.recommended?.id == model.id { Eyebrow("Best fit", color: Theme.ember) }
            else { Eyebrow(model.family) }
            Text(model.baseName).font(.system(size: 17, weight: .semibold)).lineLimit(2)
            Text("\(Precision.shortName(model.quantization)) precision").font(.mono(11)).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(title)
            content()
        }.card(padding: 18)
    }
    private func row<Cell: View>(_ title: String, @ViewBuilder cell: @escaping (LocalModel) -> Cell) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.muted).frame(width: 106, alignment: .leading)
            ForEach(models) { model in
                cell(model).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func bar(_ value: Double?, emphasis: Bool = false) -> some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    if let value { Capsule().fill(Theme.ember.opacity(emphasis ? 1 : 0.7)).frame(width: geometry.size.width * value / 100) }
                }
            }.frame(height: 6)
            Text(value.map { String(format: "%.1f", $0) } ?? "—").font(.mono(11.5, emphasis ? .semibold : .regular))
                .foregroundStyle(value == nil ? Theme.faint : Theme.ink).frame(width: 36, alignment: .trailing)
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Example", selection: $exampleID) {
                    Text("Write an email").tag("email")
                    Text("Explain something").tag("explain")
                    Text("Admit missing information").tag("grounding")
                }.frame(maxWidth: 360)
                Spacer()
                Tag(text: "No download needed", icon: "checkmark.circle")
            }
            if let archive = store.examples, let question = archive.examples.first(where: { $0.promptID == exampleID })?.prompt {
                Text(question).font(.system(size: 13)).textSelection(.enabled).padding(.horizontal, 16).padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                ScrollView {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(models) { model in
                            VStack(alignment: .leading, spacing: 14) {
                                column(model)
                                if let example = archive.example(modelID: model.id, promptID: exampleID) {
                                    MarkdownMessageView(content: example.answer).equatable()
                                    if example.reachedLimit { Text("This example reached its length limit.").font(.system(size: 11)).foregroundStyle(Theme.caution) }
                                    Divider()
                                    Text(String(format: "Started in %.2f s in the reference test", example.firstTokenSeconds)).font(.mono(10.5)).foregroundStyle(Theme.muted)
                                } else {
                                    Text("No recorded example for this exact model yet. Download it to try your own question.")
                                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                                }
                                modelAction(model)
                            }.frame(maxWidth: .infinity, alignment: .topLeading).card(padding: 18)
                        }
                    }
                }
                Text("Recorded on \(archive.chip), \(LocalModel.size(Double(archive.memoryBytes))) memory · \(String(archive.recordedAt.prefix(10))). Saved answers from these exact models, not live results or a ranking.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else { ContentUnavailableView("Examples are unavailable", systemImage: "text.bubble", description: Text("You can still compare downloaded models with your own question.")) }
        }
    }
    private var liveComparison: some View {
        VStack(alignment: .leading, spacing: 14) {
            CompareQuestionEditor(models: models)
            if !store.answerComparison.answers.isEmpty {
                Text("Answers to: \(store.answerComparison.submittedPrompt)").font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(3)
                ScrollView {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(models) { model in
                            if let answer = store.answerComparison.answers[model.id] {
                                ComparedAnswerColumn(model: model, answer: answer)
                            }
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(models) { model in
                        VStack(alignment: .leading, spacing: 14) {
                            column(model)
                            Label(store.installed.contains(model.id) ? "Ready on this Mac" : "Needs a \(model.diskLabel) download",
                                  systemImage: store.installed.contains(model.id) ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.system(size: 12)).foregroundStyle(store.installed.contains(model.id) ? Theme.ember : Theme.muted)
                            if !store.installed.contains(model.id) || !store.hasAcceptedLicense(model) { modelAction(model) }
                        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 18)
                    }
                }
                Spacer()
            }
            Text("Your question stays on this Mac. Models answer one at a time so their memory never adds up.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
        }
    }
    private func modelAction(_ model: LocalModel) -> some View {
        Button(store.installed.contains(model.id) ? (store.hasAcceptedLicense(model) ? "Chat with this" : "Review license") : "Get · \(model.diskLabel)") {
            dismiss()
            if store.installed.contains(model.id) { store.selectModel(model) }
            else { store.requestedDownload = model }
        }.buttonStyle(PrimaryButton()).disabled(store.busy || (!store.installed.contains(model.id) && (store.downloadID != nil || store.data.offlineOnly || !store.hasRoom(model))))
    }
}

private struct CompareQuestionEditor: View {
    @Environment(AppStore.self) private var store
    let models: [LocalModel]
    private var ready: Bool { models.count >= 2 && models.allSatisfy { store.installed.contains($0.id) && store.hasAcceptedLicense($0) && store.modelFit($0) != .tight } }
    var body: some View {
        @Bindable var session = store.answerComparison
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Ask them all the same question…", text: $session.prompt, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...4).font(.system(size: 14)).disabled(session.running)
                    .accessibilityIdentifier("comparison-question")
                Button(session.running ? "Comparing…" : "Ask all") { store.compareAnswers(models: models) }
                    .buttonStyle(PrimaryButton()).disabled(store.busy || !ready || session.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
            Text(ready ? "Same question · a fresh conversation for each model" : "Download at least two models that fit this Mac (and accept any licenses) to ask your own question.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        }
    }
}

private struct ComparedAnswerColumn: View {
    @Environment(AppStore.self) private var store
    let model: LocalModel
    let answer: ComparedAnswer
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                EmberGlyph(size: 18, heat: answer.finished ? 0.6 : 1, pulsing: !answer.finished && store.answerComparison.running)
                Text(model.baseName).font(.system(size: 15, weight: .semibold))
            }
            if answer.finished { Text(answer.status).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            else { Text(answer.status).font(.system(size: 11)).shimmering() }
            if !answer.reasoning.isEmpty {
                DisclosureGroup("How it thought it through") { MarkdownMessageView(content: answer.reasoning).equatable() }.font(.system(size: 11.5))
            }
            if !answer.content.isEmpty { MarkdownMessageView(content: answer.content).equatable() }
            if let time = answer.firstTokenSeconds {
                Divider()
                Text(String(format: "Started in %.2f s", time) + (answer.tokensPerSecond.map { String(format: " · %.0f tok/s", $0) } ?? "")).font(.mono(10.5)).foregroundStyle(Theme.muted)
            }
            if answer.finished {
                Button("Continue this chat") { store.continueComparison(with: model) }.buttonStyle(PrimaryButton()).disabled(store.busy)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading).card(padding: 18)
    }
}
