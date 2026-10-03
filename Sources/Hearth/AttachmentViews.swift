import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HearthCore

/// Small JPEGs decode off the main thread once, then come from memory.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()
    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let data = await Task.detached(priority: .userInitiated, operation: { try? Data(contentsOf: url) }).value,
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct AttachmentThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Theme.raised
            if let image { Image(nsImage: image).resizable().scaledToFill().transition(.opacity) }
        }
        .clipped()
        .task(id: url) {
            let loaded = await ThumbnailCache.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}

enum AttachmentInput {
    static let types: [UTType] = [.image, .pdf]
    /// Drops can be files (Finder) or raw image data (a browser or Photos).
    @MainActor static func load(_ providers: [NSItemProvider], into store: AppStore) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.attach(urls: [url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                let name = (provider.suggestedName ?? "Dropped image") + ".png"
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in store.attach(imageData: data, name: name) }
                }
            }
        }
        return accepted
    }
    /// ⌘V with files or an image on the clipboard attaches them; plain text pastes as usual.
    @MainActor static func paste(into store: AppStore) -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty,
           urls.allSatisfy({ AttachmentProcessor.kind(of: $0) != nil }) {
            store.attach(urls: urls); return true
        }
        guard board.string(forType: .string) == nil,
              let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { return false }
        store.attach(imageData: data, name: "Pasted image.png")
        return true
    }
}

/// Chips above the message field, and what the selected model will do with them.
struct ComposerAttachments: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        let attachments = store.draftAttachments, pending = store.currentPendingAttachments
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty || !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(attachments) { AttachmentChip(attachment: $0) }
                        ForEach(pending) { PendingChip(pending: $0) }
                    }.padding(.top, 6).padding(.trailing, 6)
                }.scrollClipDisabled()
            }
            if let notice = store.attachmentNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.caution)
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { store.attachmentNotice = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel("Dismiss")
                }.font(.system(size: 11.5)).foregroundStyle(Theme.ink)
            }
            if attachments.contains(where: { $0.kind == .image }) || pending.contains(where: { $0.kind == .image }),
               let model = store.selectedModel { ImageSupportNotice(model: model) }
        }
    }
}

private struct ImageSupportNotice: View {
    @Environment(AppStore.self) private var store
    let model: LocalModel
    var body: some View {
        switch store.imageSupport(for: model) {
        case .ready: EmptyView()
        case .unavailable:
            line("\(model.baseName) can't see images, so it will read the text in them.", icon: "text.viewfinder") {
                if let alternative = store.imageCapableAlternative {
                    Button("Use \(alternative.baseName)") { store.selectModel(alternative) }.disabled(store.busy)
                }
            }
        case .needsDownload(let bytes):
            line("\(model.baseName) can see images with a one-time \(LocalModel.size(Double(bytes))) add-on. Until then, it reads the text in them.", icon: "eye") {
                Button("Add image support") { store.downloadVision(model) }
            }
        case .downloading(let fraction):
            line("Adding image support… \(Int(fraction * 100))%. Until it's ready, \(model.baseName) reads the text in images.", icon: "arrow.down.circle") {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 60).tint(Theme.ember)
            }
        case .noRoom:
            line("This Mac doesn't have the memory to add image support to \(model.baseName), so it will read the text in images.", icon: "memorychip") { EmptyView() }
        }
    }
    private func line<Action: View>(_ text: String, icon: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.ember)
            Text(text).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            action().buttonStyle(QuietButton())
        }.font(.system(size: 11.5)).accessibilityElement(children: .combine)
    }
}

private struct AttachmentChip: View {
    @Environment(AppStore.self) private var store
    let attachment: ChatAttachment
    @State private var hovering = false
    var body: some View {
        Group {
            if attachment.kind == .image {
                AttachmentThumbnail(url: url(attachment.thumbnailFile))
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
            } else {
                DocumentLabel(name: attachment.name, detail: detail)
            }
        }
        .overlay(alignment: .topTrailing) { removeButton.opacity(hovering ? 1 : 0).offset(x: 6, y: -6) }
        .onHover { hovering = $0 }
        .help(attachment.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(attachment.kind == .image ? "Image" : "Document") \(attachment.name)")
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
    private var detail: String {
        let pages = attachment.pageCount ?? 0
        if let fits = store.pagesThatFit(attachment), fits < pages { return "first \(fits) of \(pages) pages fit" }
        if !attachment.hasText { return "no readable text" }
        return "\(pages) page\(pages == 1 ? "" : "s")"
    }
    private var removeButton: some View {
        Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { store.removeAttachment(attachment.id) } } label: {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.surface)
                .frame(width: 18, height: 18).background(Theme.ink.opacity(0.85), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel("Remove \(attachment.name)")
    }
    private func url(_ file: String) -> URL { store.storage?.attachments.url(file) ?? URL(fileURLWithPath: "/dev/null") }
}

private struct PendingChip: View {
    @Environment(AppStore.self) private var store
    let pending: PendingAttachment
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(pending.status).font(.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }.frame(maxWidth: 150, alignment: .leading)
        }.padding(.horizontal, 10).frame(height: 58)
            .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button { store.removeAttachment(pending.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.surface)
                        .frame(width: 18, height: 18).background(Theme.ink.opacity(0.85), in: Circle())
                }.buttonStyle(.plain).opacity(hovering ? 1 : 0).offset(x: 6, y: -6).accessibilityLabel("Cancel \(pending.name)")
            }
            .onHover { hovering = $0 }
            .transition(.opacity)
    }
}

struct DocumentLabel: View {
    let name: String
    let detail: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.text.fill").font(.system(size: 18)).foregroundStyle(Theme.ember)
                .frame(width: 34, height: 40).background(Theme.emberSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }.frame(maxWidth: 170, alignment: .leading)
        }.padding(.leading, 9).padding(.trailing, 12).frame(height: 58)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Attachments at the top of a sent message. Images open full size in Preview.
struct SentAttachments: View {
    let attachments: [ChatAttachment]
    let library: AttachmentLibrary?
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            let images = attachments.filter { $0.kind == .image }
            if !images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(images) { image in
                        Button { if let url = library?.url(image.imageFile) { NSWorkspace.shared.open(url) } } label: {
                            AttachmentThumbnail(url: library?.url(image.thumbnailFile) ?? URL(fileURLWithPath: "/dev/null"))
                                .frame(width: size(image).width, height: size(image).height)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
                        }.buttonStyle(.plain).help("Open \(image.name)").accessibilityLabel("Image \(image.name)")
                    }
                }
            }
            ForEach(attachments.filter { $0.kind == .pdf }) { document in
                DocumentLabel(name: document.name, detail: "\(document.pageCount ?? 0) page\(document.pageCount == 1 ? "" : "s")")
            }
        }
    }
    /// One image gets room to be read; several share a row.
    private func size(_ image: ChatAttachment) -> CGSize {
        let maxSide: CGFloat = attachments.filter({ $0.kind == .image }).count == 1 ? 240 : 132
        let width = CGFloat(image.pixelWidth ?? 1), height = CGFloat(image.pixelHeight ?? 1)
        let scale = maxSide / max(width, height)
        return CGSize(width: max(56, width * scale), height: max(56, height * scale))
    }
}

struct DropOverlay: View {
    var body: some View {
        ZStack {
            Theme.paper.opacity(0.88)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.ember, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(18)
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 30, weight: .medium)).foregroundStyle(Theme.ember)
                Text("Drop images or PDFs").font(.display(20))
                Text("They stay on this Mac.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
        }.allowsHitTesting(false).transition(.opacity)
    }
}
