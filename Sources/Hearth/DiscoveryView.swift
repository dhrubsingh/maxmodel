import SwiftUI
import HearthCore

extension LocalModel {
    /// "Qwen3.5 · 27B · High precision" → "Qwen3.5 · 27B". Precision is shown separately;
    /// other name parts (like "Qwen distills · 7B") are kept.
    var baseName: String {
        var parts = name.components(separatedBy: " · ")
        if parts.count > 2, ["Compact", "High precision", "Near full precision", "Standard"].contains(parts.last ?? "") { parts.removeLast() }
        return parts.joined(separator: " · ")
    }
}

/// Thinking models spend time reasoning before they answer; say so instead of implying a fixed wait.
func firstAnswer(_ assessment: ModelAssessment) -> (label: String, value: String) {
    let value = assessment.expectedFirstAnswerLabel.replacingOccurrences(of: "about ", with: "≈ ")
    return assessment.profile.isThinking ? ("Thinks up to", value) : ("Answers start", value)
}

/// Words are easier to picture than tokens. English averages about 0.75 words per token.
func readingSpeed(_ tokensPerSecond: Double, technical: Bool) -> String {
    technical ? String(format: "%.0f tok/s", tokensPerSecond) : String(format: "%.0f words/s", tokensPerSecond * 0.75)
}

/// Home: read this Mac, then answer one question — the smartest model it can run.
struct DiscoveryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var scanned = false
    private let steps = 5
    private var model: LocalModel? { store.homeAssistant }
    private var ready: Bool { model.map { store.installed.contains($0.id) } ?? false }
    private var done: Bool { step > steps }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if done { summary.transition(.opacity) } else { scan.transition(.opacity) }
            if done {
                Group {
                    if let model { HeroCard(model: model) }
                    else { nothingFits }
                }.transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                trustStrip
                exploreRow
            }
        }
        .task {
            guard !scanned else { return }
            scanned = true
            await runScan(animated: !reduceMotion && !ready)
        }
    }

    private func runScan(animated: Bool) async {
        guard animated else { step = steps + 1; return }
        step = 0
        for index in 1...(steps + 1) {
            try? await Task.sleep(for: .milliseconds(index > steps ? 420 : 240))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { step = index }
        }
    }

    private var scanLines: [(String, String)] {
        let hardware = store.hardware
        return [
            ("Chip", hardware.chip.replacingOccurrences(of: "Apple ", with: "")),
            ("Memory", LocalModel.size(Double(hardware.memory))),
            ("Available to AI", LocalModel.size(hardware.modelBudget)),
            ("Memory speed", "\(Int(hardware.memoryBandwidth.gigabytesPerSecond)) GB/s"),
            ("Models compared", "\(store.recommendationReport.rankedCount)"),
        ]
    }

    private var scan: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                EmberGlyph(size: 30, heat: 1, pulsing: true)
                Text("Reading your Mac…").font(.display(26)).tracking(-0.5).shimmering()
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(scanLines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 12) {
                        Image(systemName: step > index ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(step > index ? Theme.ember : Theme.faint)
                            .contentTransition(.symbolEffect(.replace))
                        Text(line.0).font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 140, alignment: .leading)
                        Text(step > index ? line.1 : "—").font(.mono(14, .medium)).contentTransition(.numericText())
                    }.opacity(step >= index ? 1 : 0.35)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 28, radius: 22)
            .accessibilityElement(children: .combine).accessibilityLabel("Reading your Mac")
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer").foregroundStyle(Theme.muted)
            Text(scanLines.prefix(4).map(\.1).joined(separator: "  ·  ")).font(.mono(11.5)).foregroundStyle(Theme.muted)
                .lineLimit(1).help("Chip · memory · available to AI · memory speed")
            Spacer()
            Button {
                store.refresh()
                Task { await runScan(animated: !reduceMotion) }
            } label: { Label("Rescan", systemImage: "arrow.clockwise") }.buttonStyle(QuietButton())
            Button("How we choose") { store.recommendationDetailID = model?.id; store.showRecommendation = true }.buttonStyle(QuietButton())
        }
    }

    private var nothingFits: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("No fit yet", color: Theme.caution)
            Text("Let’s make some room.").font(.display(28)).tracking(-0.6)
            Text("The usual picks need more free memory or disk space than this Mac has right now. Smaller models still work well for everyday questions.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("See smaller models") { store.openCatalog(); store.showsFullCatalog = true; store.catalogSort = .size }.buttonStyle(PrimaryButton())
                Button("Check this Mac") { store.page = .device }.buttonStyle(SoftButton())
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 30, radius: 22)
    }

    private var trustStrip: some View {
        HStack(spacing: 0) {
            trust("Free forever", "gift")
            Spacer()
            trust("Nothing leaves this Mac", "lock.fill")
            Spacer()
            trust("Works offline", "wifi.slash")
            Spacer()
            trust("No account", "person.crop.circle.badge.xmark")
        }.padding(.horizontal, 8)
    }
    private func trust(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.muted)
    }

    private var exploreRow: some View {
        VStack(spacing: 0) {
            row(icon: "square.stack.3d.up", title: ready ? "Try another model" : "Compare other models",
                detail: "Every model that fits, with benchmarks and side-by-side answers.") { store.openCatalog() }
            if !store.libraryModels.isEmpty {
                Divider().padding(.leading, 44)
                row(icon: "internaldrive", title: "\(store.installed.count) downloaded · \(LocalModel.size(store.totalDiskUsed))",
                    detail: "Manage what’s on this Mac.") { store.filter = .installed }
            }
        }.card(padding: 6, radius: 16)
    }
    private func row(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.ember).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            }.padding(.horizontal, 12).padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// The answer, presented like a well-made object: name, precision, fit, speed, one action.
