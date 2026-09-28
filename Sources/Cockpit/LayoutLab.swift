import SwiftUI
import AppKit

// `Cockpit --layout-lab <dir> [backdrop] [y]` renders the island's layouts to <dir>,
// drawn with the shipping components and sample data over a real desktop:
//   idle.png   each idle layout under Finder's short menu row and Chrome's long one
//   open.png   the open island's usage and clips tabs, over Chrome's menus
@MainActor
enum LayoutLab {
    static func render(to dir: String, backdrop: String?, yOffset: CGFloat) -> Bool {
        let folder = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = backdrop.flatMap { NSImage(contentsOfFile: ($0 as NSString).expandingTildeInPath) }
        let world = LabWorld(backdrop: image, yOffset: yOffset)
        let sheets: [(String, AnyView)] = [
            ("idle", AnyView(IdleSheet(world: world))),
            ("open", AnyView(OpenSheet(world: world))),
        ]
        var ok = true
        for (name, view) in sheets {
            let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { ok = false; continue }
            let url = folder.appendingPathComponent("\(name).png")
            do {
                try png.write(to: url)
                print("wrote \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
            } catch {
                print("could not write \(url.path): \(error.localizedDescription)")
                ok = false
            }
        }
        return ok
    }
}

// MARK: - The desktop the layouts sit on

private struct LabWorld {
    let backdrop: NSImage?
    let yOffset: CGFloat
    let screen = CGSize(width: 1512, height: 982)
    let notchWidth: CGFloat = 185
    let band: CGFloat = 32

    // A strip of the desktop starting `x` points from the left edge, the image
    // aspect-filled to the screen the way macOS draws it.
    @ViewBuilder
    func wallpaper(x: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        if let backdrop {
            Image(nsImage: backdrop)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: screen.width, height: screen.height)
                .clipped()
                .offset(x: screen.width / 2 - (x + width / 2), y: screen.height / 2 - yOffset - height / 2)
                .frame(width: width, height: height)
                .clipped()
        } else {
            LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.55), Color(red: 0.85, green: 0.45, blue: 0.2)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: width, height: height)
        }
    }
}

private struct MockMenuBar: View {
    let app: String
    let menus: [String]

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 19) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
                Text(app).font(.system(size: 13, weight: .bold))
                ForEach(menus, id: \.self) { Text($0).font(.system(size: 13)) }
            }
            .padding(.leading, 20)
            Spacer()
            HStack(spacing: 16) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
                Text("Mon 28 Sep  14:42")
            }
            .font(.system(size: 13))
            .padding(.trailing, 16)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
        .frame(width: 1512, height: 32)
    }

    static let finder = MockMenuBar(app: "Finder", menus: ["File", "Edit", "View", "Go", "Window", "Help"])
    static let chrome = MockMenuBar(app: "Chrome", menus: ["File", "Edit", "View", "History", "Bookmarks", "Profiles", "Tab", "Window", "Help"])
}

private enum Sample {
    static let now = Date()
    static var session: UsageBucket { UsageBucket(key: "five_hour", pct: 29, resetAt: now.addingTimeInterval(2 * 3600 + 300)) }
    static var week: UsageBucket { UsageBucket(key: "seven_day", pct: 24, resetAt: now.addingTimeInterval(3 * 86400)) }
    static var fable: UsageBucket {
        var b = UsageBucket(key: "seven_day_fable", pct: 48, resetAt: now.addingTimeInterval(3 * 86400))
        b.label = "Fable"
        b.detail = "weekly · model limit"
        return b
    }
    static let sessionPace = Pace(verdict: .safe(finishPct: 35, unusedPct: 65, ratePerHour: 2.8), risk: .calm, expectedPct: 58)
    static let weekPace = Pace(verdict: .safe(finishPct: 61, unusedPct: 39, ratePerHour: 0.5), risk: .calm, expectedPct: 41)
    static let fablePace = Pace(verdict: .dry(earlySeconds: 99_000, ratePerHour: 1.4), risk: .critical, expectedPct: 41)

    static var left: ReadoutModel { ReadoutModel(bucket: fable, pace: fablePace, precise: false) }
    static var right: ReadoutModel { ReadoutModel(bucket: session, pace: sessionPace, precise: false) }

