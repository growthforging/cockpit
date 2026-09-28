import SwiftUI

struct ClipsTab: View {
    @EnvironmentObject var clips: ClipboardStore
    let focusTrigger: Int
    let autoFocus: Bool
    let onCopy: (ClipItem) -> Void      // click: copy back to the clipboard, stay open
    let onPaste: (ClipItem) -> Void     // ↩ or the paste button: copy, close, ⌘V into the front app
    let onClose: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @State private var flash: (id: UUID, text: String)?
    @FocusState private var searchFocused: Bool

    private var filtered: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return clips.items }
        return clips.items.filter {
            ($0.text ?? $0.preview).lowercased().contains(q) || ($0.appName ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            SearchField(
                text: $query,
                focused: $searchFocused,
                // While a search is typed, ←/→ belong to the text, so ↑/↓ step one card at
                // a time and every match stays reachable.
                onDown: { move(query.isEmpty ? IslandMetrics.clipColumns : 1) },
                onUp: { move(query.isEmpty ? -IslandMetrics.clipColumns : -1) },
                onLeft: { move(-1) },
                onRight: { move(1) },
                onReturn: { if let it = filtered[safe: selected] { paste(it) } },
                onEscape: onClose
            )
            grid.frame(height: IslandMetrics.clipsGridHeight)
            footer.frame(height: 20)
        }
        .padding(IslandMetrics.pad)
        .onAppear { if autoFocus { searchFocused = true } }
        .onChange(of: focusTrigger) { _, _ in
            searchFocused = true
            selected = 0
        }
        .onChange(of: query) { _, _ in selected = 0 }
        .onExitCommand(perform: onClose)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                if filtered.isEmpty {
                    empty
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: IslandMetrics.clipColumns), spacing: 8) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                            ClipCard(
                                item: item,
                                selected: idx == selected,
                                flash: flash?.id == item.id ? flash?.text : nil,
                                icon: clips.icon(for: item),
                                thumb: clips.thumb(for: item),
                                onTap: { copy(item) },
                                onPaste: { paste(item) },
                                onPin: { clips.togglePin(item) },
                                onDelete: { clips.delete(item) }
                            )
                            .frame(height: IslandMetrics.clipCardHeight)
                            .id(item.id)
                        }
                    }
                }
            }
            .onChange(of: selected) { _, new in
                if let it = filtered[safe: new] { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(it.id) } }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Ink.faint)
            Text(query.isEmpty ? "Copy something, or take a screenshot, and it lands here." : "Nothing matches “\(query)”.")
                .font(.system(size: 11.5))
                .foregroundStyle(Ink.dim)
        }
        .frame(maxWidth: .infinity)
        .frame(height: IslandMetrics.clipsGridHeight)
    }

    private var footer: some View {
        HStack {
            Text(clips.items.isEmpty ? "⇧⌘V opens this anywhere" : "\(clips.items.count) clips · click copies · ↩ pastes · ⇧⌘V")
                .font(.system(size: 10.5))
                .foregroundStyle(Ink.faint)
            Spacer()
            if !clips.items.isEmpty {
                Button("Clear") { clips.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Ink.dim)
                    .help(clips.pinnedCount > 0 ? "Clear everything except pinned clips" : "Clear the history")
            }
        }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selected = min(max(0, selected + delta), filtered.count - 1)
    }

    private func copy(_ item: ClipItem) {
        showFlash(item, "Copied")
        onCopy(item)
    }

    private func paste(_ item: ClipItem) {
        showFlash(item, AXIsProcessTrusted() ? "Pasted" : "Copied")
        onPaste(item)
    }

    private func showFlash(_ item: ClipItem, _ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { flash = (item.id, text) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            if flash?.id == item.id { withAnimation(.easeOut(duration: 0.2)) { flash = nil } }
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onDown: () -> Void
    let onUp: () -> Void
    let onLeft: () -> Void
    let onRight: () -> Void
    let onReturn: () -> Void
    let onEscape: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Ink.faint)
            TextField("Search clips", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Ink.text)
                .focused(focused)
                .onKeyPress(.downArrow) { onDown(); return .handled }
                .onKeyPress(.upArrow) { onUp(); return .handled }
                // Sideways arrows walk the grid only while there is no text to move through.
                .onKeyPress(.leftArrow) { guard text.isEmpty else { return .ignored }; onLeft(); return .handled }
                .onKeyPress(.rightArrow) { guard text.isEmpty else { return .ignored }; onRight(); return .handled }
                .onKeyPress(.return) { onReturn(); return .handled }
                .onKeyPress(.escape) { onEscape(); return .handled }
            if !text.isEmpty {
                IconButton(systemName: "xmark", help: "Clear search", size: 9) { text = "" }
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .frame(height: 30)
        .background(Capsule().fill(Ink.surface))
        .overlay(Capsule().strokeBorder(focused.wrappedValue ? Ink.borderStrong : Ink.border, lineWidth: 0.5))
        .animation(.easeOut(duration: 0.15), value: focused.wrappedValue)
    }
}

