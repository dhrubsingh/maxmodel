import SwiftUI
import HearthCore

/// The signature instrument: this Mac's memory as one bar, showing what a model needs,
/// what is left, and what macOS keeps for itself. It answers "will this fit?" at a glance.
struct FitMeter: View {
    let hardware: Hardware
    let model: LocalModel
    let profile: RuntimeProfile
    var conditions: MachineConditions? = nil
    /// Download progress fills the model's segment while it arrives.
    var progress: Double? = nil
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Double { max(1, Double(hardware.memory)) }
    private var budget: Double { hardware.modelBudget }
    private var conversation: Double { profile.conversationMemory(for: model) }
    private var needed: Double { profile.memory(for: model) }
    private var weights: Double { max(0, needed - conversation) }
    private var headroom: Double { budget - needed }
    private var heldByOthers: Double {
        guard let conditions else { return 0 }
        return max(0, min(budget, budget - conditions.budget(for: hardware)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 12) {
            bar.frame(height: compact ? 6 : 22)
                .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.82), value: needed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: progress)
            if !compact { legend }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory fit")
        .accessibilityValue("\(model.name) needs about \(LocalModel.size(needed)) of \(LocalModel.size(budget)) available to AI on this Mac. \(headroom >= 0 ? "\(LocalModel.size(headroom)) to spare." : "Over by \(LocalModel.size(-headroom)).")")
    }

    private var bar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = { (bytes: Double) in CGFloat(min(1, max(0, bytes / total))) * width }
            let radius: CGFloat = compact ? 3 : 7
            ZStack(alignment: .leading) {
                // macOS reserve: the whole track is hatched, then the AI budget is painted over it.
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.raised)
                Hatch(color: Theme.faint.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                Rectangle().fill(Theme.raised).frame(width: x(budget))
                if heldByOthers > 0 {
                    Hatch(color: Theme.caution.opacity(0.7)).frame(width: x(heldByOthers)).offset(x: x(budget - heldByOthers))
                }
                // The model itself: weights, then conversation memory.
                HStack(spacing: compact ? 0 : 2) {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.ember.opacity(progress == nil ? 1 : 0.18))
                        if let progress { Rectangle().fill(Theme.ember).frame(width: x(weights) * CGFloat(min(1, max(0, progress)))) }
                    }.frame(width: x(weights))
                    Rectangle().fill(Theme.ember.opacity(progress == nil ? 0.45 : 0.12)).frame(width: max(0, x(needed) - x(weights) - (compact ? 0 : 2)))
                }
                if needed > budget {
                    Rectangle().fill(Theme.caution).frame(width: x(needed) - x(budget)).offset(x: x(budget))
                }
                if !compact {
                    Rectangle().fill(Theme.ink.opacity(0.55)).frame(width: 1.5).offset(x: x(budget) - 0.75).padding(.vertical, -4)
                }
            }.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                key(Theme.ember, "Model", weights)
                key(Theme.ember.opacity(0.45), "Chat memory", conversation)
                if headroom >= 0 { key(Theme.raised, "To spare", headroom, outlined: true) }
                else { key(Theme.caution, "Over by", -headroom) }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Hatch(color: Theme.faint).frame(width: 12, height: 10).clipShape(RoundedRectangle(cornerRadius: 2))
                    Text("macOS keeps \(LocalModel.size(total - budget))").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            if heldByOthers > 0.25 * gib {
                HStack(spacing: 6) {
                    Hatch(color: Theme.caution).frame(width: 12, height: 10).clipShape(RoundedRectangle(cornerRadius: 2))
                    Text("Other apps are holding \(LocalModel.size(heldByOthers)) of that right now. Closing a few gives the model more room.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func key(_ color: Color, _ label: String, _ bytes: Double, outlined: Bool = false) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(outlined ? Theme.faint : .clear))
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text(LocalModel.size(bytes)).font(.mono(11, .medium)).foregroundStyle(Theme.ink).contentTransition(.numericText())
        }
    }
}

/// Friendly names for precision variants of one model.
enum Precision {
    static func shortName(_ quantization: String) -> String {
        let q = quantization.uppercased()
        if q.contains("IQ1") || q.contains("IQ2") || q.contains("Q2") { return "Tiny" }
        if q.contains("Q3") { return "Compact" }
        if q.contains("Q5") || q.contains("Q6") { return "High" }
        if q.contains("Q8") || q.contains("F16") { return "Max" }
        return "Standard"
    }
    static func explanation(_ quantization: String) -> String {
        switch shortName(quantization) {
        case "Tiny", "Compact": return "Compressed further so a larger model fits. Slightly less precise."
        case "High": return "Less compression. A touch closer to the original, for Macs with room to spare."
        case "Max": return "Closest to the original model. Uses the most memory."
        default: return "The usual balance of quality, memory, and speed."
        }
    }
}