    struct Clip { let item: ClipItem; let icon: NSImage?; let thumb: NSImage? }

    static func clips(thumb: NSImage?) -> [Clip] {
        func item(_ kind: ClipKind, _ text: String?, _ preview: String, _ app: String, _ minutes: Double, chars: Int = 0, pinned: Bool = false) -> ClipItem {
            ClipItem(id: UUID(), kind: kind, text: text, preview: preview, imageFile: nil, hash: UUID().uuidString,
                     date: now.addingTimeInterval(-minutes * 60), appBundleID: nil, appName: app, pinned: pinned, chars: chars)
        }
        func icon(_ path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
        let code = "func fetchUsage(token: String) async throws -> UsageSnapshot {\n    var req = URLRequest(url: endpoint)\n    req.setValue(\"Bearer \\(token)\", forHTTPHeaderField: \"Authorization\")"
        return [
            Clip(item: item(.text, code, "func fetchUsage(token: String) async throws -> UsageSnapshot {", "Claude", 2, chars: 142), icon: icon("/Applications/Claude.app"), thumb: nil),
            Clip(item: item(.text, "https://github.com/growthforging/cockpit/pull/12", "https://github.com/growthforging/cockpit/pull/12", "Google Chrome", 6), icon: icon("/Applications/Google Chrome.app"), thumb: nil),
            Clip(item: item(.image, nil, "Screenshot 2026-09-28 at 14.42", "Screenshot", 14), icon: icon("/System/Applications/Utilities/Screenshot.app"), thumb: thumb),
            Clip(item: item(.text, "Meeting moved to Thursday 15:00, same link as last week", "Meeting moved to Thursday 15:00, same link as last week", "Telegram", 38), icon: icon("/Applications/Telegram.app"), thumb: nil),
            Clip(item: item(.file, "/Users/me/Desktop/cockpit/docs/cockpit.png", "cockpit.png", "Finder", 61), icon: icon("/System/Library/CoreServices/Finder.app"), thumb: nil),
            Clip(item: item(.text, "#FFD60A", "#FFD60A", "Figma", 180, pinned: true), icon: icon("/Applications/Figma.app"), thumb: nil),
        ]
    }
}

// MARK: - Idle

private struct IdleSheet: View {
    let world: LabWorld
    private let cropX: CGFloat = 330
    private let cropW: CGFloat = 830

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Idle layouts").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            HStack(spacing: 14) {
                Color.clear.frame(width: 200, height: 1)
                Text("Finder in front").frame(width: cropW)
                Text("Chrome in front").frame(width: cropW)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.6))
            row("split", .split)
            row("stacked", .stacked)
            row("single", .single)
            row("notch only", .notchOnly)
        }
        .padding(24)
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
    }

    private func row(_ title: String, _ layout: IdleLayout) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 200, alignment: .leading)
            cell(MockMenuBar.finder, layout)
            cell(MockMenuBar.chrome, layout)
        }
    }

    // The same arithmetic IslandView uses: the body is centred on the screen, then
    // shifted by the layout's lean to the right.
    private func cell(_ bar: MockMenuBar, _ layout: IdleLayout) -> some View {
        let s = IslandMetrics.shoulder
        let width = world.notchWidth + layout.leftWidth + layout.rightWidth
        let shift = (layout.rightWidth - layout.leftWidth) / 2
        return ZStack(alignment: .topLeading) {
            world.wallpaper(x: cropX, width: cropW, height: 46)
            ZStack(alignment: .top) {
                bar
                ZStack(alignment: .top) {
                    NotchShape(shoulder: s, bottom: 10)
                        .fill(Color.black)
                        .frame(width: width + 2 * s, height: world.band)
                    IdleReadouts(left: Sample.left, right: Sample.right, layout: layout, notchWidth: world.notchWidth)
                        .frame(height: world.band)
                }
                .offset(x: shift)
            }
            .frame(width: world.screen.width, height: 46, alignment: .top)
            .offset(x: -cropX)
            .frame(width: cropW, height: 46, alignment: .topLeading)
            .clipped()
        }
        .frame(width: cropW, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Open

private struct OpenSheet: View {
    let world: LabWorld

    var body: some View {
        let clips = Sample.clips(thumb: world.backdrop.map(Self.thumbnail))
        VStack(alignment: .leading, spacing: 18) {
            Text("Open island").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            panel(.usage, modelBuckets: 1) {
                VStack(spacing: 10) {
                    BucketGrid(entries: [
                        (Sample.session, Sample.sessionPace),
                        (Sample.week, Sample.weekPace),
                        (Sample.fable, Sample.fablePace),
                    ], precise: false)
                    HStack(spacing: 8) {
                        SourcePill(source: .login)
                        Text("updated 5s ago").font(.system(size: 10.5)).foregroundStyle(Ink.faint)
                        Spacer()
                    }
                    .frame(height: 22)
                }
                .padding(IslandMetrics.pad)
            }
            panel(.clips, modelBuckets: 0) {
                VStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.faint)
                        Text("Search clips").font(.system(size: 12)).foregroundStyle(Ink.faint)
                        Spacer()
                    }
                    .padding(.leading, 11)
                    .frame(height: 30)
                    .background(Capsule().fill(Ink.surface))
                    .overlay(Capsule().strokeBorder(Ink.border, lineWidth: 0.5))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: IslandMetrics.clipColumns), spacing: 8) {
                        ForEach(Array(clips.enumerated()), id: \.offset) { i, c in
                            ClipCard(item: c.item, selected: i == 0, flash: nil, icon: c.icon, thumb: c.thumb,
                                     onTap: {}, onPaste: {}, onPin: {}, onDelete: {})
                                .frame(height: IslandMetrics.clipCardHeight)
                        }
                    }
                    .frame(height: IslandMetrics.clipsGridHeight, alignment: .top)
                    HStack {
                        Text("\(clips.count) clips · click copies · ↩ pastes · ⇧⌘V").font(.system(size: 10.5)).foregroundStyle(Ink.faint)
                        Spacer()
                    }
                    .frame(height: 20)
                }
                .padding(IslandMetrics.pad)
            }
        }
        .padding(24)
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
    }

    // Clipboard thumbnails are small; a full-size wallpaper here throws off the renderer's colours.
    private static func thumbnail(_ image: NSImage) -> NSImage {
        let size = NSSize(width: 400, height: 260)
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private func panel<Content: View>(_ tab: IslandTab, modelBuckets: Int, @ViewBuilder content: () -> Content) -> some View {
        let w = IslandMetrics.expandedWidth
        let s = IslandMetrics.shoulder
        let height = world.band + IslandMetrics.contentHeight(tab: tab, modelBuckets: modelBuckets, hasNote: false, hasHint: false)
        let cropX: CGFloat = 256
        let cropW: CGFloat = 1000
        return ZStack(alignment: .topLeading) {
            world.wallpaper(x: cropX, width: cropW, height: height + 30)
            ZStack(alignment: .top) {
                MockMenuBar.chrome
                ZStack(alignment: .top) {
                    NotchShape(shoulder: s, bottom: IslandMetrics.expandedRadius)
                        .fill(Color.black)
                        .frame(width: w + 2 * s, height: height)
                        .shadow(color: .black.opacity(0.32), radius: 10, y: 5)
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            SegmentedTabs(tab: .constant(tab))
                            Spacer(minLength: world.notchWidth)
                            HStack(spacing: 2) {
                                IconButton(systemName: "arrow.clockwise", help: "") {}
                                IconButton(systemName: "gearshape", help: "") {}
                                IconButton(systemName: "power", help: "") {}
                            }
                        }
                        .padding(.horizontal, IslandMetrics.pad)
                        .frame(height: world.band)
                        content()
                    }
                    .frame(width: w, height: height, alignment: .top)
                    .clipShape(NotchShape(shoulder: 0, bottom: IslandMetrics.expandedRadius))
                }
            }
            .frame(width: world.screen.width, height: height + 30, alignment: .top)
            .offset(x: -cropX)
            .frame(width: cropW, height: height + 30, alignment: .topLeading)
            .clipped()
        }
        .frame(width: cropW, height: height + 30)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
