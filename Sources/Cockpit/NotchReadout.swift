import SwiftUI
import AppKit

// The idle readouts either side of the notch, and the flared shape of the black body
// they sit on. `Cockpit --lab out.png [image] [y]` renders the old and new readouts
// side by side against a real desktop.
//
// The design came out of a lab render judged by four independent critics. What they
// agreed on, and what this file therefore does: menu-bar weight for the number; colour
// only when there is something to worry about, the way the system battery works; the
// bar anchored on the camera side so nothing shifts when a value gains a digit; and no
// pace tick, which read as a rendering glitch. The critics wanted the number to stay
// white in every state. The user preferred it to take the bar's colour, so it does.

// MARK: - Shape

// The black body beside and under the camera. Its top outer corners flare outward the
// way the hardware notch does where it meets the bezel, so the extension reads as the
// notch grown wider rather than a slab laid over the menu bar.
struct NotchShape: Shape {
    var shoulder: CGFloat = 8   // concave flare at the top outer corners
    var bottom: CGFloat = 10    // convex bottom corners

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottom) }
        set { shoulder = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let k: CGFloat = 0.5523   // cubic approximation of a quarter circle
        let s = max(0, min(shoulder, r.width / 4, r.height / 2))
        let b = max(0, min(bottom, (r.width - 2 * s) / 2, r.height - s))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX + s, y: r.minY + s),
                   control1: CGPoint(x: r.minX + k * s, y: r.minY),
                   control2: CGPoint(x: r.minX + s, y: r.minY + s - k * s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - b))
        p.addCurve(to: CGPoint(x: r.minX + s + b, y: r.maxY),
                   control1: CGPoint(x: r.minX + s, y: r.maxY - b + k * b),
                   control2: CGPoint(x: r.minX + s + b - k * b, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s - b, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX - s, y: r.maxY - b),
                   control1: CGPoint(x: r.maxX - s - b + k * b, y: r.maxY),
                   control2: CGPoint(x: r.maxX - s, y: r.maxY - b + k * b))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY),
                   control1: CGPoint(x: r.maxX - s, y: r.minY + s - k * s),
                   control2: CGPoint(x: r.maxX - k * s, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Model

enum ReadoutSide { case leading, trailing }

// Everything one readout needs, independent of where the numbers came from.
struct ReadoutModel {
    var label: String
    var text: String
    var pct: Double
    var risk: Level
    var synthesized: Bool
    var help: String
}

extension ReadoutModel {
    init(bucket: UsageBucket, pace: Pace, precise: Bool) {
        label = bucket.title
        text = bucket.synthesized ? "–" : fmtPct(bucket.pct, precise: precise)
        pct = bucket.synthesized ? 0 : bucket.pct
        risk = pace.risk
        synthesized = bucket.synthesized
        help = bucket.synthesized
            ? "\(bucket.title) · no usage data yet"
            : "\(bucket.title) · \(bucket.subtitle) · \(pace.verdict.compact)"
    }

    var fraction: CGFloat { CGFloat(min(100, max(0, pct))) / 100 }
    var atLimit: Bool { !synthesized && pct >= 100 }

    // The number takes the bar's colour, so number and bar read as one state: white
    // while it's fine, yellow when ahead of pace, red when running out early.
    var ink: Color {
        if synthesized { return Color.white.opacity(0.35) }
        if atLimit { return Level.critical.color }
        switch risk {
        case .calm: return Color.white.opacity(0.95)
        case .caution: return Level.caution.color
        case .critical: return Level.critical.color
        }
    }

    // White while it's fine. Colour is reserved for the moment it means something.
    var fill: Color {
        switch risk {
        case .calm: return Color.white.opacity(0.8)
        case .caution: return Level.caution.color
        case .critical: return Level.critical.color
        }
    }

    // When usage is hot the whole groove takes the colour, so a low but dangerous value
    // is still unmistakable from across the room.
    var track: Color {
        if synthesized { return Color.white.opacity(0.1) }
        switch risk {
        case .calm: return Color.white.opacity(0.15)
        case .caution: return Level.caution.color.opacity(0.26)
        case .critical: return Level.critical.color.opacity(0.26)
        }
    }
}

// MARK: - The readout

struct NotchReadout: View {
    let model: ReadoutModel
    let side: ReadoutSide

    // Fixed geometry. The bar is anchored on the camera side and the number grows
    // outward in a slot sized for "100%", so nothing moves when a value gains a digit.
    static let barWidth: CGFloat = 20
    static let barHeight: CGFloat = 4
    static let gap: CGFloat = 5
    static let outerInset: CGFloat = 8
    static let innerInset: CGFloat = 3
    // Measured from the real fonts, so "100%" can never overflow into the flared edge.
    static let numberSlot: CGFloat = {
        let digits = NSFont.monospacedDigitSystemFont(ofSize: digitSize, weight: .medium)
        let percent = NSFont.systemFont(ofSize: digitSize * 0.77, weight: .medium)
        let widest = NSMutableAttributedString(string: "100", attributes: [.font: digits])
        widest.append(NSAttributedString(string: "%", attributes: [.font: percent]))
        return ceil(widest.size().width) + 1
    }()
    static var flankWidth: CGFloat { outerInset + numberSlot + gap + barWidth + innerInset }

    fileprivate static let digitSize: CGFloat = 13
    // Half the cap height of the digits: the bar's centre sits on the digits' optical
    // middle rather than on the text frame, which includes descender space.
    private static var capMid: CGFloat { NSFont.systemFont(ofSize: digitSize, weight: .medium).capHeight / 2 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
            if side == .leading {
                number.frame(width: Self.numberSlot, alignment: .trailing)
                bar
            } else {
                bar
                number.frame(width: Self.numberSlot, alignment: .leading)
            }
        }
        .padding(side == .leading ? .leading : .trailing, Self.outerInset)
        .padding(side == .leading ? .trailing : .leading, Self.innerInset)
        .frame(width: Self.flankWidth)
        .help(model.help)
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: model.pct)
    }

    private var number: some View { ReadoutNumber(model: model, size: Self.digitSize) }

    private var bar: some View {
        ReadoutBar(model: model, width: Self.barWidth, height: Self.barHeight)
            .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + Self.capMid }
    }
}

