import SwiftUI
import AppKit
import HearthCore

extension AppPage {
    var title: String { self == .chat ? "Chat" : self == .models ? "Models" : "This Mac" }
    var symbol: String { self == .chat ? "bubble.left.and.text.bubble.right" : self == .models ? "square.stack.3d.up" : "laptopcomputer" }
}

extension AppStore {
    var engineState: StatusLight.State {
        if generating { return .working }
        if busy && (activeID == nil || activeID != selectedModel?.id) { return .warming }
        return activeID != nil ? .ready : .idle
    }
}

struct ContentView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            Sidebar().frame(width: 232)
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                if let error = store.error { errorBanner(error) }
                PageHost(store: store, page: store.page)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.paper)
        }
        .foregroundStyle(Theme.ink).tint(Theme.ember)
        .overlay(alignment: .top) { CelebrationOverlay() }
        .sheet(isPresented: $store.showComparison) { ComparisonView().environment(store) }
        .sheet(item: $store.requestedDownload, onDismiss: { store.downloadStartsChat = false }) { model in DownloadModelSheet(model: model).environment(store) }
        .sheet(item: $store.requestedDetails) { model in ModelDetails(model: model).environment(store) }
        .sheet(isPresented: $store.showRecommendation, onDismiss: { store.recommendationDetailID = nil }) { RecommendationView().environment(store) }
        .alert("Remove model files?", isPresented: Binding(get: { store.requestedDelete != nil }, set: { if !$0 { store.requestedDelete = nil } })) {
            Button("Cancel", role: .cancel) { store.requestedDelete = nil }
            Button("Remove", role: .destructive) { if let model = store.requestedDelete { store.deleteModel(model) }; store.requestedDelete = nil }
        } message: {
            if let model = store.requestedDelete { Text("Remove \(model.name) and its download files? Your conversations stay saved. You'll need to download it again to use it.") }
        }
        .alert("This model may struggle", isPresented: Binding(get: { store.requestedHeavyModel != nil }, set: { if !$0 { store.requestedHeavyModel = nil } })) {
            Button("Cancel", role: .cancel) { store.requestedHeavyModel = nil }
            Button("Try anyway") { if let model = store.requestedHeavyModel { store.selectModel(model, allowHeavy: true) }; store.requestedHeavyModel = nil }
        } message: { Text("It needs more memory than this Mac comfortably has for AI. Other apps may slow down. A smaller model or precision is recommended.") }
        .alert("Delete conversation?", isPresented: Binding(get: { store.requestedChatDelete != nil }, set: { if !$0 { store.requestedChatDelete = nil } })) {
            Button("Cancel", role: .cancel) { store.requestedChatDelete = nil }
            Button("Delete", role: .destructive) { if let id = store.requestedChatDelete { store.deleteChat(id) }; store.requestedChatDelete = nil }
        } message: { Text("This conversation will be removed from this Mac. This cannot be undone.") }
    }
    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
            VStack(alignment: .leading, spacing: 9) {
                Text(error).font(.system(size: 12)).textSelection(.enabled)
                if store.recovery != nil {
                    HStack(spacing: 16) {
                        Button("Try again") { store.recover() }.disabled(store.busy || store.downloadID != nil)
                        Button("Manage storage") { store.page = .models; store.filter = .installed }
                        Button("Choose another model") { store.openCatalog() }
                    }.buttonStyle(QuietButton())
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { withAnimation { store.error = nil } } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel("Dismiss error")
        }.padding(.horizontal, 22).padding(.vertical, 13).background(Theme.caution.opacity(0.1))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.caution.opacity(0.25)).frame(height: 1) }
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The once-only moment a model finishes downloading: a burst of embers and a plain promise.
private struct CelebrationOverlay: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if let celebration = store.celebration {
            ZStack(alignment: .top) {
                if !reduceMotion { EmberBurst(start: celebration.date).frame(width: 520, height: 360) }
                HStack(spacing: 14) {
                    EmberGlyph(size: 30, heat: 1, pulsing: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(celebration.model.name) is yours.").font(.system(size: 14, weight: .semibold))
                        Label("Verified and installed. It works offline from now on.", systemImage: "wifi.slash")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Button { store.celebration = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel("Dismiss")
                }.padding(.horizontal, 18).padding(.vertical, 14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.ember.opacity(0.35)))
                    .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
                    .padding(.top, 22)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            .task(id: celebration) {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.easeOut(duration: 0.3)) { if store.celebration == celebration { store.celebration = nil } }
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                EmberGlyph(size: 24, heat: store.engineState == .idle ? 0.35 : 1, pulsing: store.engineState == .working)
                Text(Theme.appName).font(.system(size: 19, weight: .bold)).tracking(-0.5)
            }.padding(.top, 44).padding(.bottom, 22).padding(.horizontal, 6)
            Button { store.newChat() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.and.pencil")
                    Text("New chat")
                    Spacer()
                    Text("⌘N").font(.mono(10)).foregroundStyle(Theme.faint)
                }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 9)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.bottom, 14)
            ForEach(AppPage.allCases, id: \.self) { page in
                Button { store.page = page } label: {
                    HStack(spacing: 10) {
                        Image(systemName: page.symbol).frame(width: 18).foregroundStyle(store.page == page ? Theme.ember : Theme.muted)
                        Text(page.title).font(.system(size: 13, weight: store.page == page ? .semibold : .medium))
                        Spacer()
                        if page == .models && !store.installed.isEmpty {
                            Text("\(store.installed.count)").font(.mono(10, .medium)).foregroundStyle(Theme.muted)
                        }
                    }.padding(.horizontal, 11).padding(.vertical, 8)
                        .background(store.page == page ? Theme.surface.opacity(0.9) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.bottom, 2).accessibilityIdentifier("nav-\(page.rawValue)")
                    .accessibilityLabel(page.title)
            }
            Eyebrow("Recent").padding(.top, 24).padding(.bottom, 8).padding(.horizontal, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if store.data.conversations.isEmpty {
                        Text("Your chats live here, and only here.").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.horizontal, 6).padding(.top, 2)
                    }
                    ForEach(store.data.conversations) { chat in
                        let selected = store.conversationID == chat.id && store.page == .chat
                        Button { store.openChat(chat) } label: {
                            HStack(spacing: 7) {
                                Text(chat.title).font(.system(size: 12.5, weight: selected ? .medium : .regular)).lineLimit(1)
                                Spacer(minLength: 0)
                                if store.streamingReply?.conversationID == chat.id {
                                    StatusLight(state: .working).accessibilityLabel("Reply in progress")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9).padding(.vertical, 7)
                                .background(selected ? Theme.ember.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .contextMenu { Button("Delete conversation", role: .destructive) { store.requestedChatDelete = chat.id }.disabled(store.busy) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 12)
            EngineCard().padding(.bottom, 12)
            Label("Nothing leaves this Mac", systemImage: "lock.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 6).padding(.bottom, 20)
        }.padding(.horizontal, 14).background(Theme.sidebar)
    }
}

/// What is running right now, in one glance.
private struct EngineCard: View {
    @Environment(AppStore.self) private var store
    private var model: LocalModel? {
        store.catalog.first { $0.id == (store.activeID ?? store.selectedModel?.id) }
    }
    var body: some View {
        if let model, !store.installedModels.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    StatusLight(state: store.engineState)
                    Text(stateText).font(.mono(10, .medium)).foregroundStyle(store.engineState == .idle ? Theme.muted : Theme.ember).tracking(0.5)
                    Spacer()
                    if store.activeID != nil && !store.busy {
                        Button { store.unload() } label: { Image(systemName: "eject").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Release memory · the download stays")
                            .accessibilityLabel("Release model memory")
                    }
                }
                Text(model.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                Text(store.engineState == .idle ? "Loads when you send" : "\(LocalModel.size(store.profile(for: model).memory(for: model))) in memory · offline")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(store.engineState == .idle ? Theme.line : Theme.ember.opacity(0.35)))
                .animation(.easeOut(duration: 0.25), value: store.engineState)
        }
    }
    private var stateText: String {
        switch store.engineState {
        case .idle: return "IDLE"
        case .warming: return "WARMING UP"
        case .ready: return "READY"
        case .working: return "WRITING"
        }
    }
}

struct DownloadRow: View {
    @Environment(AppStore.self) private var store
    let model: LocalModel
    private var fraction: Double { store.downloadProgress?.fraction ?? Double(store.partials[model.id] ?? 0) / Double(max(1, model.bytes)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if store.verifying { Text("Checking every byte…").font(.system(size: 12, weight: .medium)).shimmering() }
                else { Text("Downloading").font(.system(size: 12, weight: .medium)) }
                Spacer()
                if !store.verifying { Button("Pause") { store.pauseDownload() }.buttonStyle(QuietButton()) }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(LinearGradient(colors: [Theme.ember, Theme.emberDeep], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geometry.size.width * (store.verifying ? 1 : fraction)))
                        .animation(.easeOut(duration: 0.35), value: fraction)
                }
            }.frame(height: 6)
            HStack {
                Text("\(LocalModel.size(Double(store.downloadProgress?.received ?? store.partials[model.id] ?? 0))) of \(model.diskLabel)")
                    .font(.mono(11)).contentTransition(.numericText())
                Spacer()
                if let seconds = store.downloadProgress?.secondsRemaining {
                    Text(seconds < 60 ? "under a minute" : "≈ \(Int(ceil(seconds / 60))) min left").font(.mono(11))
                }
            }.foregroundStyle(Theme.muted)
        }
    }
}
