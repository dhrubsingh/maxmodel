import SwiftUI
import HearthCore

struct DownloadModelSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let model: LocalModel
    @State private var accepted = false
    private var alreadyInstalled: Bool { store.installed.contains(model.id) }
    private var needsAcceptance: Bool { model.needsLicenseReview && !store.hasAcceptedLicense(model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                EmberGlyph(size: 40, heat: 0.8)
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(alreadyInstalled ? "Review license" : "Get this model", color: Theme.ember)
                    Text(model.baseName).font(.display(24)).tracking(-0.5)
                }
                Spacer()
                Tag(text: model.license, warm: model.needsLicenseReview)
            }
            if !alreadyInstalled {
                FitMeter(hardware: store.hardware, model: model, profile: store.profile(for: model), conditions: store.conditions)
                    .card(padding: 16, radius: 14)
                VStack(alignment: .leading, spacing: 9) {
                    step("arrow.down.circle", "A one-time \(model.diskLabel) download from \(model.distributorURL.lastPathComponent). Pause and resume any time.")
                    if let vision = model.vision {
                        step("eye", "Then \(LocalModel.size(Double(vision.bytes))) of image support, so it can look at screenshots and photos. You can chat while it arrives.")
                    }
                    step("checkmark.shield", "Every byte is checked against a pinned fingerprint before it runs.")
                    step("wifi.slash", "After that it runs entirely on this Mac, with or without internet.")
                }
                if model.validation != "Tested locally" {
                    Text("File, architecture, and license are verified. This exact configuration hasn’t yet been through \(Theme.appName)’s local conversation tests.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.attribution == "Built with Llama" { Text("Built with Llama").font(.system(size: 12, weight: .semibold)) }
            HStack(spacing: 14) {
                ModelKnowledgeLabel(model: model)
                Spacer()
                Link("Original model ↗", destination: model.sourceURL)
                Link("License ↗", destination: model.licenseURL ?? model.sourceURL)
                ForEach((model.noticeFiles ?? []).filter { $0.filename.uppercased().contains("POLICY") }, id: \.filename) { notice in
                    Link("Use policy ↗", destination: notice.sourceURL)
                }
            }.font(.system(size: 11))
            if model.needsLicenseReview {
                Text(model.licenseID == "qwen-research" ? "Research license · review the permitted uses carefully." : "Custom terms · usage and redistribution conditions apply.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.caution)
                ScrollView {
                    Text(verbatim: model.licenseText).font(.system(size: 11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.frame(height: 200).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                if needsAcceptance {
                    Toggle("I have reviewed and accept this model’s license and applicable use policies, and my intended use is permitted.", isOn: $accepted)
                        .toggleStyle(.checkbox).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                } else { Label("You accepted this version of the terms on this Mac.", systemImage: "checkmark.circle").font(.system(size: 12)) }
            }
            Text("Original license documents, attribution, and download provenance are kept with the model files. \(Theme.appName) does not change the publisher’s terms.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            if !alreadyInstalled && !store.hasRoom(model) { Text("Free more disk space before downloading this model.").font(.system(size: 12)).foregroundStyle(Theme.caution) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
                Spacer()
                Button(alreadyInstalled ? "Continue" : "Download \(model.diskLabel)") {
                    if alreadyInstalled {
                        if accepted, let digest = model.licenseSHA256 {
                            if store.data.acceptedLicenses == nil { store.data.acceptedLicenses = [:] }
                            store.data.acceptedLicenses?[model.id] = digest; store.save()
                        }
                        dismiss(); store.selectModel(model)
                    } else { store.beginDownload(model, acceptedLicense: accepted, openChatWhenReady: store.downloadStartsChat); dismiss() }
                }.buttonStyle(PrimaryButton(large: true)).keyboardShortcut(.defaultAction)
                    .disabled((needsAcceptance && !accepted) || (!alreadyInstalled && (store.data.offlineOnly || store.downloadID != nil || !store.hasRoom(model))))
            }
        }.padding(28).frame(width: 620).background(Theme.paper).foregroundStyle(Theme.ink).tint(Theme.ember)
    }
    private func step(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.ember).frame(width: 18)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
