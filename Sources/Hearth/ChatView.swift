import SwiftUI
import AppKit
import HearthCore

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @State private var followsLatest = true
    @State private var dropTargeted = false
    var body: some View {
        content
            .onDrop(of: AttachmentInput.types + [.fileURL], isTargeted: $dropTargeted) { providers in
                !store.installedModels.isEmpty && AttachmentInput.load(providers, into: store)
            }
            .overlay { if dropTargeted && !store.installedModels.isEmpty { DropOverlay() } }
            .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }
    private var content: some View {
        VStack(spacing: 0) {
            header
            if store.generationIsElsewhere {
                strip("Your other reply is still running. You can keep drafting here.", action: "View reply") { store.showRunningConversation() }
            } else if store.calibrationID != nil {
                strip(store.status, action: "Stop check") { store.stopOperation() }
            }
            if store.conversation?.messages.isEmpty != false { welcome }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(store.conversation?.messages ?? []) { message in
                                MessageView(savedMessage: message,
                                            modelName: store.catalog.first { $0.id == message.modelID }?.name ?? Theme.appName,
                                            liveReply: store.streamingReply?.messageID == message.id ? store.streamingReply : nil,
                                            library: store.storage?.attachments)
                                    .equatable()
                                if message.id == store.conversation?.messages.last?.id && message.role == "assistant" && !store.generating {
                                    ReplyActions(message: message)
                                }
                            }
                            ChatScrollAnchor(reply: store.generationIsElsewhere ? nil : store.streamingReply, followsLatest: followsLatest) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }.id("bottom")
                        }.frame(maxWidth: 740).padding(.horizontal, 32).padding(.vertical, 30).frame(maxWidth: .infinity)
                            .background(ChatScrollObserver { followsLatest = $0 })
                    }
                        .defaultScrollAnchor(.bottom)
                        .onChange(of: store.conversationID) { _, _ in followsLatest = true; proxy.scrollTo("bottom", anchor: .bottom) }
                        .onChange(of: store.conversation?.messages.count) { _, _ in followsLatest = true; proxy.scrollTo("bottom", anchor: .bottom) }
                        .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                        .overlay(alignment: .bottom) {
                            if !followsLatest {
                                Button { followsLatest = true; withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                                    Label("Latest", systemImage: "arrow.down")
                                }.buttonStyle(SoftButton()).padding(.bottom, 10).shadow(color: .black.opacity(0.1), radius: 8)
                                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                            }
                        }
                }
            }
            if let notice = store.contextNotice {
                Label(notice, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.caution)
                    .padding(.horizontal, 36).padding(.bottom, 8).frame(maxWidth: 840, alignment: .leading)
            }
            if !store.installedModels.isEmpty { ChatComposer() }
            HStack(spacing: 6) {
                Text("Runs on this Mac · AI can make mistakes")
                if let model = store.selectedModel { Text("·"); AboutAssistantButton(model: model) }
            }.font(.system(size: 10.5)).foregroundStyle(Theme.faint).padding(.bottom, 14)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(store.conversation?.title ?? "New chat").font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Spacer()
            if !store.installedModels.isEmpty { ModelPill() }
            Button { store.newChat() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).foregroundStyle(Theme.muted).help("New chat (⌘N)")
            if store.conversation != nil {
                Menu {
                    Button("Export conversation…") { store.exportConversation() }
                    Button("Delete conversation…", role: .destructive) { store.requestedChatDelete = store.conversationID }.disabled(store.busy)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func strip(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            StatusLight(state: .working)
            Text(text).lineLimit(1)
            Spacer()
            Button(action, action: perform).buttonStyle(QuietButton())
        }.font(.system(size: 11.5)).padding(.horizontal, 28).padding(.vertical, 10).background(Theme.emberSoft.opacity(0.6))
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            EmberGlyph(size: 54, heat: store.engineState == .idle ? 0.5 : 1, pulsing: store.engineState == .warming)
                .padding(.bottom, 4)
            if store.installedModels.isEmpty {
                Text("No model yet.").font(.display(30)).tracking(-0.6)
                Text("Let’s find the smartest one your Mac can run. It takes one download.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                Button("Find my model") { store.page = .models; store.filter = .recommended }.buttonStyle(PrimaryButton(large: true)).padding(.top, 6)
            } else {
                Text("What’s on your mind?").font(.display(30)).tracking(-0.6)
                Group {
                    if store.engineState == .warming { Text("Warming up \(store.selectedModel?.name ?? "your model")…").shimmering() }
                    else { Text("\(store.selectedModel?.name ?? "Your model") · running entirely on this Mac").foregroundStyle(Theme.muted) }
                }.font(.system(size: 13))
                HStack(spacing: 12) {
                    starter("Rewrite something", "Paste a draft. Get it clearer.", "Help me rewrite this clearly:\n\n", "pencil.line")
                    starter("Explain a concept", "Anything you’re curious about.", "Explain this in simple terms: ", "lightbulb")
                    starter("Think it through", "Talk through a decision.", "Help me think through this decision: ", "point.3.connected.trianglepath.dotted")
                }.padding(.top, 14)
                Label("Drop in a screenshot, photo, or PDF to ask about it. It never leaves this Mac.", systemImage: "paperclip")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 4)
            }
            Spacer(); Spacer().frame(height: 20)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func starter(_ title: String, _ detail: String, _ prompt: String, _ icon: String) -> some View {
        StarterCard(title: title, detail: detail, icon: icon) { store.useStarter(prompt) }
    }
}

private struct StarterCard: View {
    let title: String, detail: String, icon: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.ember)
                    .frame(width: 22, height: 20, alignment: .leading)
                    .symbolEffect(.bounce, value: hovering)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(2).multilineTextAlignment(.leading)
            }.frame(width: 168, height: 96, alignment: .topLeading).padding(15)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hovering ? Theme.ember.opacity(0.45) : Theme.line))
                .offset(y: hovering ? -2 : 0)
                .shadow(color: .black.opacity(hovering ? 0.06 : 0), radius: 10, y: 5)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

