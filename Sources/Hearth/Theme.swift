import SwiftUI
import AppKit

/// Design language: a precision instrument that runs warm. Paper and ink, one ember accent
/// reserved for action and "live" state, monospaced figures for anything measured.
enum Theme {
    /// The product name lives here only, so a rename is a one-line change.
    static let appName = "MaxModel"

    static func adaptive(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: alpha)
        })
    }
    static let paper = adaptive(0xF5F2EB, 0x131211)
    static let surface = adaptive(0xFCFAF6, 0x1C1A18)
    static let raised = adaptive(0xEDE8DE, 0x262320)
    static let sidebar = adaptive(0xEFEBE3, 0x0F0E0D)
    static let ink = adaptive(0x1A1916, 0xEEE9DF)
    static let muted = adaptive(0x6E685E, 0xA19A8E)
    static let faint = adaptive(0xA8A196, 0x5E5850)
    static let line = adaptive(0xE2DCD0, 0x2E2B27)
    static let ember = adaptive(0xE4541C, 0xFF6B2C)
    static let emberDeep = adaptive(0xB93F10, 0xE0541A)
    static let emberSoft = adaptive(0xFBE5D9, 0x3A2216)
    static let caution = adaptive(0xA86A12, 0xF0B256)
    static let onEmber = Color.white
}

extension Font {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

/// Small uppercase instrument label.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.muted
    init(_ text: String, color: Color = Theme.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(.mono(10, .semibold)).tracking(1.1).foregroundStyle(color)
    }
}

/// One measured value: a label above a monospaced figure.
struct Readout: View {
    let label: String
    let value: String
    var detail: String? = nil
    var size: CGFloat = 20
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(label)
            Text(value).font(.mono(size, .medium)).foregroundStyle(Theme.ink).contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Card: ViewModifier {
    var padding: CGFloat = 22
    var radius: CGFloat = 16
    var fill: Color = Theme.surface
    var highlighted = false
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(highlighted ? Theme.ember.opacity(0.55) : Theme.line, lineWidth: highlighted ? 1.5 : 1))
    }
}
extension View {
    func card(padding: CGFloat = 22, radius: CGFloat = 16, fill: Color = Theme.surface, highlighted: Bool = false) -> some View {
        modifier(Card(padding: padding, radius: radius, fill: fill, highlighted: highlighted))
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: large ? 14 : 13, weight: .semibold))
            .padding(.horizontal, large ? 20 : 15).padding(.vertical, large ? 12 : 9)
            .foregroundStyle(Theme.onEmber.opacity(enabled ? 1 : 0.85))
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.ember, Theme.emberDeep], startPoint: .top, endPoint: .bottom))
                    .opacity(enabled ? 1 : 0.35)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
            }
            .shadow(color: Theme.ember.opacity(enabled && !configuration.isPressed ? 0.25 : 0), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
struct SoftButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8).foregroundStyle(Theme.ink.opacity(enabled ? 1 : 0.4))
            .background(configuration.isPressed ? Theme.raised : Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
/// Text-weight action in the accent colour.
struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ember.opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4))
            .contentShape(Rectangle())
    }
}

struct Tag: View {
    let text: String
    var icon: String? = nil
    var warm = false
    var body: some View {
        HStack(spacing: 4) { if let icon { Image(systemName: icon) }; Text(text) }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(warm ? Theme.caution : Theme.ink.opacity(0.75))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((warm ? Theme.caution.opacity(0.12) : Theme.raised), in: Capsule())
    }
}