// The digits carry the reading; the percent sign steps back, the way Weather treats its
// degree sign. Shared by the notch and the menu-bar chip so both read the same.
struct ReadoutNumber: View {
    let model: ReadoutModel
    var size: CGFloat = 13

    var body: some View {
        let color = model.ink
        let digits = model.text.hasSuffix("%") ? String(model.text.dropLast()) : model.text
        var line = Text(digits)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
        if model.text.hasSuffix("%") {
            line = line + Text("%")
                .font(.system(size: size * 0.77, weight: .medium))
                .foregroundStyle(color.opacity(0.58))
        }
        return line
            .monospacedDigit()
            .contentTransition(.numericText(value: model.pct))
            .lineLimit(1)
            .fixedSize()
    }
}

// The fill is a plain rectangle clipped by the capsule, so a small value shows as a
// sliver growing out of the rounded end instead of a round dot.
struct ReadoutBar: View {
    let model: ReadoutModel
    var width: CGFloat = 20
    var height: CGFloat = 4

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(model.track)
            if !model.synthesized {
                Rectangle()
                    .fill(model.fill)
                    .frame(width: max(3, width * model.fraction))
            }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
    }
}

// MARK: - Lab

@MainActor
enum DesignLab {
    static func render(to path: String, backdrop: String?, yOffset: CGFloat) -> Bool {
        let image = backdrop.flatMap { NSImage(contentsOfFile: ($0 as NSString).expandingTildeInPath) }
        let renderer = ImageRenderer(content: LabSheet(backdrop: image, yOffset: yOffset))
        renderer.scale = 2
        guard let out = renderer.nsImage, let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try png.write(to: url)
            print("wrote \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
            return true
        } catch {
            print("could not write \(url.path): \(error.localizedDescription)")
            return false
        }
    }
}

private struct LabState {
    let name: String
    let left: ReadoutModel
    let right: ReadoutModel

    static func model(_ label: String, _ pct: Double, _ risk: Level) -> ReadoutModel {
        ReadoutModel(label: label, text: "\(Int(pct))%", pct: pct, risk: risk, synthesized: false, help: "")
    }
    static func empty(_ label: String) -> ReadoutModel {
        ReadoutModel(label: label, text: "–", pct: 0, risk: .calm, synthesized: true, help: "")
    }