// One clip as a card: a few lines of the text, or the picture itself, and where it came
// from. Click copies; the buttons that appear on hover paste, pin or delete.
struct ClipCard: View {
    let item: ClipItem
    let selected: Bool
    let flash: String?
    let icon: NSImage?
    let thumb: NSImage?
    let onTap: () -> Void
    let onPaste: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 5) {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 12, height: 12)
                }
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(meta(now: ctx.date))
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Ink.faint)
                }
            }
            .frame(height: 12)
        }
        .padding(10)
        .background(shape.fill(selected ? Color.white.opacity(0.13) : hover ? Ink.surfaceHover : Ink.surface))
        .overlay(shape.strokeBorder(selected ? Ink.borderStrong : Ink.border, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) { corner.padding(6) }
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.easeOut(duration: 0.15), value: selected)
        .help(item.kind == .text ? "Click to copy · ↩ to paste" : "Click to copy")
    }

    @ViewBuilder
    private var preview: some View {
        if let thumb {
            Color.clear
                .overlay { Image(nsImage: thumb).resizable().interpolation(.high).scaledToFill() }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else if item.kind == .text {
            // A few hundred characters is plenty for three lines, and keeps a pasted log cheap to draw.
            Text(String((item.text ?? item.preview).trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
                .font(.system(size: 11.5))
                .foregroundStyle(Ink.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: item.kind == .file ? "doc.fill" : "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.dim)
                Text(item.preview)
                    .font(.system(size: 11.5, weight: .medium, design: item.kind == .file ? .monospaced : .default))
                    .foregroundStyle(Ink.text)
                    .lineLimit(2)
            }
        }
    }

    // A confirmation after a click, the actions while the pointer is over the card.
    @ViewBuilder
    private var corner: some View {
        if let flash {
            Text(flash)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Level.calm.color)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.black.opacity(0.8)))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else if hover {
            HStack(spacing: 0) {
                IconButton(systemName: "arrow.turn.down.left", help: "Paste into the front app", size: 10, action: onPaste)
                IconButton(systemName: item.pinned ? "pin.slash" : "pin", help: item.pinned ? "Unpin" : "Pin", size: 10, action: onPin)
                IconButton(systemName: "trash", help: "Delete", size: 10, action: onDelete)
            }
            .padding(.horizontal, 2)
            .background(Capsule().fill(Color.black.opacity(0.8)))
            .overlay(Capsule().strokeBorder(Ink.border, lineWidth: 0.5))
            .transition(.opacity)
        }
    }

    private func meta(now: Date) -> String {
        var parts: [String] = []
        if let app = item.appName { parts.append(app) }
        parts.append(fmtAgo(item.date, now: now))
        if item.kind == .text, item.chars > 80 { parts.append("\(item.chars) chars") }
        if item.kind == .file, item.chars > 1 { parts.append("\(item.chars) files") }
        return parts.joined(separator: " · ")
    }
}
