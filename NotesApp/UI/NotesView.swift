import SwiftUI
import AppKit

/// One line of the notes' Markdown: its kind, the marker text before the content (kept as written
/// when the line is edited) and the content itself.
struct NotesLine {
    enum Kind: Equatable { case blank, heading(Int), bullet, task(done: Bool), numbered(Int), paragraph }

    let kind: Kind
    /// Indentation and marker ("  - [ ] ", "## "), exactly as in the text.
    let prefix: String
    let content: String
    /// Nesting depth from the indentation (two spaces or a tab per level).
    let level: Int

    init(_ raw: String) {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = String(raw.dropFirst(indent.count))
        level = min(3, width / 2)
        func split(_ pattern: String) -> (String, String)? {
            guard let r = rest.range(of: pattern, options: .regularExpression) else { return nil }
            return (String(indent) + String(rest[r]), String(rest[r.upperBound...]))
        }
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            kind = .blank; prefix = raw; content = ""
        } else if let (p, c) = split(#"^#{1,6}\s+"#) {
            kind = .heading(p.filter { $0 == "#" }.count); prefix = p; content = c
        } else if let (p, c) = split(#"^[-*•+]\s+\[[ xX]\]\s*"#) {
            kind = .task(done: p.contains("[x]") || p.contains("[X]")); prefix = p; content = c
        } else if let (p, c) = split(#"^[-*•+]\s+"#) {
            kind = .bullet; prefix = p; content = c
        } else if let (p, c) = split(#"^\d+[.)]\s+"#) {
            kind = .numbered(Int(p.filter(\.isNumber)) ?? 1); prefix = p; content = c
        } else {
            kind = .paragraph; prefix = String(indent); content = rest
        }
    }

    var isTask: Bool { if case .task = kind { return true }; return false }

    /// The same line with the checkbox flipped.
    var toggled: String? {
        guard case .task(let done) = kind else { return nil }
        let p = done ? prefix.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
                     : prefix.replacingOccurrences(of: "[ ]", with: "[x]")
        return p + content
    }

    /// The marker a new line after this one starts with (Return at the end of a list item).
    var continuation: String? {
        let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
        switch kind {
        case .bullet: return indent + "- "
        case .task: return indent + "- [ ] "
        case .numbered(let n): return indent + "\(n + 1). "
        default: return nil
        }
    }
}

/// The notes rendered from Markdown and editable in place: double-click a line (or use its pencil)
/// to edit just that line, with its bullet or checkbox kept. Return saves and starts the next list
/// item, Esc cancels, clearing a line deletes it. Timestamps like [12:56] play the recording there.
struct EditableNotes: View {
    let text: String
    var editable = true
    var onToggle: ((Int) -> Void)? = nil
    var onCommit: ((Int, String) -> Void)? = nil
    var onInsert: ((Int, String) -> Void)? = nil
    var onSeek: ((Double) -> Void)? = nil

