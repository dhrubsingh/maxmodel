import SwiftUI
import HearthCore

/// A model's spec sheet: plain answers first, the numbers one click deeper.
struct ModelDetails: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showTechnical = false
    @State private var showKnowledge = false
    @State private var showTuning = false
    let model: LocalModel
    var body: some View {
        let assessment = store.assessment(model)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                EmberGlyph(size: 40, heat: store.installed.contains(model.id) ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("\(model.family) · \(Precision.shortName(model.quantization)) precision")
                    Text(model.baseName).font(.display(26)).tracking(-0.6)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 26).padding(.vertical, 20)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.strengths).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                    if let pick = store.discoveryPicks.first(where: { $0.id == model.id }) {
                        Label(pick.reason, systemImage: "sparkle").font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            Readout(label: store.installed.contains(model.id) ? "On disk" : "Download", value: model.diskLabel)
                            Readout(label: "Memory", value: LocalModel.size(store.profile(for: model).memory(for: model)))
                            if let assessment {
                                Readout(label: assessment.benchmark == nil ? "Speed · est." : "Speed", value: readingSpeed(assessment.expectedTokensPerSecond, technical: store.showsTechnicalDetails))
                                Readout(label: "Score", value: assessment.publishedCapability.map { String(format: "%.1f", $0) } ?? "—")
                            }
                        }
                        FitMeter(hardware: store.hardware, model: model, profile: store.profile(for: model), conditions: store.conditions)
                    }.card()
                    section("Keep in mind", model.limitations)
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow("On this Mac")
                        if let reply = store.data.replyObservations?[model.id], reply.modelSHA256 == model.sha256,
                           reply.hardwareID == store.hardware.optimizationID {
                            Text(String(format: "Your last reply started in %.1f s and ran at %.0f tokens/s.", reply.firstAnswerSeconds, reply.tokensPerSecond))
                                .font(.system(size: 13, weight: .medium))
                            Text("Measured during a real conversation on \(reply.date.formatted(date: .abbreviated, time: .omitted)). Start time includes loading and thinking.")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Timing is recorded quietly as you chat, with no extra test prompts.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        Button("Why this one, benchmarks & tuning…") { store.recommendationDetailID = model.id; showTuning = true }.buttonStyle(QuietButton())
                    }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 18)
                    DisclosureGroup(isExpanded: $showKnowledge) {
                        ModelKnowledgeDetails(model: model).padding(.top, 12)
                    } label: {
                        HStack {
                            Text("Knows things up to").font(.system(size: 12.5, weight: .semibold))
                            Spacer()
                            Text(model.knowledgeCutoffLabel).font(.mono(12)).foregroundStyle(Theme.muted)
                        }
                    }.card(padding: 16)
                    ImageSupportRow(model: model).card(padding: 16)
                    HStack {
                        Text("License").font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Link(model.license + " ↗", destination: model.licenseURL ?? model.sourceURL).font(.system(size: 12.5))
                    }.card(padding: 16)
                    if model.needsLicenseReview {
                        Label("Custom terms apply. You’ll review them before downloading.", systemImage: "doc.text").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    }
                    if model.attribution == "Built with Llama" { Text("Built with Llama").font(.system(size: 11.5, weight: .medium)) }
                    DisclosureGroup("Technical details", isExpanded: $showTechnical) {
                        VStack(alignment: .leading, spacing: 16) {
                            Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 10) {
                                row("Parameters", String(format: "%g billion", model.parameters))
                                row("Format", "GGUF · \(model.quantization)")
                                row("Architecture", model.architecture ?? "Unknown")
                                row("Conversation window", "\(store.profile(for: model).contextTokens.formatted()) tokens")
                                row("Thinking budget", "\(store.profile(for: model).thinkingTokens.formatted()) tokens")
                                row("Verification", model.validation ?? "Metadata verified")
                                row("Catalog checked", model.metadataCheckedAt ?? "Unknown")
                                row("Measured speed", store.assessment(model)?.benchmark.map { String(format: "%.0f tok/s · starts in %.2f s", $0.tokensPerSecond, $0.firstTokenSeconds) } ?? "Not measured here")
                            }
                            if store.installed.contains(model.id) {
                                Button("Run local performance & answer check") { dismiss(); store.runBenchmark(model) }.buttonStyle(SoftButton()).disabled(store.busy)
                            }
                            Text("The download is pinned to an exact revision and verified before installing and loading. Metadata verified covers the file, architecture, and license. Tested locally means this configuration has completed a real conversation test.")
                                .font(.system(size: 11, weight: .regular)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 16) {
                                Link("Original model ↗", destination: model.sourceURL)
                                Link("Download source ↗", destination: model.distributorURL)
                            }.font(.system(size: 11.5, weight: .regular))
                            VStack(alignment: .leading, spacing: 4) {
                                Eyebrow("SHA-256")
                                Text(model.sha256).font(.mono(9.5)).textSelection(.enabled).foregroundStyle(Theme.muted)
                            }
                        }.padding(.top, 14)
                    }.font(.system(size: 12.5, weight: .semibold)).card(padding: 16)
                }.padding(26)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                Text(assistantFit(store.modelFit(model))).font(.system(size: 12)).foregroundStyle(store.modelFit(model) == .tight ? Theme.caution : Theme.muted)
                Spacer()
                if store.downloadID == model.id { Text("Downloading…").font(.system(size: 12)).shimmering() }
                else {
                    Button(store.installed.contains(model.id) ? "Chat with this model" : "Get it · \(model.diskLabel)") {
                        dismiss()
                        if store.installed.contains(model.id) { store.openAssistant(model) } else { store.requestDownload(model, startChat: true) }
                    }.buttonStyle(PrimaryButton())
                        .disabled(store.installed.contains(model.id) ? store.busy : (store.downloadID != nil || store.data.offlineOnly || !store.hasRoom(model)))
                }
            }.padding(.horizontal, 26).padding(.vertical, 14)
        }.frame(width: 640, height: 720).background(Theme.paper).foregroundStyle(Theme.ink).tint(Theme.ember)
            .sheet(isPresented: $showTuning, onDismiss: { store.recommendationDetailID = nil }) { RecommendationView().environment(store) }
    }
    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(title)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 11.5, weight: .regular)).foregroundStyle(Theme.muted)
            Text(value).font(.mono(11.5)).textSelection(.enabled)
        }
    }
}

/// Whether this model can look at images, and the add-on that lets it.
private struct ImageSupportRow: View {
    @Environment(AppStore.self) private var store
    let model: LocalModel
    var body: some View {
        HStack(spacing: 10) {
            Text("Images").font(.system(size: 12.5, weight: .semibold))
            Spacer()
            switch store.imageSupport(for: model) {
            case .ready: Label("Sees images", systemImage: "eye").foregroundStyle(Theme.ink)
            case .unavailable: Text("Reads the text in images").foregroundStyle(Theme.muted)
            case .noRoom: Text("Not enough memory to see images here").foregroundStyle(Theme.muted)
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 70).tint(Theme.ember)
                Text("Adding image support · \(Int(fraction * 100))%").foregroundStyle(Theme.muted)
            case .needsDownload(let bytes):
                if store.installed.contains(model.id) {
                    Button("Add image support · \(LocalModel.size(Double(bytes)))") { store.downloadVision(model) }.buttonStyle(QuietButton())
                } else {
                    Text("Sees images · \(LocalModel.size(Double(bytes))) add-on").foregroundStyle(Theme.muted)
                }
            }
        }.font(.system(size: 12.5))
    }
}
