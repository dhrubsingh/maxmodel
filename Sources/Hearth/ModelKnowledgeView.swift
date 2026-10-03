import SwiftUI
import HearthCore

/// Small, neutral disclosure wherever a user chooses or uses a model.
struct ModelKnowledgeLabel: View {
    let model: LocalModel
    @State private var showDetails = false
    var body: some View {
        Button { showDetails = true } label: {
            HStack(spacing: 4) {
                Text("Knowledge cutoff: \(model.knowledgeCutoffLabel)")
                Image(systemName: "info.circle")
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.muted)
            .accessibilityLabel("\(model.name) knowledge cutoff: \(model.knowledgeCutoffLabel). More information")
            .popover(isPresented: $showDetails) {
                ModelKnowledgeDetails(model: model).padding(20).frame(width: 355)
            }
    }
}

struct ModelKnowledgeDetails: View {
    let model: LocalModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What this assistant may know").font(.system(size: 13, weight: .semibold))
            Text("\(model.name) · \(model.knowledgeCutoffLabel)").font(.system(size: 12, weight: .medium))
            Text(model.knowledge?.note ?? "We have not verified a publisher-reported cutoff for this model.")
            Text("A cutoff describes the age of training information, not when the model was released. It does not guarantee that every earlier fact is known or correct.")
            Text("This assistant cannot check the web. Downloads and chats do not update its built-in knowledge; verify time-sensitive answers with a current source.")
            if let knowledge = model.knowledge {
                HStack {
                    Link("Publisher source ↗", destination: knowledge.sourceURL)
                    Spacer()
                    Text("Checked \(knowledge.checkedAt)").foregroundStyle(Theme.muted)
                }.font(.system(size: 10))
            }
        }.font(.system(size: 11)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
    }
}