    @State private var editing: Int?
    @State private var draft = ""
    @State private var hovered: Int?
    @FocusState private var focused: Bool

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, raw in
                row(index, NotesLine(raw))
            }
        }
        .lineSpacing(3)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "notes-time", let seconds = Double(url.host ?? "") else { return ExternalLink.open(url) }
            onSeek?(seconds)
            return .handled
        })
    }

    @ViewBuilder
    private func row(_ index: Int, _ line: NotesLine) -> some View {
        if case .blank = line.kind, editing != index {
            Spacer().frame(height: 4)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                marker(index, line)
                if editing == index {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(font(line))
                        .focused($focused)
                        .onSubmit { commit(index, line, next: true) }
                        .onExitCommand { cancel(index, line) }
                        .onChange(of: focused) { _, now in if !now, editing == index { commit(index, line, next: false) } }
                } else {
                    content(line)
                        .font(font(line))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { begin(index, line) }
                }
                if editable, editing != index {
                    Button { begin(index, line) } label: { Image(systemName: "pencil").font(.caption) }
                        .accessibilityLabel("Edit this line")
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .opacity(hovered == index ? 1 : 0)
                        .help("Edit this line")
                }
            }
            .padding(.leading, CGFloat(line.level) * 18)
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(background(index), in: RoundedRectangle(cornerRadius: 6))
            .padding(.top, topPadding(line))
            .onHover { inside in if inside { hovered = index } else if hovered == index { hovered = nil } }
            .help(editable && editing != index ? "Double-click to edit" : "")
        }
    }

    private func background(_ index: Int) -> AnyShapeStyle {
        if editing == index { return AnyShapeStyle(.tint.opacity(0.10)) }
        if editable, hovered == index { return AnyShapeStyle(.quaternary.opacity(0.35)) }
        return AnyShapeStyle(.clear)
    }

    @ViewBuilder
    private func marker(_ index: Int, _ line: NotesLine) -> some View {
        switch line.kind {
        case .task(let done):
            Button { onToggle?(index) } label: {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .disabled(onToggle == nil)
            .accessibilityLabel(done ? "Mark as not done" : "Mark as done")
        case .bullet:
            Text(line.level == 0 ? "•" : "◦").foregroundStyle(.secondary)
        case .numbered(let n):
            Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
        default:
            EmptyView()
        }
    }

    private func content(_ line: NotesLine) -> some View {
        let done: Bool = { if case .task(let d) = line.kind { return d }; return false }()
        return Self.inline(line.content)
            .strikethrough(done)
            .foregroundStyle(done ? .secondary : .primary)
    }

    private func font(_ line: NotesLine) -> Font {
        switch line.kind {
        case .heading(1): return .title2.bold()
        case .heading(2): return .title3.bold()
        case .heading: return .headline
        default: return .body
        }
    }

    private func topPadding(_ line: NotesLine) -> CGFloat {
        if case .heading(let n) = line.kind { return n <= 2 ? 10 : 4 }
        return 0
    }

    // MARK: Editing

    private func begin(_ index: Int, _ line: NotesLine) {
        guard editable else { return }
        draft = line.content
        editing = index
        DispatchQueue.main.async { focused = true }
    }

    private func commit(_ index: Int, _ line: NotesLine, next: Bool) {
        guard editing == index else { return }
        editing = nil
        let new = line.prefix + draft.replacingOccurrences(of: "\n", with: " ")
        if new != line.prefix + line.content || draft.trimmingCharacters(in: .whitespaces).isEmpty {
            onCommit?(index, new)
        }
        // Return at the end of a list item starts the next one, like any notes app.
        if next, !draft.trimmingCharacters(in: .whitespaces).isEmpty, let continuation = line.continuation {
            onInsert?(index, continuation)
            draft = ""
            editing = index + 1
            DispatchQueue.main.async { focused = true }
        }
    }

    private func cancel(_ index: Int, _ line: NotesLine) {
        editing = nil
        // A list item just started and left empty goes away again.
        if line.content.trimmingCharacters(in: .whitespaces).isEmpty, line.continuation != nil { onCommit?(index, "") }
    }

    // MARK: Inline Markdown

    /// Bold, italics, code and links, with transcript times ("[12:56]") turned into links that play
    /// the recording from there.
    static func inline(_ s: String) -> Text {
        let linked = s
            .replacingOccurrences(of: #"\[(\d{1,2}):(\d{2}):(\d{2})\](?!\()"#, with: "[$1:$2:$3](notes-time://$1-$2-$3)", options: .regularExpression)
            .replacingOccurrences(of: #"\[(\d{1,2}):(\d{2})\](?!\()"#, with: "[$1:$2](notes-time://$1-$2)", options: .regularExpression)
        guard var attributed = try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return Text(s)
        }
        for run in attributed.runs {
            guard let url = run.link else { continue }
            // Notes are written by the model from what was said, so a link may have been planted
            // by someone on the call. Only web links stay clickable (and ask first, see
            // `ExternalLink`); file, app and other links become plain text.
            guard url.scheme == "notes-time" else {
                if !ExternalLink.isWeb(url) { attributed[run.range].link = nil }
                continue
            }
            let parts = (url.host ?? "").split(separator: "-", omittingEmptySubsequences: false).compactMap { Double($0) }
            let seconds = parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : parts.count == 2 ? parts[0] * 60 + parts[1] : 0
            attributed[run.range].link = URL(string: "notes-time://\(Int(seconds))")
            attributed[run.range].font = .body.monospacedDigit()
        }
        return Text(attributed)
    }
}

/// Says what a notes edit taught for later meetings, with Undo and a one-click fix for the rest
/// of these notes.
struct LessonBanner: View {
    let lesson: Vocabulary.NotesLesson
    let remaining: (Vocabulary.NotesLesson.Fix) -> Int
    let replaceAll: (Vocabulary.NotesLesson.Fix) -> Void
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Remembered for future meetings").font(.callout.weight(.semibold))
                ForEach(lesson.fixes, id: \.self) { fix in
                    HStack(spacing: 8) {
                        Text("“\(fix.heard)” → “\(fix.wanted)”").font(.callout)
                        let count = remaining(fix)
                        if count > 0 {
                            Button("Fix \(count) more in these notes") { replaceAll(fix) }
                                .controlSize(.small)
                        }
                    }
                }
                if !lesson.terms.isEmpty {
                    Text("Added to Vocabulary: \(lesson.terms.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Undo", action: undo).controlSize(.small)
                .help("Forget what this edit taught (the edit itself stays)")
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.25)))
    }
}

/// Web links in notes open only after the user has seen the whole address: a link the model wrote
/// could carry meeting details to someone else's site. Any other kind of link is not opened.
enum ExternalLink {
    static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }

    /// For a view's `openURL` action, which SwiftUI calls on the main thread.
    static func open(_ url: URL) -> OpenURLAction.Result {
        guard isWeb(url) else { return .discarded }
        return MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = "Open this link in your browser?"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            return .handled
        }
    }
}