/// Which model you are talking to, with its live state, switchable in place.
private struct ModelPill: View {
    @Environment(AppStore.self) private var store
    @State private var hovering = false
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                StatusLight(state: store.engineState)
                Text(store.selectedModel?.name ?? "Choose model").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }.padding(.horizontal, 11).padding(.vertical, 6)
                .background(hovering || open ? Theme.raised : Theme.surface, in: Capsule()).overlay(Capsule().strokeBorder(Theme.line))
                .contentShape(Capsule())
        }.buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: open)
            .disabled(store.busy).opacity(store.busy ? 0.6 : 1)
            .help(store.busy ? "Available when the current reply finishes" : "Switch model")
            .accessibilityLabel("Model: \(store.selectedModel?.name ?? "none"). Switch model")
            .popover(isPresented: $open, arrowEdge: .bottom) { ModelSwitcher { open = false } }
    }
}

/// Downloaded models, one click to switch. Lives in a popover so it can show fit and state.
private struct ModelSwitcher: View {
    @Environment(AppStore.self) private var store
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow("On this Mac").padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(store.installedModels) { model in
                SwitcherRow(model: model, selected: model.id == store.selectedModel?.id) {
                    close()
                    if model.id != store.selectedModel?.id { store.selectModel(model) }
                }
            }
            Divider().padding(.vertical, 6)
            Button { close(); store.requestedDetails = store.selectedModel } label: {
                Label("About this model", systemImage: "info.circle").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6).disabled(store.selectedModel == nil)
            Button { close(); store.openCatalog() } label: {
                Label("Find another model", systemImage: "plus.circle").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6)
        }.font(.system(size: 12.5)).padding(10).frame(width: 320).foregroundStyle(Theme.ink).tint(Theme.ember)
    }
}

