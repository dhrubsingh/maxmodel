import SwiftUI
import AppKit
import HearthCore

struct MarkdownMessageView: View, Equatable {
    let content: String
    var body: some View {
        MarkdownBlocksView(blocks: ChatMarkdown.parse(content))
            .font(.system(size: 14)).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard ChatMarkdown.safeLink(url.absoluteString) != nil else { return .discarded }
                return .systemAction
            })
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(blocks.indices, id: \.self) { index in block(blocks[index]) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func block(_ value: MarkdownBlock) -> AnyView {
        switch value {
        case .paragraph(let runs):
            return AnyView(InlineMarkdownText(runs: runs).lineSpacing(5))
        case .heading(let level, let runs):
            return AnyView(InlineMarkdownText(runs: runs).font(.system(size: level == 1 ? 23 : level == 2 ? 19 : 16, weight: .semibold)).padding(.top, 5))
        case .code(let language, let text):
            return AnyView(CodeBlockView(language: language, code: text))
        case .quote(let blocks):
            return AnyView(HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.faint).frame(width: 3)
                MarkdownBlocksView(blocks: blocks).foregroundStyle(Theme.muted)
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 3))
        case .list(let start, let items):
            return AnyView(VStack(alignment: .leading, spacing: 9) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let checked = items[index].checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(Theme.ember)
                                .accessibilityLabel(checked ? "Completed" : "Not completed").frame(width: 22, alignment: .trailing)
                        } else {
                            Text(start.map { "\($0 + index)." } ?? "•").monospacedDigit().foregroundStyle(Theme.muted)
                                .frame(minWidth: 18, alignment: .trailing)
                        }
                        MarkdownBlocksView(blocks: items[index].blocks)
                    }
                }
            }.padding(.leading, 4))
        case .table(let header, let rows):
            return AnyView(ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            InlineMarkdownText(runs: header[column]).fontWeight(.semibold)
                                .padding(11).frame(minWidth: 125, maxWidth: 240, alignment: .leading).background(Theme.raised)
                        }
                    }
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(header.indices, id: \.self) { column in
                                InlineMarkdownText(runs: column < rows[row].count ? rows[row][column] : [])
                                    .padding(11).frame(minWidth: 125, maxWidth: 240, alignment: .leading)
                                    .background(row.isMultiple(of: 2) ? Theme.surface : Theme.paper)
                            }
                        }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
            })
        case .rule: return AnyView(Divider().padding(.vertical, 4))
        }
    }
}

private struct InlineMarkdownText: View {
    let runs: [MarkdownRun]
    private var attributed: AttributedString {
        var result = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if run.strikethrough { intent.insert(.strikethrough) }
            if run.code {
                intent.insert(.code)
                part.font = .system(size: 13, design: .monospaced)
                part.backgroundColor = Theme.raised
                part.foregroundColor = Theme.emberDeep
            }
            part.inlinePresentationIntent = intent
            if let link = run.link { part.link = link }
            result += part
        }
        return result
    }
    var body: some View {
        Text(attributed).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language).font(.system(size: 11, weight: .medium, design: .monospaced))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.plain).font(.system(size: 11)).accessibilityLabel("Copy code")
            }.foregroundStyle(Theme.muted).padding(.horizontal, 14).padding(.vertical, 10).background(Theme.raised.opacity(0.7))
            Divider()
            ScrollView(.horizontal) {
                Text(verbatim: code.hasSuffix("\n") ? String(code.dropLast()) : code)
                    .font(.system(size: 12.5, design: .monospaced)).lineSpacing(4)
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(14)
            }
        }.background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .onChange(of: code) { _, _ in copied = false }
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
    }
}