private struct HeroCard: View {
    @Environment(AppStore.self) private var store
    let model: LocalModel
    private var variants: [LocalModel] {
        store.catalog.filter { $0.baseModelID == model.baseModelID }.sorted { $0.bytes < $1.bytes }
    }
    private var shown: LocalModel { variants.first { $0.id == store.variantSelections[model.baseModelID] } ?? model }
    private var ready: Bool { store.installed.contains(shown.id) }
    private var downloading: Bool { store.downloadID == shown.id }
    private var paused: Bool { !ready && (store.partials[shown.id] ?? 0) > 0 }
    private var isBestFit: Bool { store.recommended?.id == shown.id }
    private var technical: Bool { store.showsTechnicalDetails }

    var body: some View {
        let assessment = store.assessment(shown)
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(ready ? "Your model" : isBestFit ? "Best fit for this Mac" : "Your pick", color: Theme.ember)
                    Text(shown.baseName).font(.display(38)).tracking(-1.1).lineLimit(2)
                    Text(ready ? shown.strengths : isBestFit ? "The smartest model your \(store.hardware.chip.replacingOccurrences(of: "Apple ", with: "")) can run, judged on published benchmarks." : shown.strengths)
                        .font(.system(size: 14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                EmberGlyph(size: 64, heat: ready ? 1 : 0.6, pulsing: downloading)
            }
            if variants.count > 1 { precisionPicker }
            FitMeter(hardware: store.hardware, model: shown, profile: store.profile(for: shown), conditions: store.conditions,
                     progress: downloading ? (store.verifying ? 1 : store.downloadProgress?.fraction ?? 0) : nil)
            HStack(alignment: .top, spacing: 14) {
                Readout(label: ready ? "On disk" : "Download", value: shown.diskLabel)
                if let assessment {
                    Readout(label: assessment.benchmark == nil ? "Speed · est." : "Speed", value: readingSpeed(assessment.expectedTokensPerSecond, technical: technical))
                    Readout(label: firstAnswer(assessment).label, value: firstAnswer(assessment).value,
                            detail: assessment.profile.isThinking ? "on hard questions; simple ones start sooner" : nil)
                }
                if technical, let assessment {
                    Readout(label: "Score", value: assessment.publishedCapability.map { String(format: "%.1f", $0) } ?? "—")
                    Readout(label: "Context", value: "\(assessment.profile.contextTokens / 1024)K")
                }
            }
            if downloading {
                DownloadRow(model: shown)
            } else {
                HStack(spacing: 16) {
                    Button {
                        if ready { store.openAssistant(shown) } else { store.requestDownload(shown, startChat: true) }
                    } label: {
                        HStack(spacing: 8) {
                            Text(ready ? "Start chatting" : paused ? "Resume download" : "Get it · \(shown.diskLabel)")
                            Image(systemName: ready ? "arrow.right" : "arrow.down").font(.system(size: 12, weight: .bold))
                        }
                    }.buttonStyle(PrimaryButton(large: true))
                        .disabled(ready ? (store.busy && store.selectedModel?.id != shown.id) : (store.downloadID != nil || store.data.offlineOnly || !store.hasRoom(shown)))
                    Button("Why this one?") { store.recommendationDetailID = shown.id; store.showRecommendation = true }.buttonStyle(QuietButton())
                    AboutAssistantButton(model: shown, title: "Details")
                    Spacer(minLength: 0)
                }
                if ready && store.busy {
                    HStack(spacing: 8) { StatusLight(state: .warming); Text(store.status).font(.system(size: 11.5)).shimmering() }
                }
                if store.data.offlineOnly && !ready {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                        Text("Download lock is on.")
                        Button("Change in This Mac") { store.page = .device }.buttonStyle(QuietButton())
                    }.font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                } else if !ready && !store.hasRoom(shown) {
                    Text("Free \(LocalModel.size(Double(shown.bytes - store.hardware.freeDisk) + 128 * 1024 * 1024)) of disk space to download this.").font(.system(size: 11.5)).foregroundStyle(Theme.caution)
                }
            }
            if shown.needsLicenseReview || shown.attribution == "Built with Llama" {
                HStack(spacing: 10) {
                    if shown.needsLicenseReview { Label("Custom license · you’ll review it before downloading", systemImage: "doc.text") }
                    if shown.attribution == "Built with Llama" { Text("Built with Llama") }
                }.font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(30).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.surface)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(RadialGradient(colors: [Theme.ember.opacity(ready ? 0.16 : 0.1), .clear], center: .center, startRadius: 0, endRadius: 220))
                        .frame(width: 440, height: 440).offset(x: 140, y: -170).allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.05), radius: 24, y: 10)
    }

    private var precisionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow("Precision")
                Spacer()
                Text(Precision.explanation(shown.quantization)).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 6) {
                ForEach(variants) { variant in
                    let fits = store.modelFit(variant) != .tight
                    let selected = variant.id == shown.id
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { store.variantSelections[model.baseModelID] = variant.id }
                    } label: {
                        VStack(spacing: 3) {
                            HStack(spacing: 4) {
                                Text(Precision.shortName(variant.quantization)).font(.system(size: 12.5, weight: .semibold))
                                if store.recommended?.id == variant.id { Circle().fill(Theme.ember).frame(width: 5, height: 5) }
                                if store.installed.contains(variant.id) { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                            }
                            Text(fits ? variant.diskLabel : "Too big").font(.mono(10.5)).foregroundStyle(fits ? Theme.muted : Theme.caution)
                        }.frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(selected ? Theme.emberSoft : Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.ember.opacity(0.6) : .clear, lineWidth: 1.5))
                            .opacity(fits ? 1 : 0.55).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(store.downloadID != nil || (!fits && !store.installed.contains(variant.id)))
                        .accessibilityLabel("\(Precision.shortName(variant.quantization)) precision, \(variant.diskLabel)\(fits ? "" : ", too big for this Mac")")
                }
            }
        }
    }
}

struct AboutAssistantButton: View {
    @Environment(AppStore.self) private var store
    let model: LocalModel
    var title = "About this model"
    var body: some View {
        Button(title) { store.requestedDetails = model }.buttonStyle(QuietButton())
            .accessibilityLabel("About \(model.name)")
    }
}

func assistantFit(_ fit: Hardware.Fit) -> String {
    switch fit {
    case .comfortable: return "Fits comfortably"
    case .heavy: return "Fits, with less room for other apps"
    case .tight: return "Too big for this Mac"
    }
}