private struct SwitcherRow: View {
    @Environment(AppStore.self) private var store
    let model: LocalModel
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StatusLight(state: store.activeID == model.id ? store.engineState : .idle)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.baseName).font(.system(size: 13, weight: .semibold))
                        if store.recommended?.id == model.id { Tag(text: "Best fit") }
                        if model.canSeeImages { Tag(text: "Sees images", icon: "eye") }
                    }
                    Text("\(Precision.shortName(model.quantization)) · \(model.diskLabel) · \(store.activeID == model.id ? "in memory" : "loads in a few seconds")")
                        .font(.mono(10.5)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ember) }
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .background(hovering ? Theme.raised : selected ? Theme.emberSoft.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

private struct ReplyActions: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage
    var body: some View {
        HStack(spacing: 16) {
            Button { store.retryLastReply() } label: {
                Label(message.interrupted ? "Retry" : "Try again", systemImage: "arrow.clockwise")
            }.help("Get a new answer. The previous one stays under Earlier answers.")
                .accessibilityIdentifier("retry-reply")
            if !message.content.isEmpty {
                Button { store.continueReply() } label: { Label("Continue", systemImage: "text.append") }
                    .accessibilityIdentifier("continue-reply")
            }
            Button { store.editLastQuestion() } label: { Label("Edit question", systemImage: "pencil") }
                .help("Edit in a new conversation. The original is kept.")
                .accessibilityIdentifier("edit-question")
            Spacer(minLength: 8)
            if message.failure == nil, !message.content.isEmpty, let modelID = message.modelID,
               let reply = store.data.replyObservations?[modelID], abs(reply.date.timeIntervalSince(message.date)) < 600 {
                Text(String(format: "%.0f tok/s · started in %.1f s · on this Mac", reply.tokensPerSecond, reply.firstAnswerSeconds))
                    .font(.mono(10)).foregroundStyle(Theme.faint).help("Measured during this reply")
            }
            if message.failure != nil {
                Menu("Use another model") {
                    ForEach(store.installedModels.filter { $0.id != store.selectedModel?.id }) { model in
                        Button(model.name) { store.selectModel(model) }
                    }
                    Button("Find another model…") { store.openCatalog() }
                }.menuStyle(.borderlessButton).fixedSize()
            }
        }.buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.muted)
            .disabled(store.busy).padding(.top, -14).padding(.leading, 30)
    }
}

private struct ChatComposer: View {
    @Environment(AppStore.self) private var store
    @FocusState private var composerFocused: Bool
    @State private var choosingFiles = false
    @State private var pasteMonitor: Any?
    private var empty: Bool { store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.draftAttachments.isEmpty }
    private var reading: Bool { !store.currentPendingAttachments.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerAttachments()
            field
        }.padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(composerFocused ? Theme.ember.opacity(0.5) : Theme.line, lineWidth: composerFocused ? 1.5 : 1))
            .shadow(color: Theme.ember.opacity(composerFocused ? 0.12 : 0), radius: 14, y: 4)
            .animation(.easeOut(duration: 0.2), value: composerFocused)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: store.busy)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.draftAttachments)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.currentPendingAttachments)
            .padding(.horizontal, 32).padding(.bottom, 10).frame(maxWidth: 820)
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: AttachmentInput.types, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { store.attach(urls: urls) }
                composerFocused = true
            }
            .onAppear {
                pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [store] event in
                    guard store.page == .chat, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers == "v", NSApp.keyWindow?.firstResponder is NSTextView,
                          AttachmentInput.paste(into: store) else { return event }
                    return nil
                }
            }
            .onDisappear { if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }; pasteMonitor = nil }
    }
    private var field: some View {
        @Bindable var store = store
        return HStack(alignment: .bottom, spacing: 10) {
            Button { choosingFiles = true } label: {
                Image(systemName: "paperclip").font(.system(size: 14, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Theme.muted).padding(.bottom, 1)
                .help("Attach images or PDFs. You can also drop or paste them.").accessibilityLabel("Attach images or PDFs")
            TextField(store.draftAttachments.isEmpty ? "Ask anything…" : "Ask about \(store.draftAttachments.count == 1 ? "it" : "them")…", text: $store.draft, axis: .vertical)
                .font(.system(size: 14)).textFieldStyle(.plain).lineLimit(1...8).focused($composerFocused)
                .onSubmit { if !store.busy && !reading { store.send() } }
                .accessibilityIdentifier("chat-input")
                .onChange(of: store.composerFocusRequest) { _, _ in composerFocused = true }
                .onChange(of: store.conversationID) { _, _ in composerFocused = true }
                .padding(.vertical, 4)
            Group {
                if store.generationIsElsewhere {
                    Button { store.showRunningConversation() } label: { icon("bubble.left.and.bubble.right") }
                        .buttonStyle(SoftButton()).help("View the conversation receiving a reply")
                } else if store.busy {
                    Button { store.stopOperation() } label: { icon("stop.fill") }.buttonStyle(PrimaryButton()).help("Stop (⌘.)")
                        .accessibilityLabel("Stop")
                } else {
                    Button { store.send() } label: { icon("arrow.up") }.buttonStyle(PrimaryButton())
                        .disabled(empty || reading).help(reading ? "Finishing reading your attachments…" : "Send")
                        .accessibilityLabel("Send message")
                }
            }.transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }
    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .bold)).frame(width: 16, height: 16)
    }
}

