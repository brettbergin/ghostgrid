import AppKit
import GhostGridCore
import SwiftUI

/// A pane's commands, read from its output (see CommandBlockParser), for
/// the blocks panel. Updates are published only while the panel is open.
@MainActor
final class CommandBlockStore: ObservableObject {
    @Published private(set) var blocks: [CommandBlock] = []
    private var parser = CommandBlockParser()
    var isWatched = false {
        didSet { if isWatched { blocks = parser.blocks } }
    }

    var latest: CommandBlock? { parser.blocks.last }
    var all: [CommandBlock] { parser.blocks }

    /// A command started (the shell ran something new).
    var onStart: ((CommandBlock) -> Void)?
    /// A command finished, live (not from a replay).
    var onFinish: ((CommandBlock) -> Void)?
    private var lastStarted: Int?
    private var lastFinished: Int?

    func feed(_ data: Data) {
        parser.feed(data)
        if isWatched { blocks = parser.blocks }
        guard let last = parser.blocks.last else { return }
        if last.id != lastStarted {
            lastStarted = last.id
            onStart?(last)
        }
        if last.isFinished, last.id != lastFinished {
            lastFinished = last.id
            onFinish?(last)
        }
    }

    /// The pane's screen was rebuilt from a replay: read it afresh.
    func replace(with replay: Data) {
        parser.reset()
        parser.feed(replay, replayed: true)
        if isWatched { blocks = parser.blocks }
        lastStarted = parser.blocks.last?.id
        lastFinished = parser.blocks.last(where: \.isFinished)?.id
    }
}

/// What the panel asks the pane to do.
struct CommandBlockActions {
    var copy: (String) -> Void
    var rerun: (String) -> Void
    var close: () -> Void
}

/// Pane > Command Blocks (Cmd+Shift+B): every command run in the pane, newest
/// last, each folding open to its output, with copy, rerun and share.
struct CommandBlocksView: View {
    @ObservedObject var store: CommandBlockStore
    let actions: CommandBlockActions
    @State private var open: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Commands").font(.system(size: 12, weight: .semibold))
                Text("\(store.blocks.count)").foregroundStyle(.secondary).font(.system(size: 11))
                Spacer()
                Button(open.isEmpty ? "Unfold all" : "Fold all") {
                    open = open.isEmpty ? Set(store.blocks.map(\.id)) : []
                }
                .buttonStyle(.borderless)
                Button("Done", action: actions.close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if store.blocks.isEmpty {
                Text("No commands yet. Blocks come from the shell's prompt marks (zsh and bash with Ghostty's shell integration, or nushell).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(store.blocks) { block in
                                BlockRow(block: block, isOpen: open.contains(block.id), actions: actions) {
                                    if open.contains(block.id) { open.remove(block.id) } else { open.insert(block.id) }
                                }
                                .id(block.id)
                            }
                        }
                        .padding(10)
                    }
                    .onAppear { scroller.scrollTo(store.blocks.last?.id, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: Palette.card).opacity(0.97))
        .foregroundStyle(Color(nsColor: Palette.text))
    }
}

private struct BlockRow: View {
    let block: CommandBlock
    let isOpen: Bool
    let actions: CommandBlockActions
    let toggle: () -> Void

    /// The panel shows the last lines of very long output; copy and share
    /// carry all of it.
    private static let shownLines = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                .help(isOpen ? "Fold" : "Unfold")
                .accessibilityLabel(isOpen ? "Fold" : "Unfold")
                Text(block.command ?? "(command not reported)")
                    .font(Font(Palette.mono(12)))
                    .lineLimit(isOpen ? nil : 1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .onTapGesture(perform: toggle)
                Spacer(minLength: 4)
                if let duration = block.duration { Text(Self.format(duration)).font(.system(size: 10)).foregroundStyle(.secondary) }
                Text(block.summary)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor.opacity(0.25)))
                    .foregroundStyle(statusColor)
                Button { actions.copy(block.transcript()) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy command and output").accessibilityLabel("Copy")
                Button { if let command = block.command { actions.rerun(command) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Run again").accessibilityLabel("Run again")
                    .disabled(block.command == nil)
                ShareLink(item: block.transcript()) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless).help("Share").accessibilityLabel("Share")
            }
            if isOpen {
                Text(shownOutput)
                    .font(Font(Palette.mono(11)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    private var statusColor: Color {
        switch block.summary {
        case "ok": Color(nsColor: Palette.success)
        case "running": Color(nsColor: Palette.focus)
        default: Color(nsColor: Palette.failure)
        }
    }

    private var shownOutput: String {
        let output = block.output.isEmpty ? "(no output)" : block.output
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let head = block.isTruncated ? "... (earlier output dropped)\n" : ""
        guard lines.count > Self.shownLines else { return head + output }
        return "... (\(lines.count - Self.shownLines) earlier lines; copy or share for all)\n"
            + lines.suffix(Self.shownLines).joined(separator: "\n")
    }

    private static func format(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000)
            : seconds < 60 ? String(format: "%.1f s", seconds)
            : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}
