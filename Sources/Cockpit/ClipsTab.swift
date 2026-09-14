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
                onDown: { move(1) },
                onUp: { move(-1) },
                onReturn: { if let it = filtered[safe: selected] { paste(it) } },
                onEscape: onClose
            )
            list.frame(height: IslandMetrics.clipsListHeight)
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

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    if filtered.isEmpty {
                        empty
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                            ClipRow(
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
        .frame(height: IslandMetrics.clipsListHeight)
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

struct ClipRow: View {
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

    var body: some View {
        HStack(spacing: 9) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview)
                    .font(.system(size: 12, design: item.kind == .file ? .monospaced : .default))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 11, height: 11)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text(meta(now: ctx.date))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Ink.faint)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 6)
            if let flash {
                Text(flash)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Level.calm.color)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if hover {
                HStack(spacing: 1) {
                    IconButton(systemName: "arrow.turn.down.left", help: "Paste into the front app", size: 10, action: onPaste)
                    IconButton(systemName: item.pinned ? "pin.slash" : "pin", help: item.pinned ? "Unpin" : "Pin", size: 10, action: onPin)
                    IconButton(systemName: "trash", help: "Delete", size: 10, action: onDelete)
                }
                .transition(.opacity)
            } else if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Ink.faint)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.white.opacity(0.13) : hover ? Color.white.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.easeOut(duration: 0.15), value: selected)
        .help(item.kind == .text ? "Click to copy · ↩ to paste" : "Click to copy")
    }

    @ViewBuilder
    private var leading: some View {
        if let thumb {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: item.kind == .file ? "doc" : item.kind == .image ? "photo" : "text.alignleft")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Ink.dim)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.surface))
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