private struct ChatScrollAnchor: View {
    let reply: StreamingReply?
    let followsLatest: Bool
    let scrollToLatest: () -> Void
    var body: some View {
        // Scroll after the new text has been laid out, not before; scrolling mid-layout is what jitters.
        Color.clear.frame(height: 1).onChange(of: reply?.message.content) { _, _ in
            guard followsLatest else { return }
            DispatchQueue.main.async { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { scrollToLatest() } }
        }
    }
}

struct MessageView: View, Equatable {
    let savedMessage: ChatMessage
    let modelName: String
    let liveReply: StreamingReply?
    /// Constant for the app's lifetime, so it doesn't take part in equality.
    var library: AttachmentLibrary? = nil
    private var message: ChatMessage { liveReply?.message ?? savedMessage }
    private var generating: Bool { liveReply != nil }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.savedMessage == rhs.savedMessage && lhs.modelName == rhs.modelName && lhs.liveReply === rhs.liveReply
    }
    @State private var copied = false
    @State private var hovering = false
    private var user: Bool { message.role == "user" }
    var body: some View {
        if user { userBubble } else { assistantReply }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 90)
            VStack(alignment: .trailing, spacing: 6) {
                if let attachments = message.attachments, !attachments.isEmpty {
                    SentAttachments(attachments: attachments, library: library)
                }
                if !message.content.isEmpty {
                    Text(verbatim: message.content).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    copyButton.opacity(hovering ? 1 : 0)
                }
            }
        }.onHover { hovering = $0 }
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(1.6)); copied = false } }
    }

    private var assistantReply: some View {
        HStack(alignment: .top, spacing: 12) {
            EmberGlyph(size: 20, heat: generating ? 1 : 0.5, pulsing: generating && message.content.isEmpty).padding(.top, 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(modelName).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.muted)
                    Spacer()
                    if !message.content.isEmpty && !generating { copyButton.opacity(hovering ? 1 : 0.35) }
                }
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup {
                        MarkdownMessageView(content: reasoning).equatable().foregroundStyle(Theme.muted).padding(.top, 8)
                    } label: {
                        if generating && message.content.isEmpty { Text("Thinking…").shimmering() }
                        else { Text("How it thought it through").foregroundStyle(Theme.muted) }
                    }.font(.system(size: 12)).tint(Theme.muted)
                }
                if message.content.isEmpty && generating {
                    if message.reasoning?.isEmpty != false { Text(liveReply?.phase ?? "Starting…").font(.system(size: 13)).shimmering() }
                } else if message.content.isEmpty {
                    if message.failure == nil { Text("Stopped before it started.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                } else {
                    MarkdownMessageView(content: message.content).equatable()
                }
                if !generating {
                    if let failure = message.failure {
                        Label(failure, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Theme.caution).textSelection(.enabled)
                    } else if message.interrupted && !message.content.isEmpty {
                        Text("Stopped · the partial answer is kept").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    if message.reachedLimit == true {
                        Text("This answer reached its length limit. Continue below to keep going.").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    }
                }
                if let previous = message.previousReplies, !previous.isEmpty {
                    DisclosureGroup("Earlier answers (\(previous.count))") {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(previous) { answer in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(answer.date, style: .time).font(.mono(10)).foregroundStyle(Theme.muted)
                                    if !answer.content.isEmpty { MarkdownMessageView(content: answer.content).equatable() }
                                    else { Text("No answer was completed.").font(.system(size: 11)) }
                                    if let reasoning = answer.reasoning, !reasoning.isEmpty {
                                        DisclosureGroup("How it thought it through") { MarkdownMessageView(content: reasoning).equatable() }
                                    }
                                }
                                Divider()
                            }
                        }.padding(.top, 10)
                    }.font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).onHover { hovering = $0 }
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(1.6)); copied = false } }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.content, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copied ? Theme.ember : Theme.muted)
        }.buttonStyle(.plain).help("Copy").accessibilityLabel(copied ? "Copied" : "Copy message")
    }
}
