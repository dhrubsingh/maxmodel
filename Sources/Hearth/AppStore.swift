import SwiftUI
import AppKit
import HearthCore
import Observation

enum AppPage: String, CaseIterable { case chat = "Chat", models = "Assistants", device = "Your Mac" }
enum ModelFilter: String, CaseIterable { case recommended = "Your assistant", all = "Explore models", installed = "Manage storage" }
enum LicenseFilter: String, CaseIterable { case all = "All licenses", permissive = "Apache / MIT", custom = "Custom terms" }
enum CatalogSort: String, CaseIterable { case suggested = "Suggested", size = "Smallest download", name = "Name" }
enum RecoveryAction { case download(String, startChat: Bool), load(String) }

@MainActor @Observable
final class AppStore {
    var page: AppPage = .models
    var filter: ModelFilter = .recommended
    var fitsOnly = true
    var search = "" { didSet { scheduleSearch() } }
    private(set) var searchQuery = ""
    private var searchTask: Task<Void, Never>?
    var variantSelections: [String: String] = [:]
    var comparisonMode: ComparisonMode = .overview
    let answerComparison = AnswerComparison()
    let examples: DiscoveryExamples?
    var familyFilter = ""
    var categoryFilter = ""
    var licenseFilter: LicenseFilter = .all
    var catalogSort: CatalogSort = .suggested
    var comparison = Set<String>()
    var showComparison = false
    var data = AppData()
    var hardware: Hardware
    var conditions = MachineConditions()
    let recommendationEvidence: RecommendationEvidence?
    var showRecommendation = false
    var recommendationDetailID: String?
    var calibrationID: String?
    var installed = Set<String>()
    var partials: [String: Int64] = [:]
    var activeID: String?
    var conversationID: UUID?
    var draft = "" {
        didSet {
            drafts[draftKey] = draft.isEmpty ? nil : draft
            lastInteraction = Date()
            scheduleSave()
        }
    }
    @ObservationIgnored private var drafts: [String: String] = [:]
    private var draftKey: String { conversationID?.uuidString ?? "new" }
    /// Attachments in the unsent message, saved per conversation like the draft text.
    var draftAttachments: [ChatAttachment] = [] {
        didSet {
            attachmentDrafts[draftKey] = draftAttachments.isEmpty ? nil : draftAttachments
            lastInteraction = Date()
            scheduleSave()
        }
    }
    @ObservationIgnored private var attachmentDrafts: [String: [ChatAttachment]] = [:]
    /// Attachments still being read, shown as chips with progress.
    var pendingAttachments: [PendingAttachment] = []
    @ObservationIgnored private var attachmentJobs: [UUID: Task<ChatAttachment, Error>] = [:]
    var attachmentNotice: String?
    var visionInstalled = Set<String>()
    var visionDownloads: [String: Double] = [:]
    @ObservationIgnored private var visionTasks: [String: Task<Void, Never>] = [:]
    static let attachmentLimit = 10
    var composerFocusRequest = 0
    var status = "Choose your first assistant"
    var error: String? { didSet { recovery = nil } }
    var recovery: RecoveryAction?
    var busy = false
    var generating = false
    var downloadID: String?
    var downloadProgress: DownloadProgress?
    var verifying = false
    private var contextNotices: [String: String] = [:]
    var contextNotice: String? {
        get { contextNotices[draftKey] }
        set { contextNotices[draftKey] = newValue }
    }
    var requestedDownload: LocalModel?
    var downloadStartsChat = false
    var requestedDetails: LocalModel?
    var showsFullCatalog = false
    var showsTechnicalDetails = false
    private var setupModelID: String?
    var requestedDelete: LocalModel?
    var requestedChatDelete: UUID?
    var requestedHeavyModel: LocalModel?
    /// Set when a download finishes so the interface can mark the moment once.
    var celebration: Celebration?
    var benchmarkID: String?
    let catalog: [LocalModel]
    let families: [String]
    let catalogGroupCount: Int
    private let searchIndex: [String: String]
    @ObservationIgnored private var recommendationCache: (RecommendationQuery, RecommendationReport)?
    @ObservationIgnored private var catalogCache: (CatalogQuery, CatalogSnapshot)?
    let storage: LocalStorage?
    let engine: LocalEngine?
    var streamingReply: StreamingReply?
    private let stateWriter: StateWriter?
    private var refreshTask: Task<Void, Never>?
    private var refreshVersion = 0
    private var operation: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var currentDownload: ModelDownload?
    private var autosave: Task<Void, Never>?
    private var writableState = true
    @ObservationIgnored private var lastInteraction = Date()
    private var idleTask: Task<Void, Never>?
    private var memoryPressure: DispatchSourceMemoryPressure?

