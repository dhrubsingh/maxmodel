import SwiftUI
import HearthCore

/// "This Mac": a spec sheet that explains what limits local AI, in plain terms.
struct DeviceView: View {
    @Environment(AppStore.self) private var store
    private var focusModel: LocalModel? { store.selectedModel ?? store.homeAssistant }
    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("This Mac")
                    Text(store.hardware.chip.replacingOccurrences(of: "Apple ", with: "")).font(.display(40)).tracking(-1)
                    Text("\(LocalModel.size(Double(store.hardware.memory))) memory · \(store.hardware.cores) cores · \(store.hardware.gpu)")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                HStack(alignment: .top, spacing: 14) {
                    spec("Available to AI", LocalModel.size(store.hardware.modelBudget), "Decides how large a model can be.")
                    spec("Memory speed", "\(Int(store.hardware.memoryBandwidth.gigabytesPerSecond)) GB/s\(store.hardware.memoryBandwidth.published ? "" : "*")", "Decides how fast it writes.")
                    spec("Free disk", LocalModel.size(Double(store.hardware.freeDisk)), "\(LocalModel.size(store.totalDiskUsed)) used by models.")
                }
                if let model = focusModel {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Eyebrow("Right now")
                            Spacer()
                            Button("Recheck") { store.refresh() }.buttonStyle(QuietButton())
                        }
                        Text(store.isShortOnFreeMemory(model) ? "Other apps are crowding \(model.name)." : "\(model.name) fits with room to spare.")
                            .font(.system(size: 17, weight: .semibold))
                        FitMeter(hardware: store.hardware, model: model, profile: store.profile(for: model), conditions: store.conditions)
                    }.card()
                }
                VStack(alignment: .leading, spacing: 16) {
                    Eyebrow("Our promises")
                    promise("lock.fill", "Your chats never leave this Mac.", "Messages go only to the engine running here. No cloud AI, no analytics, no account.")
                    promise("eye.slash", "It can’t see your files.", "The model reads only what you type. It cannot browse the web or run commands.")
                    promise("arrow.down.circle", "Downloads only when you ask.", "The catalog and engine ship with the app. Only a download you start contacts Hugging Face.")
                    Divider()
                    Toggle(isOn: Binding(get: { store.data.offlineOnly }, set: { store.setOffline($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Download lock").font(.system(size: 13, weight: .semibold))
                            Text("Block new downloads. Everything you have keeps working offline.").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                    }.toggleStyle(.switch).tint(Theme.ember)
                }.card()
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow("For the curious")
                    Toggle(isOn: $store.showsTechnicalDetails) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Show technical details").font(.system(size: 13, weight: .semibold))
                            Text("Adds precision, context window, estimated speed, and benchmark figures across the app.")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                    }.toggleStyle(.switch).tint(Theme.ember)
                    Divider()
                    Text("Downloaded models use disk space; only the active one uses memory. An idle model is released after 15 minutes or when macOS needs memory, and reloads when you send. Files are stored with owner-only permissions and excluded from backups; FileVault protects them at rest.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    Text(store.storage?.root.path ?? "Storage unavailable").font(.mono(10)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    HStack(spacing: 10) {
                        Button("Show files") { store.revealStorage() }.buttonStyle(SoftButton())
                        Button("Refresh hardware") { store.refresh() }.buttonStyle(SoftButton())
                        Spacer()
                        Button("Release model memory") { store.unload() }.buttonStyle(SoftButton()).disabled(store.activeID == nil || store.busy)
                    }
                    if !store.hardware.memoryBandwidth.published {
                        Text("* Estimated for this chip tier.").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    }
                }.card()
                HStack {
                    Text("\(Theme.appName) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · llama.cpp b11146")
                    Spacer()
                    Text("\(store.hardware.architecture) · macOS 14+")
                }.font(.mono(10)).foregroundStyle(Theme.faint)
            }.padding(.horizontal, 40).padding(.top, 44).padding(.bottom, 32).frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
    private func spec(_ label: String, _ value: String, _ detail: String) -> some View {
        Readout(label: label, value: value, detail: detail, size: 24).card(padding: 18, radius: 14)
    }
    private func promise(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ember).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
