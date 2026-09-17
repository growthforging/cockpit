import SwiftUI
import AppKit

// `Cockpit --shot out.png` renders the island to a PNG without a screen recording
// permission, a camera, or a steady hand. It draws the real components with sample
// numbers, so a README image cannot drift away from what the app actually looks like.
@MainActor
enum Shot {
    static func render(to path: String, scale: CGFloat = 2) -> Bool {
        let renderer = ImageRenderer(content: HeroShot())
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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

// MARK: - Sample state

private enum Sample {
    static var session: UsageBucket {
        UsageBucket(key: "five_hour", pct: 29, resetAt: Date().addingTimeInterval(2 * 3600 + 5 * 60))
    }
    static var week: UsageBucket {
        UsageBucket(key: "seven_day", pct: 24, resetAt: Date().addingTimeInterval(3 * 86400))
    }
    static var fable: UsageBucket {
        var b = UsageBucket(key: "seven_day_fable", pct: 48, resetAt: Date().addingTimeInterval(3 * 86400))
        b.label = "Fable"
        b.detail = "weekly · model limit"
        return b
    }

    static let sessionPace = Pace(
        verdict: .safe(finishPct: 35, unusedPct: 65, ratePerHour: 2.8),
        risk: .calm, expectedPct: 58
    )
    static let weekPace = Pace(
        verdict: .safe(finishPct: 61, unusedPct: 39, ratePerHour: 0.5),
        risk: .calm, expectedPct: 41
    )
    // The case worth putting in a screenshot: on pace to run out a day before the reset.
    static let fablePace = Pace(
        verdict: .dry(earlySeconds: 99_000, ratePerHour: 1.4),
        risk: .critical, expectedPct: 41
    )
}

// MARK: - The image

private struct HeroShot: View {
    private let canvas = CGSize(width: 1100, height: 420)
    private let menuBarHeight: CGFloat = 32
    private let notchWidth: CGFloat = 185

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            VStack(spacing: 0) {
                menuBar
                island
                Spacer(minLength: 0)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, .dark)
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [
                Color(red: 0.07, green: 0.08, blue: 0.11),
                Color(red: 0.13, green: 0.11, blue: 0.16),
                Color(red: 0.06, green: 0.07, blue: 0.09),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(
                colors: [Level.calm.color.opacity(0.16), .clear],
                center: .top, startRadius: 30, endRadius: 420
            )
        )
    }

    // A plain strip standing in for the menu bar, so the island reads as attached to a notch.
    private var menuBar: some View {
        ZStack {
            Color.black
            HStack(spacing: 16) {
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
                Text("9:41")
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.62))
            .padding(.trailing, 22)
        }
        .frame(height: menuBarHeight)
    }

    private var island: some View {
        VStack(spacing: 0) {
            band
            content
        }
        .frame(width: IslandMetrics.expandedWidth)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: IslandMetrics.expandedRadius,
                bottomTrailingRadius: IslandMetrics.expandedRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
            .shadow(color: .black.opacity(0.5), radius: 18, y: 9)
        )
    }

    // The notch band doubles as the toolbar while the island is open.
    private var band: some View {
        HStack(spacing: 0) {
            SegmentedTabs(tab: .constant(.usage))
                .frame(maxWidth: .infinity)
            Spacer().frame(width: notchWidth)
            HStack(spacing: 2) {
                IconButton(systemName: "arrow.clockwise", help: "") {}
                IconButton(systemName: "gearshape", help: "") {}
                IconButton(systemName: "power", help: "") {}
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: menuBarHeight)
    }

    private var content: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                BucketCard(bucket: Sample.session, pace: Sample.sessionPace, precise: false)
                BucketCard(bucket: Sample.week, pace: Sample.weekPace, precise: false)
            }
            .frame(height: IslandMetrics.cardHeight)

            ModelRow(bucket: Sample.fable, pace: Sample.fablePace, precise: false)
                .frame(height: IslandMetrics.modelRowHeight)

            HStack(spacing: 8) {
                SourcePill(source: .login)
                Text("updated 5s ago")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Ink.faint)
                Spacer()
            }
            .frame(height: 22)
        }
        .padding(IslandMetrics.pad)
    }
}