    static let all: [LabState] = [
        LabState(name: "Today: Fable running hot, session idle",
                 left: model("Fable", 24, .critical), right: model("Session", 2, .calm)),
        LabState(name: "Mid-week, pace slightly ahead",
                 left: model("Fable", 67, .caution), right: model("Session", 45, .calm)),
        LabState(name: "At the limit",
                 left: model("Fable", 100, .critical), right: model("Session", 88, .critical)),
        LabState(name: "No data yet",
                 left: empty("Fable"), right: empty("Session")),
    ]
}

// The readout that shipped before this one, kept only so the lab can show the change.
private struct PreviousReadout: View {
    let m: ReadoutModel

    var body: some View {
        VStack(spacing: 2.5) {
            Text(m.synthesized ? "—" : m.text)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(m.synthesized ? Ink.faint : m.risk.color)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(width: 26, height: 2.5)
                if !m.synthesized {
                    Capsule().fill(m.risk.color).frame(width: max(2, 26 * m.fraction), height: 2.5)
                }
            }
            .frame(width: 26, height: 4.5)
        }
        .fixedSize()
    }
}

private struct LabSheet: View {
    let backdrop: NSImage?
    let yOffset: CGFloat

    private let screen = CGSize(width: 1512, height: 982)
    private let notchWidth: CGFloat = 185
    private let band: CGFloat = 32
    private let cellSize = CGSize(width: 420, height: 50)
    private let labelWidth: CGFloat = 110

    private var states: [Int] {
        let raw = ProcessInfo.processInfo.environment["COCKPIT_LAB_STATES"] ?? ""
        let picked = raw.split(separator: ",").compactMap { Int($0) }.filter { LabState.all.indices.contains($0) }
        return picked.isEmpty ? Array(LabState.all.indices) : picked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Color.clear.frame(width: labelWidth, height: 1)
                ForEach(states, id: \.self) { i in
                    Text(LabState.all[i].name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .frame(width: cellSize.width, alignment: .center)
                }
            }
            row("Before", before: true)
            row("After", before: false)
            HStack(spacing: 12) {
                Text("Monitor chip")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: labelWidth, alignment: .leading)
                ForEach(states, id: \.self) { i in
                    ZStack {
                        wallpaper
                        StatusBarContent(entries: [LabState.all[i].left, LabState.all[i].right])
                    }
                    .frame(width: cellSize.width, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .padding(24)
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
        .environment(\.colorScheme, .dark)
    }

    private func row(_ title: String, before: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(states, id: \.self) { i in
                cell(state: LabState.all[i], before: before)
            }
        }
    }

    private func cell(state: LabState, before: Bool) -> some View {
        let flank = before ? 62 : NotchReadout.flankWidth
        let bodyWidth = notchWidth + 2 * flank
        let shoulder: CGFloat = before ? 0 : NotchShape().shoulder
        return ZStack(alignment: .top) {
            wallpaper
            ZStack(alignment: .top) {
                if before {
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 9,
                                           bottomTrailingRadius: 9, topTrailingRadius: 0, style: .continuous)
                        .fill(Color.black)
                        .frame(width: bodyWidth, height: band)
                } else {
                    NotchShape(shoulder: shoulder, bottom: 10)
                        .fill(Color.black)
                        .frame(width: bodyWidth + 2 * shoulder, height: band)
                }
                Circle().fill(Color(white: 0.07)).frame(width: 7, height: 7)
                    .offset(y: band / 2 - 3.5)
                HStack(spacing: 0) {
                    Group {
                        if before { PreviousReadout(m: state.left) } else { NotchReadout(model: state.left, side: .leading) }
                    }
                    .frame(width: flank)
                    Spacer().frame(width: notchWidth)
                    Group {
                        if before { PreviousReadout(m: state.right) } else { NotchReadout(model: state.right, side: .trailing) }
                    }
                    .frame(width: flank)
                }
                .frame(height: band)
            }
        }
        .frame(width: cellSize.width, height: cellSize.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // The top-centre of the desktop, aspect-filled to the screen as macOS draws it.
    @ViewBuilder
    private var wallpaper: some View {
        if let backdrop {
            Image(nsImage: backdrop)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: screen.width, height: screen.height)
                .clipped()
                .offset(y: -yOffset)
                .frame(width: cellSize.width, height: cellSize.height, alignment: .top)
                .clipped()
        } else {
            LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.55), Color(red: 0.85, green: 0.45, blue: 0.2)],
                           startPoint: .leading, endPoint: .trailing)
        }
    }
}