/// The mark: a chip with an ember at its core. `heat` drives the glow (0 idle … 1 working).
/// The app's mark, matching its icon: a chat bubble with an ember inside. The ember glows with
/// `heat` and breathes while the model works.
struct EmberGlyph: View {
    var size: CGFloat = 28
    var heat: Double = 0.6
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let line = max(1.2, size * 0.075), tail = size * 0.2
        let emberCenter = CGPoint(x: size / 2, y: line / 2 + (size - line - tail) / 2)
        ZStack {
            ChatBubble(tail: tail, inset: line / 2)
                .stroke(Theme.ink.opacity(0.85), style: StrokeStyle(lineWidth: line, lineJoin: .round))
            Circle().fill(RadialGradient(colors: [Theme.ember.opacity(0.5 * heat), .clear], center: .center, startRadius: 0, endRadius: size * 0.34))
                .frame(width: size * 0.72, height: size * 0.72).position(emberCenter)
            Circle().fill(LinearGradient(colors: [Theme.ember, Theme.emberDeep], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.24, height: size * 0.24)
                .modifier(Breathing(active: pulsing && !reduceMotion))
                .position(emberCenter)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// One continuous outline, so a stroked bubble has no seam where the tail meets the body.
/// Same geometry as the app icon in scripts/make-icon.swift.
struct ChatBubble: Shape {
    var tail: CGFloat
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let frame = rect.insetBy(dx: inset, dy: inset)
        let w = frame.width
        let body = CGRect(x: frame.minX, y: frame.minY, width: w, height: frame.height - tail)
        let radius = body.height * 0.4, small = w * 0.045
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: body.maxX, y: body.minY), radius),
            (CGPoint(x: body.maxX, y: body.maxY), radius),
            (CGPoint(x: body.minX + w * 0.58, y: body.maxY), small),
            (CGPoint(x: body.minX + w * 0.2, y: body.maxY + tail - inset), small * 0.7),
            (CGPoint(x: body.minX + w * 0.36, y: body.maxY), small),
            (CGPoint(x: body.minX, y: body.maxY), radius),
            (CGPoint(x: body.minX, y: body.minY), radius),
        ]
        let start = CGPoint(x: body.midX, y: body.minY)
        var path = Path()
        path.move(to: start)
        for (index, (corner, cornerRadius)) in corners.enumerated() {
            path.addArc(tangent1End: corner, tangent2End: index + 1 < corners.count ? corners[index + 1].0 : start, radius: cornerRadius)
        }
        path.closeSubpath()
        return path
    }
}

private struct Breathing: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { view, phase in
                view.scaleEffect(phase ? 1.18 : 0.88).opacity(phase ? 1 : 0.75)
            } animation: { _ in .easeInOut(duration: 0.9) }
        } else { content }
    }
}

/// A small status light: hollow when idle, solid when ready, breathing while working.
struct StatusLight: View {
    enum State { case idle, warming, ready, working }
    let state: State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if state == .idle { Circle().strokeBorder(Theme.faint, lineWidth: 1.5) }
            else { Circle().fill(Theme.ember) }
        }.frame(width: 8, height: 8)
            .modifier(Breathing(active: (state == .warming || state == .working) && !reduceMotion))
            .accessibilityHidden(true)
    }
}

/// A light sweeping across text, used for in-progress labels instead of a spinner.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if reduceMotion { content.foregroundStyle(Theme.muted) }
        else {
            content.foregroundStyle(Theme.muted).overlay {
                TimelineView(.animation) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, Theme.ink, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.45)
                            .offset(x: (phase * 1.9 - 0.45) * geometry.size.width)
                    }
                }.mask(content).allowsHitTesting(false)
            }
        }
    }
}
extension View { func shimmering() -> some View { modifier(Shimmer()) } }

/// Diagonal hatching for memory that isn't available to the model.
struct Hatch: View {
    var color: Color = Theme.faint
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height)); path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}

/// One-shot burst of embers for the moment a model becomes yours.
struct EmberBurst: View {
    let start: Date
    private static let particles: [(angle: Double, speed: Double, size: Double, delay: Double)] = (0..<46).map { index in
        let seed = Double((index * 7919) % 997) / 997
        return (angle: -Double.pi / 2 + (seed - 0.5) * 2.6, speed: 180 + Double((index * 31) % 160),
                size: 3 + Double(index % 4), delay: Double(index % 6) * 0.03)
    }
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.62)
                for particle in Self.particles {
                    let t = max(0, elapsed - particle.delay)
                    guard t > 0, t < 1.6 else { continue }
                    let x = origin.x + cos(particle.angle) * particle.speed * t
                    let y = origin.y + sin(particle.angle) * particle.speed * t + 260 * t * t
                    let fade = max(0, 1 - t / 1.6)
                    let rect = CGRect(x: x, y: y, width: particle.size, height: particle.size)
                    context.fill(Path(ellipseIn: rect), with: .color(Theme.ember.opacity(fade)))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