    init(storage suppliedStorage: LocalStorage? = nil) {
        var setupError: String?
        let root: LocalStorage?
        do { root = try suppliedStorage ?? LocalStorage() } catch { root = nil; setupError = error.localizedDescription }
        storage = root
        stateWriter = root.map(StateWriter.init)
        hardware = Hardware.inspect(at: root?.root ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        do { catalog = try LocalModel.catalog() } catch { catalog = []; setupError = error.localizedDescription }
        do { recommendationEvidence = try RecommendationEvidence.load(catalog: catalog) }
        catch { recommendationEvidence = nil; setupError = error.localizedDescription }
        families = Set(catalog.map(\.family)).sorted()
        catalogGroupCount = Set(catalog.map(\.groupID)).count
        searchIndex = Dictionary(uniqueKeysWithValues: catalog.map {
            ($0.id, [$0.name, $0.family, $0.license, $0.tagline, $0.strengths].joined(separator: " "))
        })
        examples = try? DiscoveryExamples.load(catalog: catalog)
        do { engine = try LocalEngine() } catch { engine = nil; setupError = error.localizedDescription }
        if let root {
            do { data = try root.readState() } catch {
                setupError = error.localizedDescription
                writableState = !FileManager.default.fileExists(atPath: root.stateURL.path)
            }
        }
        error = setupError
        installed = root?.installedIDs(catalog) ?? []
        visionInstalled = root?.visionInstalledIDs(catalog) ?? []
        refresh()
        for model in catalog where installed.contains(model.id) {
            Task {
                // Housekeeping only: the notices were saved at install, so a failed refresh is logged, not shown.
                do { try await Task.detached(priority: .utility) { try root?.preserveNotices(model) }.value }
                catch { NSLog("MaxModel: could not refresh license notices for %@: %@", model.id, error.localizedDescription) }
            }
        }
        if let setupError { error = setupError }
        if !installed.isEmpty { page = .chat; status = "Ready when you are" }
        if let key = data.currentConversationKey {
            conversationID = data.conversations.first { $0.id.uuidString == key }?.id
        } else { conversationID = data.conversations.first?.id }
        drafts = data.drafts ?? [:]
        draft = drafts[draftKey] ?? ""
        attachmentDrafts = data.draftAttachments ?? [:]
        draftAttachments = attachmentDrafts[draftKey] ?? []
        pruneAttachments()
        if data.selectedModelID == nil { data.selectedModelID = catalog.first(where: { installed.contains($0.id) })?.id }
        if let id = conversation?.modelID, installed.contains(id) { data.selectedModelID = id }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            Task { @MainActor in self?.releaseMemoryIfIdle(underPressure: true) }
        }
        pressure.resume(); memoryPressure = pressure
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.releaseMemoryIfIdle(underPressure: false)
            }
        }
    }
    var generationIsElsewhere: Bool {
        generating && streamingReply?.conversationID != conversationID
    }
    var chatStatus: String {
        if generationIsElsewhere { return "Another conversation is getting a reply" }
        if busy { return status }
        if selectedModel == nil { return "Choose your first assistant" }
        return activeID == selectedModel?.id ? "Ready offline" : "Available offline · loads when you send"
    }
    func showRunningConversation() {
        guard let id = streamingReply?.conversationID, let chat = data.conversations.first(where: { $0.id == id }) else { return }
        openChat(chat)
    }
    func releaseMemoryIfIdle(underPressure: Bool, now: Date = Date()) {
        guard !busy, activeID != nil, underPressure || now.timeIntervalSince(lastInteraction) >= 15 * 60 else { return }
        unload()
    }
    var discoveryPicks: [DiscoveryPick] {
        recommendationReport.choices.enumerated().map { index, choice in
            DiscoveryPick(model: choice.model,
                          title: index == 0 ? "Recommended · \(recommendationGoal.title)" : choice.model.family != recommended?.family ? "Another perspective" : "A lighter alternative",
                          reason: choice.summary, tradeoff: choice.performanceLabel)
        }
    }
    var homeAssistant: LocalModel? {
        if let selectedModel, installed.contains(selectedModel.id) { return selectedModel }
        if let downloaded = installedModels.first { return downloaded }
        if let pending = catalog.first(where: { $0.id == downloadID || $0.id == setupModelID }) { return pending }
        if let paused = catalog.first(where: { (partials[$0.id] ?? 0) > 0 }) { return paused }
        return discoveryPicks.first?.model
    }
    var libraryModels: [LocalModel] {
        catalog.filter { installed.contains($0.id) || (partials[$0.id] ?? 0) > 0 || downloadID == $0.id }
    }
    func openCatalog() {
        page = .models; filter = .all; fitsOnly = true; showsFullCatalog = false
        resetCatalogFilters()
    }
    func resetCatalogFilters() {
        search = ""; familyFilter = ""; categoryFilter = ""; licenseFilter = .all; catalogSort = .suggested
    }
    func requestDownload(_ model: LocalModel, startChat: Bool = false) {
        if startChat { setupModelID = model.id }
        if startChat && hasAcceptedLicense(model) {
            beginDownload(model, openChatWhenReady: true)
        } else {
            downloadStartsChat = startChat; requestedDownload = model
        }
    }
    func openAssistant(_ model: LocalModel) {
        if selectedModel?.id == model.id { page = .chat }
        else { selectModel(model) }
    }
    func comparePicks(mode: ComparisonMode) {
        comparison = Set(discoveryPicks.map(\.id)); comparisonMode = mode; showComparison = true
    }
    private func scheduleSearch() {
        searchTask?.cancel()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { searchQuery = ""; return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.searchQuery = query
        }
    }
    var recommended: LocalModel? {
        recommendationReport.recommended?.model
    }
    var recommendationGoal: RecommendationGoal { data.recommendationGoal ?? .capability }
    var conversationMemory: ConversationMemory { data.conversationMemory ?? .everyday }
    var compactCache: Bool { data.compactCache ?? true }
    func setRecommendationGoal(_ goal: RecommendationGoal) {
        guard !busy, goal != recommendationGoal else { return }
        data.recommendationGoal = goal; data.runtimeProfiles = nil; save()
        // This changes suggestions. A loaded chat keeps its configuration until the user switches/reloads.
    }
    func setConversationMemory(_ value: ConversationMemory) {
        guard !busy, value != conversationMemory else { return }
        data.conversationMemory = value; data.runtimeProfiles = nil; save()
    }
    func setCompactCache(_ value: Bool) {
        guard !busy, value != compactCache else { return }
        data.compactCache = value; data.runtimeProfiles = nil; save()
    }
    private var recommendationInputs: RecommendationQuery {
        RecommendationQuery(hardware: hardware, goal: recommendationGoal,
                                        conversationMemory: conversationMemory, compactCache: compactCache,
                                        installed: installed, partials: partials, benchmarks: data.benchmarks,
                                        failures: data.runtimeFailures ?? [:], profiles: data.runtimeProfiles ?? [:], hour: Int(Date().timeIntervalSince1970 / 3600))
    }
    /// Answers "what is the most capable assistant this Mac's hardware can run?". Memory that
    /// other apps happen to hold right now is reported separately (see `isShortOnFreeMemory`)
    /// and never silently downgrades the recommendation.
    var recommendationReport: RecommendationReport {
        let query = recommendationInputs
        if let cache = recommendationCache, cache.0 == query { return cache.1 }
        let result = RecommendationPlanner.evaluate(catalog: catalog, evidence: recommendationEvidence, hardware: hardware,
            goal: recommendationGoal, conversationMemory: conversationMemory, compactCache: compactCache,
            installed: installed, partials: partials,
            benchmarks: data.benchmarks, failures: data.runtimeFailures ?? [:], profiles: data.runtimeProfiles ?? [:])
        recommendationCache = (query, result)
        return result
    }
    func assessment(_ model: LocalModel) -> ModelAssessment? { recommendationReport.assessment(model.id) }
    /// True when the model fits this Mac but other apps currently hold the memory it needs.
    func isShortOnFreeMemory(_ model: LocalModel) -> Bool {
        modelFit(model) != .tight && profile(for: model).memory(for: model) > conditions.budget(for: hardware)
    }
    func profile(for model: LocalModel) -> RuntimeProfile { assessment(model)?.profile ?? .legacy(model) }
    func modelFit(_ model: LocalModel) -> Hardware.Fit {
        let memory = profile(for: model).memory(for: model)
        if memory > hardware.modelBudget { return .tight }
        return memory > hardware.modelBudget * 0.75 ? .heavy : .comfortable
    }
    func runningProfile(for model: LocalModel) -> RuntimeProfile {
        if engine?.activeModelID == model.id, let active = engine?.activeProfile { return active }
        return profile(for: model)
    }
    var selectedModel: LocalModel? { catalog.first { $0.id == data.selectedModelID } }
    var conversation: Conversation? { data.conversations.first { $0.id == conversationID } }
    var installedModels: [LocalModel] { catalog.filter { installed.contains($0.id) } }
    var filteredGroups: [ModelGroup] { catalogSnapshot.groups }
    var filteredModels: [LocalModel] { catalogSnapshot.models }

    // Read every query input before checking this one-entry cache, so Observation still
    // invalidates the view correctly even when a previous result is reused.
    private var catalogSnapshot: CatalogSnapshot {
        let query = CatalogQuery(search: searchQuery, family: familyFilter, category: categoryFilter,
                                 license: licenseFilter, filter: filter, sort: catalogSort, fitsOnly: fitsOnly,
                                 hardware: hardware, installed: installed, partials: partials, recommendations: recommendationInputs)
        if let cache = catalogCache, cache.0 == query { return cache.1 }
        let models = buildFilteredModels()
        var groups = ModelGroup.aggregate(models)
        switch catalogSort {
        case .suggested: break
        case .size: groups.sort { ($0.models.first?.bytes ?? 0) < ($1.models.first?.bytes ?? 0) }
        case .name: groups.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
        let snapshot = CatalogSnapshot(models: models, groups: groups)
        catalogCache = (query, snapshot)
        return snapshot
    }
    func preferredModel(in models: [LocalModel]) -> LocalModel {
        if let recommended, let match = models.first(where: { $0.id == recommended.id }) { return match }
        if let selected = models.first(where: { $0.id == data.selectedModelID }) { return selected }
        if let installed = models.first(where: { self.installed.contains($0.id) }) { return installed }
        return models.filter { assessment($0)?.eligible == true }.max { (assessment($0)?.capability ?? 0) < (assessment($1)?.capability ?? 0) } ?? models[0]
    }
    func hasRoom(_ model: LocalModel) -> Bool { installed.contains(model.id) || hardware.hasStorage(for: model, partialBytes: partials[model.id] ?? 0) }
    func hasAcceptedLicense(_ model: LocalModel) -> Bool {
        !model.needsLicenseReview || (model.licenseSHA256 != nil && data.acceptedLicenses?[model.id] == model.licenseSHA256)
    }
    var totalDiskUsed: Double {
        catalog.reduce(0) { total, model in
            total + (installed.contains(model.id) ? Double(model.bytes) : Double(partials[model.id] ?? 0))
                + (visionInstalled.contains(model.id) ? Double(model.vision?.bytes ?? 0) : 0)
        }
    }
    private func buildFilteredModels() -> [LocalModel] {
        let recommendedID = recommended?.id
        let matches = catalog.filter { model in
            (searchQuery.isEmpty || (searchIndex[model.id] ?? "").localizedCaseInsensitiveContains(searchQuery)) &&
            (familyFilter.isEmpty || model.family == familyFilter) &&
            (categoryFilter.isEmpty || model.taskCategory == categoryFilter) &&
            (licenseFilter == .all || (licenseFilter == .custom) == model.needsLicenseReview) &&
            (filter != .installed || installed.contains(model.id)) &&
            (filter == .installed || (filter == .all && !fitsOnly) || (modelFit(model) != .tight && hasRoom(model)))
        }.sorted { a, b in
            if catalogSort == .name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            if catalogSort == .size { return (a.bytes, a.id) < (b.bytes, b.id) }
            return (a.id == recommendedID ? 0 : 1, assessment(a)?.eligible == true ? 0 : 1, -(assessment(a)?.capability ?? -1), a.bytes, a.id)
                < (b.id == recommendedID ? 0 : 1, assessment(b)?.eligible == true ? 0 : 1, -(assessment(b)?.capability ?? -1), b.bytes, b.id)
        }
        return matches
    }
    func refresh() {
        guard let storage else { return }
        activeID = engine?.isRunning == true ? engine?.activeModelID : nil
        refreshVersion += 1
        let version = refreshVersion, catalog = catalog, footprint = engine?.memoryFootprint() ?? 0
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                (Hardware.inspect(at: storage.root), storage.installedIDs(catalog),
                 Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, storage.fileSize(storage.partialURL($0))) }),
                 MachineConditions.inspect(currentModelMemory: footprint), storage.visionInstalledIDs(catalog))
            }.value
            guard let self, !Task.isCancelled, self.refreshVersion == version else { return }
            self.hardware = snapshot.0; self.installed = snapshot.1; self.partials = snapshot.2; self.conditions = snapshot.3
            self.visionInstalled = snapshot.4
        }
    }
    var stateSnapshot: AppData {
        var snapshot = data
        snapshot.drafts = drafts
        snapshot.draftAttachments = attachmentDrafts.isEmpty ? nil : attachmentDrafts
        snapshot.currentConversationKey = draftKey
        if let live = streamingReply,
           let i = snapshot.conversations.firstIndex(where: { $0.id == live.conversationID }),
           let j = snapshot.conversations[i].messages.firstIndex(where: { $0.id == live.message.id }) {
            snapshot.conversations[i].messages[j] = live.message
        }
        return snapshot
    }
    func save() {
        guard writableState else { return }
        stateWriter?.save(stateSnapshot) { [weak self] failure in
            guard let failure else { return }
            Task { @MainActor in self?.error = "Could not save your conversation: \(failure)" }
        }
    }
    func scheduleSave() {
        guard autosave == nil else { return }
        autosave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.save(); self?.autosave = nil
        }
    }
    func setOffline(_ offline: Bool) {
        if offline && downloadID != nil { pauseDownload() }
        if offline { visionTasks.values.forEach { $0.cancel() } }
        data.offlineOnly = offline; save()
    }
    func beginDownload(_ model: LocalModel, acceptedLicense: Bool = false, openChatWhenReady: Bool = false) {
        guard downloadID == nil, let storage else { return }
        if model.needsLicenseReview && !hasAcceptedLicense(model) {
            guard acceptedLicense, let digest = model.licenseSHA256 else { error = "Review and accept this model's license before downloading."; return }
            if data.acceptedLicenses == nil { data.acceptedLicenses = [:] }
            data.acceptedLicenses?[model.id] = digest; save()
        }
        guard !data.offlineOnly else { error = "Turn off Download lock in Your Mac to allow a model download."; return }
        downloadID = model.id; verifying = false; downloadProgress = nil
        let client = ModelDownload(model: model, destination: storage.partialURL(model)) { [weak self] progress in
            Task { @MainActor in self?.downloadProgress = progress }
        }
        currentDownload = client
        downloadTask = Task { [weak self] in
            guard let self else { return }
            var completed = false
            do {
                let available = await Task.detached(priority: .utility) { Hardware.inspect(at: storage.root) }.value
                try Task.checkCancellation()
                guard available.hasStorage(for: model, partialBytes: storage.fileSize(storage.partialURL(model))) else {
                    throw HearthError.message("There isn't enough free disk space for this model. Remove another model or free some storage first.")
                }
                try await client.run()
                try Task.checkCancellation()
                self.verifying = true
                try await storage.finishInstall(model)
                self.installed.insert(model.id)
                if self.data.selectedModelID == nil { self.data.selectedModelID = model.id; self.save() }
                self.status = "\(model.name) is ready to use"
                completed = true
            } catch {
                if !Task.isCancelled && (error as NSError).code != NSURLErrorCancelled {
                    self.error = error.localizedDescription
                    self.recovery = .download(model.id, startChat: openChatWhenReady)
                }
            }
            self.downloadID = nil; self.currentDownload = nil; self.downloadTask = nil
            self.downloadProgress = nil; self.verifying = false; self.refresh()
            if completed { self.downloadDidFinish(model, openChatWhenReady: openChatWhenReady) }
        }
    }
    func downloadDidFinish(_ model: LocalModel, openChatWhenReady: Bool) {
        celebration = Celebration(model: model)
        // An explicitly requested setup can open chat, but never interrupt work already running.
        if openChatWhenReady && !busy { selectModel(model) }
        // Image support follows the model, so chat can start while it arrives.
        if model.canSeeImages { downloadVision(model, automatic: true) }
    }
    func pauseDownload() { currentDownload?.cancel(); downloadTask?.cancel() }
    func deleteModel(_ model: LocalModel) {
        guard let storage, !busy, downloadID != model.id else { return }
        visionTasks[model.id]?.cancel()
        busy = true; status = "Removing model files…"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                if self.activeID == model.id { await self.engine?.unload(); self.activeID = nil }
                try await Task.detached(priority: .utility) { try storage.remove(model) }.value
                self.data.benchmarks.removeValue(forKey: model.id)
                self.data.runtimeProfiles?.removeValue(forKey: model.id)
                self.data.optimizations?.removeValue(forKey: model.id)
                self.data.runtimeFailures = self.data.runtimeFailures?.filter { !$0.key.hasPrefix(model.id + ":") }
                self.installed.remove(model.id); self.partials.removeValue(forKey: model.id); self.visionInstalled.remove(model.id)
                if self.data.selectedModelID == model.id { self.data.selectedModelID = self.installedModels.first?.id }
                self.save(); self.status = "Removed \(model.name). Conversations are kept."
            } catch { self.error = error.localizedDescription }
            self.busy = false; self.operation = nil; self.refresh()
        }
    }
    func toggleComparison(_ model: LocalModel) {
        if comparison.contains(model.id) { comparison.remove(model.id) }
        else if comparison.count < 3 { comparison.insert(model.id) }
    }
    private func loadPlannedModel(_ model: LocalModel, storage: LocalStorage, engine: LocalEngine, preserveActive: Bool = false, requireFit: Bool = false) async throws {
        let noticeKey = draftKey
        if preserveActive && engine.activeModelID == model.id && engine.isRunning { return }
        let footprint = engine.memoryFootprint() ?? 0
        conditions = await Task.detached(priority: .utility) { MachineConditions.inspect(currentModelMemory: footprint) }.value
        try Task.checkCancellation()
        let planned = profile(for: model)
        if requireFit, planned.memory(for: model) > conditions.budget(for: hardware) {
            throw HearthError.message("There is not enough available memory to optimize this assistant. Close other apps or choose a smaller model.")
        }
        let vision = imageSupport(for: model) == .ready
        do {
            do { try await engine.load(model, storage: storage, profile: planned, vision: vision) { self.status = $0 } }
            catch where vision && !Task.isCancelled {
                try await engine.load(model, storage: storage, profile: planned) { self.status = $0 }
                contextNotices[noticeKey] = "Image support couldn't start this time, so images will be read as text. Chat works as usual."
            }
        } catch {
            try Task.checkCancellation()
            let message = error.localizedDescription
            let loadingFailure = message.contains("exited while loading") || message.contains("too long to load")
            // Compression fallback is a normal FP16 plan. Integrity failures never retry.
            guard (planned.contextTokens > 4096 || planned.cacheType != .f16 || planned.execution != ExecutionSettings()), loadingFailure else {
                if loadingFailure {
                    if data.runtimeFailures == nil { data.runtimeFailures = [:] }
                    data.runtimeFailures?[model.id + ":" + planned.id] = "This configuration failed to load. Run a local check to retry."
                    save()
                }
                throw error
            }
            let fallback = planned.execution != ExecutionSettings()
                ? AdaptiveOptimizer.replacing(planned, threads: max(1, hardware.cores - 2), execution: .init())
                : RuntimeFallback.profile(after: planned, model: model,
                evidence: recommendationEvidence?.models.first { $0.modelID == model.id }, hardware: hardware,
                budget: conditions.budget(for: hardware), goal: recommendationGoal, conversationMemory: conversationMemory)
            status = "Making more room for this assistant…"
            do { try await engine.load(model, storage: storage, profile: fallback) { self.status = $0 } }
            catch {
                try Task.checkCancellation()
                if data.runtimeFailures == nil { data.runtimeFailures = [:] }
                data.runtimeFailures?[model.id + ":" + planned.id] = "This model failed to load even with a shorter conversation window. Try another assistant or recheck."
                save(); throw error
            }
            contextNotices[noticeKey] = "\(Theme.appName) returned to compatible settings with a \(fallback.contextTokens.formatted())-token window to help this model run. Your saved chats are kept."
        }
        if data.runtimeProfiles == nil { data.runtimeProfiles = [:] }
        data.runtimeProfiles?[model.id] = engine.activeProfile
        data.runtimeFailures?.removeValue(forKey: model.id + ":" + planned.id)
        save()
    }
    func selectModel(_ model: LocalModel, allowHeavy: Bool = false) {
        guard !busy else { return }
        guard hasAcceptedLicense(model) else { requestedDownload = model; return }
        guard installed.contains(model.id) else { requestedDownload = model; return }
        if modelFit(model) == .tight && !allowHeavy { requestedHeavyModel = model; return }
        data.selectedModelID = model.id
        if let index = data.conversations.firstIndex(where: { $0.id == conversationID }) { data.conversations[index].modelID = model.id }
        save(); page = .chat; contextNotice = nil
        error = nil; lastInteraction = Date()
        guard let storage, let engine else { error = "The bundled engine is unavailable."; return }
        busy = true
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.loadPlannedModel(model, storage: storage, engine: engine)
                self.activeID = model.id
                self.lastInteraction = Date()
                self.status = "Ready offline"
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                    self.recovery = .load(model.id)
                }
                self.status = engine.isRunning ? "Ready · local check incomplete" : "Model is not running"
            }
            self.calibrationID = nil; self.busy = false; self.operation = nil; self.refresh()
        }
    }
    func unload() {
        guard !busy else { return }
        busy = true; status = "Releasing model memory…"
        operation = Task { [weak self] in
            guard let self else { return }
            await self.engine?.unload()
            self.activeID = nil; self.status = "Memory released · models stay downloaded"
            self.busy = false; self.operation = nil; self.refresh()
        }
    }
    func newChat() {
        conversationID = nil; draft = drafts["new"] ?? ""; draftAttachments = attachmentDrafts["new"] ?? []; page = .chat
        attachmentNotice = nil; composerFocusRequest += 1; save()
    }
    func openChat(_ chat: Conversation) {
        guard data.conversations.contains(where: { $0.id == chat.id }) else { return }
        conversationID = chat.id; page = .chat; draft = drafts[draftKey] ?? ""; draftAttachments = attachmentDrafts[draftKey] ?? []
        attachmentNotice = nil
        if let id = chat.modelID, installed.contains(id) { data.selectedModelID = id }
        save()
    }
    func deleteChat(_ id: UUID) {
        guard !busy else { return }
        data.conversations.removeAll { $0.id == id }
        drafts.removeValue(forKey: id.uuidString); contextNotices.removeValue(forKey: id.uuidString)
        attachmentDrafts.removeValue(forKey: id.uuidString)
        if conversationID == id { newChat() }
        save(); pruneAttachments()
    }
    func useStarter(_ prompt: String) {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            composerFocusRequest += 1; return
        }
        draft = prompt; composerFocusRequest += 1
    }
    func recover() {
        guard !busy, let action = recovery else { return }
        error = nil
        switch action {
        case let .download(id, startChat):
            if let model = catalog.first(where: { $0.id == id }) { requestDownload(model, startChat: startChat) }
        case let .load(id):
            if let model = catalog.first(where: { $0.id == id }) { selectModel(model) }
        }
    }
    func editLastQuestion() {
        guard !busy, let original = conversation,
              let index = original.messages.lastIndex(where: { $0.role == "user" }) else { return }
        var revised = Conversation(modelID: original.modelID)
        revised.title = String(original.messages[index].content.prefix(44)) + " · revised"
        revised.messages = Array(original.messages[..<index])
        data.conversations.insert(revised, at: 0)
        openChat(revised); draft = original.messages[index].content
        draftAttachments = original.messages[index].attachments ?? []
        contextNotice = "Edit your question below. Your original conversation is kept."
        composerFocusRequest += 1; save()
    }
    func retryLastReply() {
        guard !busy, writableState, let chatID = conversationID,
              let index = data.conversations.firstIndex(where: { $0.id == chatID }),
              let previous = data.conversations[index].messages.last, previous.role == "assistant",
              let model = selectedModel, installed.contains(model.id), let storage, let engine else { return }
        guard hasAcceptedLicense(model) else { requestedDownload = model; return }
        let history = Array(data.conversations[index].messages.dropLast())
        guard history.last?.role == "user" else { return }
        var reply = ChatMessage(role: "assistant", content: "", modelID: model.id, interrupted: true)
        var archived = previous; archived.previousReplies = nil
        reply.previousReplies = (previous.previousReplies ?? []) + [archived]
        data.conversations[index].messages.removeLast()
        startReply(model, chatID: chatID, history: history, reply: reply, storage: storage, engine: engine)
    }
    func continueReply() {
        guard conversation?.messages.last?.role == "assistant" else { return }
        send("Continue your previous answer from where it stopped, without repeating what you already wrote.")
    }
    func send(_ suggestion: String? = nil) {
        guard writableState else { error = "Conversation storage is unavailable. Resolve the storage error and reopen \(Theme.appName) before starting a chat."; return }
        let text = (suggestion ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = suggestion == nil ? draftAttachments : []
        guard !busy, !text.isEmpty || !attachments.isEmpty, suggestion != nil || currentPendingAttachments.isEmpty else { return }
        guard let model = selectedModel, installed.contains(model.id), let storage, let engine else { page = .models; return }
        guard hasAcceptedLicense(model) else { requestedDownload = model; return }
        // Explicit actions such as Continue never consume the user's unsent draft.
        let pendingDraft = suggestion == nil ? "" : draft
        let pendingAttachments = suggestion == nil ? [] : draftAttachments
        if suggestion == nil { draft = ""; draftAttachments = [] }
        attachmentNotice = nil
        if conversationID == nil {
            var chat = Conversation(modelID: model.id)
            chat.title = String((text.isEmpty ? attachments.map(\.name).joined(separator: ", ") : text).prefix(54))
            data.conversations.insert(chat, at: 0); conversationID = chat.id
            if suggestion != nil { drafts.removeValue(forKey: "new"); attachmentDrafts.removeValue(forKey: "new") }
            draft = pendingDraft; draftAttachments = pendingAttachments
        }
        guard let chatID = conversationID, let index = data.conversations.firstIndex(where: { $0.id == chatID }) else { return }
        data.conversations[index].messages.append(ChatMessage(role: "user", content: text, attachments: attachments))
        let history = data.conversations[index].messages
        let reply = ChatMessage(role: "assistant", content: "", modelID: model.id, interrupted: true)
        startReply(model, chatID: chatID, history: history, reply: reply, storage: storage, engine: engine)
    }
    private func startReply(_ model: LocalModel, chatID: UUID, history: [ChatMessage], reply: ChatMessage,
                            storage: LocalStorage, engine: LocalEngine) {
        guard let index = data.conversations.firstIndex(where: { $0.id == chatID }) else { return }
        data.conversations[index].messages.append(reply)
        streamingReply = StreamingReply(conversationID: chatID, message: reply)
        data.conversations[index].updatedAt = Date(); data.conversations[index].modelID = model.id
        contextNotice = nil; error = nil; lastInteraction = Date()
        save(); busy = true; generating = true; status = "Loading assistant…"
        operation = Task { [weak self] in
            guard let self else { return }
            var bufferedText = ""
            var reasoningText = ""
            var lastDisplay = Date.distantPast
            let started = Date()
            var firstAnswerSeconds: Double?
            do {
                // A conversation with images reloads once to add image support, if it's ready.
                let wantsVision = history.contains(where: \.hasImages) && self.imageSupport(for: model) == .ready && !engine.visionEnabled
                try await self.loadPlannedModel(model, storage: storage, engine: engine, preserveActive: !wantsVision)
                self.activeID = model.id
                let latest = history.last { $0.role == "user" }
                let phase = latest?.hasImages == true ? (engine.visionEnabled ? "Looking at your image…" : "Reading the text in your image…")
                    : latest?.attachments?.isEmpty == false ? "Reading your document…" : nil
                self.status = phase ?? "Writing a response…"
                self.streamingReply?.phase = phase
                let result = try await engine.complete(messages: history, attachments: storage.attachments, onTrim: { count in
                    if count > 0 { self.contextNotices[chatID.uuidString] = "\(count) earlier messages are saved but omitted from this reply to fit the conversation window. Start a new chat for a fresh topic." }
                }, onReasoning: { token in
                    reasoningText += token
                    if Date().timeIntervalSince(lastDisplay) >= 0.08 {
                        if self.status != "Thinking on this Mac…" { self.status = "Thinking on this Mac…" }
                        self.updateReply(chatID, replyID: reply.id) { $0.reasoning = reasoningText }
                        lastDisplay = Date(); self.scheduleSave()
                    }
                }, onToken: { token in
                    if firstAnswerSeconds == nil { firstAnswerSeconds = Date().timeIntervalSince(started) }
                    if self.status != "Writing a response…" { self.status = "Writing a response…" }
                    bufferedText += token
                    // Do not re-layout the entire conversation for every generated token.
                    if Date().timeIntervalSince(lastDisplay) >= 0.08 {
                        self.updateReply(chatID, replyID: reply.id) { $0.content += bufferedText }
                        bufferedText = ""; lastDisplay = Date(); self.scheduleSave()
                    }
                })
                self.updateReply(chatID, replyID: reply.id) {
                    $0.content = result.text; $0.reasoning = result.reasoning; $0.interrupted = false; $0.reachedLimit = result.reachedLimit
                }
                if self.data.replyObservations == nil { self.data.replyObservations = [:] }
                self.data.replyObservations?[model.id] = ReplyObservation(modelSHA256: model.sha256,
                    hardwareID: self.hardware.optimizationID, profileID: engine.activeProfile?.id ?? "",
                    firstAnswerSeconds: firstAnswerSeconds ?? result.firstTokenSeconds, tokensPerSecond: result.tokensPerSecond,
                    processMemoryBytes: engine.memoryFootprint())
                bufferedText = ""
                self.status = "Running on this Mac"
            } catch {
                if !reasoningText.isEmpty { self.updateReply(chatID, replyID: reply.id) { $0.reasoning = reasoningText } }
                if !bufferedText.isEmpty { self.updateReply(chatID, replyID: reply.id) { $0.content += bufferedText } }
                self.status = Task.isCancelled ? "Response stopped" : "Couldn't finish the response"
                if !Task.isCancelled && (error as NSError).code != NSURLErrorCancelled {
                    self.updateReply(chatID, replyID: reply.id) { $0.failure = error.localizedDescription }
                }
            }
            self.data = self.stateSnapshot; self.streamingReply = nil
            self.generating = false; self.busy = false; self.operation = nil
            self.lastInteraction = Date()
            self.save(); self.refresh()
        }
    }
    private func updateReply(_ chatID: UUID, replyID: UUID, action: (inout ChatMessage) -> Void) {
        if let live = streamingReply, live.conversationID == chatID, live.message.id == replyID {
            action(&live.message); return
        }
        guard let i = data.conversations.firstIndex(where: { $0.id == chatID }),
              let j = data.conversations[i].messages.firstIndex(where: { $0.id == replyID }) else { return }
        action(&data.conversations[i].messages[j])
    }
    func stopOperation() { if busy { status = "Stopping…" }; operation?.cancel() }
    private func measureAndTune(_ model: LocalModel, storage: LocalStorage, engine: LocalEngine) async throws -> Benchmark {
        var measurement = try await engine.benchmark(model: model, chip: hardware.chip) { step in
            self.status = "Checking local performance · \(step) of 3 · you can skip"
        }
        if let current = engine.activeProfile, current.machineID == nil, let tuned = PerformanceTuning.nextProfile(current, measurement: measurement, goal: recommendationGoal) {
            status = "Tuning thinking time for this Mac…"
            try await engine.load(model, storage: storage, profile: tuned) { self.status = $0 }
            if data.runtimeProfiles == nil { data.runtimeProfiles = [:] }
            data.runtimeProfiles?[model.id] = tuned; save()
            measurement = try await engine.benchmark(model: model, chip: hardware.chip) { step in
                self.status = "Validating the tuned assistant · \(step) of 3 · you can skip"
            }
        }
        return measurement
    }
    func optimization(for model: LocalModel) -> OptimizationRecord? {
        guard let record = data.optimizations?[model.id], record.applies(model: model, hardware: hardware, profile: profile(for: model)) else { return nil }
        return record
    }
    func resetOptimization(_ model: LocalModel) {
        guard !busy else { return }
        data.runtimeProfiles?.removeValue(forKey: model.id)
        data.optimizations?.removeValue(forKey: model.id)
        save()
        status = "Automatic settings restored · use the assistant again to apply"
    }
    func optimizeModel(_ model: LocalModel) {
        guard !busy, installed.contains(model.id), let storage, let engine else { return }
        guard hasAcceptedLicense(model) else { requestedDownload = model; return }
        let previousProfile = data.runtimeProfiles?[model.id]
        busy = true; calibrationID = model.id; benchmarkID = model.id
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.loadPlannedModel(model, storage: storage, engine: engine, requireFit: true)
                guard let baseline = engine.activeProfile else { throw HearthError.message("The assistant is not loaded.") }
                self.activeID = model.id
                let record = try await engine.optimize(model: model, storage: storage, hardware: self.hardware, baseline: baseline) { self.status = $0 }
                var result = try await engine.benchmark(model: model, chip: self.hardware.chip) { self.status = "Measuring the final settings · \($0) of 3" }
                result.checks = try await engine.checkAnswers { self.status = "Final answer checks · \($0) of 6" }
                try Task.checkCancellation()
                if self.data.optimizations == nil { self.data.optimizations = [:] }
                if self.data.runtimeProfiles == nil { self.data.runtimeProfiles = [:] }
                self.data.optimizations?[model.id] = record
                self.data.runtimeProfiles?[model.id] = record.selected
                self.data.benchmarks[model.id] = result
                self.data.runtimeFailures = self.data.runtimeFailures?.filter { !$0.key.hasPrefix(model.id + ":") }
                self.save(); self.status = "Optimization checked · results in Performance & why"
            } catch {
                await engine.unload()
                self.activeID = nil
                self.data.runtimeProfiles?[model.id] = previousProfile
                self.save()
                if !Task.isCancelled { self.error = error.localizedDescription }
                self.status = "Optimization stopped · previous settings kept"
            }
            self.busy = false; self.calibrationID = nil; self.benchmarkID = nil; self.operation = nil; self.refresh()
        }
    }
    func runBenchmark(_ model: LocalModel, includeContext: Bool = false) {
        guard !busy, installed.contains(model.id), let storage, let engine else { return }
        guard hasAcceptedLicense(model) else { requestedDownload = model; return }
        busy = true; benchmarkID = model.id; calibrationID = model.id
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                // An explicit recheck is also the recovery path for an earlier failure.
                self.data.runtimeFailures = self.data.runtimeFailures?.filter { !$0.key.hasPrefix(model.id + ":") }
                let started = Date()
                try await self.loadPlannedModel(model, storage: storage, engine: engine)
                self.activeID = model.id
                let loadSeconds = Date().timeIntervalSince(started)
                var result = try await self.measureAndTune(model, storage: storage, engine: engine)
                result.loadSeconds = loadSeconds
                result.checks = try await engine.checkAnswers { step in self.status = "Checking basic answers · \(step) of 6" }
                if includeContext {
                    self.status = "Preparing a long synthetic conversation…"
                    result.contextCheck = try await engine.checkContext { self.status = $0 }
                }
                self.data.benchmarks[model.id] = result; self.save(); self.status = "Local check complete · see How it works"
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; self.recordCalibrationFailure(model) }
                self.status = "Local check stopped"
            }
            self.busy = false; self.benchmarkID = nil; self.calibrationID = nil; self.operation = nil; self.refresh()
        }
    }
    private func recordCalibrationFailure(_ model: LocalModel) {
        let configuration = engine?.activeProfile ?? profile(for: model)
        if data.runtimeFailures == nil { data.runtimeFailures = [:] }
        data.runtimeFailures?[model.id + ":" + configuration.id] = "This configuration could not complete its local check. Recheck it or try another assistant."
        save()
    }
    func compareAnswers(models: [LocalModel]) {
        let session = answerComparison
        let prompt = session.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, models.count >= 2, !prompt.isEmpty, let engine, let storage else { return }
        guard models.allSatisfy({ installed.contains($0.id) && hasAcceptedLicense($0) && modelFit($0) != .tight }) else {
            error = "Download and review the licenses of two models that fit your Mac before comparing your question."; return
        }
        session.submittedPrompt = prompt
        session.answers = Dictionary(uniqueKeysWithValues: models.map { ($0.id, ComparedAnswer(modelID: $0.id)) })
        session.running = true; busy = true
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                for model in models {
                    try Task.checkCancellation()
                    guard let answer = session.answers[model.id] else { continue }
                    var buffer = "", lastDisplay = Date.distantPast
                    try await engine.load(model, storage: storage, profile: self.profile(for: model)) { answer.status = $0 }
                    self.activeID = model.id; answer.status = "Writing on this Mac…"
                    self.status = "Comparing \(model.name)…"
                    do {
                        let result = try await engine.complete(messages: [ChatMessage(role: "user", content: prompt)], maxTokens: self.profile(for: model).thinkingTokens + 512, reusePrompt: false,
                            onReasoning: { token in answer.reasoning += token }, onToken: { token in
                                buffer += token
                                if Date().timeIntervalSince(lastDisplay) >= 0.08 {
                                    answer.content += buffer; buffer = ""; lastDisplay = Date()
                                }
                            })
                        answer.content = result.text; answer.reasoning = result.reasoning ?? ""
                        answer.firstTokenSeconds = result.firstTokenSeconds; answer.tokensPerSecond = result.tokensPerSecond
                        answer.status = result.reachedLimit ? "Reached the comparison length limit" : "Complete"
                        answer.finished = true
                    } catch {
                        answer.content += buffer
                        answer.status = Task.isCancelled ? "Stopped · partial answer kept" : error.localizedDescription
                        throw error
                    }
                }
                self.status = "Comparison ready · choose the answer you prefer"
            } catch {
                for answer in session.answers.values where !answer.finished {
                    if answer.content.isEmpty { answer.status = Task.isCancelled ? "Comparison stopped" : error.localizedDescription }
                }
                self.status = Task.isCancelled ? "Comparison stopped" : "Comparison could not finish"
            }
            session.running = false; self.busy = false; self.operation = nil; self.refresh()
        }
    }
    func continueComparison(with model: LocalModel) {
        guard !busy, let answer = answerComparison.answers[model.id], answer.finished else { return }
        var chat = Conversation(modelID: model.id)
        chat.title = String(answerComparison.submittedPrompt.prefix(54))
        var reply = ChatMessage(role: "assistant", content: answer.content, modelID: model.id)
        reply.reasoning = answer.reasoning.isEmpty ? nil : answer.reasoning
        chat.messages = [ChatMessage(role: "user", content: answerComparison.submittedPrompt), reply]
        data.conversations.insert(chat, at: 0); conversationID = chat.id; draft = ""
        showComparison = false; selectModel(model); save()
    }
    func exportConversation() {
        guard let conversation = stateSnapshot.conversations.first(where: { $0.id == conversationID }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Theme.appName) conversation.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = conversation.title + "\n\n" + conversation.messages.map { message in
            let attached = message.attachments.map { "[Attached: " + $0.map(\.name).joined(separator: ", ") + "]\n" } ?? ""
            return (message.role == "user" ? "You" : Theme.appName) + ":\n" + attached + message.content
        }.joined(separator: "\n\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
    func revealStorage() { if let url = storage?.root { NSWorkspace.shared.open(url) } }
    func shutdown() {
        operation?.cancel(); currentDownload?.cancel(); downloadTask?.cancel(); autosave?.cancel()
        refreshTask?.cancel(); searchTask?.cancel()
        idleTask?.cancel(); memoryPressure?.cancel()
        if writableState { try? stateWriter?.flush(stateSnapshot) }
        engine?.stop()
    }
}

private struct CatalogQuery: Equatable {
    let search: String
    let family: String
    let category: String
    let license: LicenseFilter
    let filter: ModelFilter
    let sort: CatalogSort
    let fitsOnly: Bool
    let hardware: Hardware
    let installed: Set<String>
    let partials: [String: Int64]
    let recommendations: RecommendationQuery
}

private struct RecommendationQuery: Equatable {
    let hardware: Hardware
    let goal: RecommendationGoal
    let conversationMemory: ConversationMemory
    let compactCache: Bool
    let installed: Set<String>
    let partials: [String: Int64]
    let benchmarks: [String: Benchmark]
    let failures: [String: String]
    let profiles: [String: RuntimeProfile]
    let hour: Int
}

private struct CatalogSnapshot {
    let models: [LocalModel]
    let groups: [ModelGroup]
}

struct Celebration: Equatable {
    let model: LocalModel
    let date = Date()
}

struct PendingAttachment: Identifiable, Equatable {
    let id: UUID
    let key: String
    let name: String
    let kind: ChatAttachment.Kind
    var status: String
}

/// Whether the selected model can look at images right now, and what to offer if not.
enum ImageSupport: Equatable {
    case ready, unavailable, noRoom
    case needsDownload(bytes: Int64)
    case downloading(fraction: Double)
}

extension AppStore {
    var currentPendingAttachments: [PendingAttachment] { pendingAttachments.filter { $0.key == draftKey } }

    func imageSupport(for model: LocalModel) -> ImageSupport {
        guard let vision = model.vision else { return .unavailable }
        if let fraction = visionDownloads[model.id] { return .downloading(fraction: fraction) }
        guard visionInstalled.contains(model.id) else { return .needsDownload(bytes: vision.bytes) }
        return profile(for: model).memory(for: model) + vision.estimatedMemory <= hardware.modelBudget ? .ready : .noRoom
    }
    /// An installed model that can see images, preferring the recommendation, to offer instead.
    var imageCapableAlternative: LocalModel? {
        let capable = installedModels.filter { $0.canSeeImages && $0.id != selectedModel?.id && imageSupport(for: $0) != .noRoom }
        return capable.first { $0.id == recommended?.id } ?? capable.first
    }
    /// Leading pages of a PDF the selected model can read in one message.
    func pagesThatFit(_ attachment: ChatAttachment) -> Int? {
        guard attachment.kind == .pdf, let lengths = attachment.pageCharacters, let model = selectedModel else { return nil }
        let planned = profile(for: model)
        let budget = AttachmentBudget.characters(contextTokens: planned.contextTokens, thinkingTokens: planned.thinkingTokens,
                                                 images: imageSupport(for: model) == .ready ? 1 : 0)
        return max(1, AttachmentBudget.pagesThatFit(lengths: lengths, budget: budget))
    }

    func attach(urls: [URL]) {
        for url in urls {
            guard let kind = AttachmentProcessor.kind(of: url) else {
                attachmentNotice = "\(url.lastPathComponent) isn't an image or PDF, so it can't be attached."; continue
            }
            startAttachment(name: url.lastPathComponent, kind: kind) { id, library, progress in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try AttachmentProcessor.process(fileAt: url, id: id, into: library, progress: progress)
            }
        }
    }
    func attach(imageData: Data, name: String) {
        startAttachment(name: name, kind: .image) { id, library, _ in
            try AttachmentProcessor.process(imageData: imageData, name: name, id: id, into: library)
        }
    }
    func removeAttachment(_ id: UUID) {
        if let job = attachmentJobs.removeValue(forKey: id) { job.cancel() }
        pendingAttachments.removeAll { $0.id == id }
        draftAttachments.removeAll { $0.id == id }
        pruneAttachments()
    }

    /// Reading happens off the main actor; the chip updates as pages are read.
    private func startAttachment(name: String, kind: ChatAttachment.Kind,
                                 work: @escaping @Sendable (UUID, AttachmentLibrary, @escaping @Sendable (String) -> Void) throws -> ChatAttachment) {
        guard let library = storage?.attachments else { return }
        let key = draftKey
        guard (attachmentDrafts[key]?.count ?? 0) + pendingAttachments.filter({ $0.key == key }).count < Self.attachmentLimit else {
            attachmentNotice = "A message can include up to \(Self.attachmentLimit) images or PDFs."; return
        }
        let id = UUID()
        pendingAttachments.append(PendingAttachment(id: id, key: key, name: name, kind: kind, status: kind == .pdf ? "Reading…" : "Preparing…"))
        attachmentNotice = nil
        let report: @Sendable (String) -> Void = { [self] status in
            Task { @MainActor in
                if let index = self.pendingAttachments.firstIndex(where: { $0.id == id }) { self.pendingAttachments[index].status = status }
            }
        }
        let job = Task.detached(priority: .userInitiated) { try work(id, library, report) }
        attachmentJobs[id] = job
        Task { [weak self] in
            let result = await job.result
            guard let self, self.attachmentJobs.removeValue(forKey: id) != nil else { return }
            self.pendingAttachments.removeAll { $0.id == id }
            switch result {
            case .success(let attachment):
                if key == self.draftKey { self.draftAttachments.append(attachment) }
                else { self.attachmentDrafts[key, default: []].append(attachment); self.scheduleSave() }
            case .failure(let error):
                if !(error is CancellationError) { self.attachmentNotice = error.localizedDescription }
                self.pruneAttachments()
            }
        }
    }

    /// Deletes attachment files nothing refers to: removed chips, deleted chats, interrupted reads.
    func pruneAttachments() {
        guard let library = storage?.attachments else { return }
        var keep = Set(pendingAttachments.map(\.id))
        for chat in data.conversations { for message in chat.messages { message.attachments?.forEach { keep.insert($0.id) } } }
        attachmentDrafts.values.forEach { $0.forEach { keep.insert($0.id) } }
        let referenced = keep
        Task.detached(priority: .utility) { library.prune(keeping: referenced) }
    }

    /// Downloads and verifies a model's image encoder. Automatic downloads stay quiet about failures.
    func downloadVision(_ model: LocalModel, automatic: Bool = false) {
        guard let vision = model.vision, let storage, visionTasks[model.id] == nil,
              installed.contains(model.id), !visionInstalled.contains(model.id) else { return }
        guard !data.offlineOnly else {
            if !automatic { attachmentNotice = "Download lock is on. Turn it off in This Mac to add image support." }
            return
        }
        visionDownloads[model.id] = 0
        let client = ModelDownload(source: vision.url, bytes: vision.bytes, destination: storage.visionPartialURL(model)) { [weak self] progress in
            Task { @MainActor in if self?.visionDownloads[model.id] != nil { self?.visionDownloads[model.id] = progress.fraction } }
        }
        visionTasks[model.id] = Task { [weak self] in
            do {
                let available = await Task.detached(priority: .utility) { Hardware.inspect(at: storage.root) }.value
                guard available.hasStorage(bytes: vision.bytes, partialBytes: storage.fileSize(storage.visionPartialURL(model))) else {
                    throw HearthError.message("There isn't enough free disk space for image support (\(LocalModel.size(Double(vision.bytes)))).")
                }
                try await client.run()
                try Task.checkCancellation()
                try await storage.finishVisionInstall(model)
                self?.visionInstalled.insert(model.id)
            } catch {
                if !automatic, !Task.isCancelled, (error as NSError).code != NSURLErrorCancelled {
                    self?.attachmentNotice = "Image support couldn't be added: \(error.localizedDescription)"
                }
            }
            self?.visionDownloads[model.id] = nil; self?.visionTasks[model.id] = nil
        }
    }
}
