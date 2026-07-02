import SwiftUI
import AppKit

// GitHub-flavored markdown for chat bubbles. SwiftUI's Text renders inline
// markdown but ignores block structure entirely, so blocks are parsed here
// and rendered as views; inline spans (bold/links/code/@mentions) go through
// AttributedString within each block.

/// Link/mention color for incoming (gray) bubbles. The system accent blue is
/// only ~3.5:1 against the bubble gray; these hold ≥5:1 in both appearances.
let bubbleLinkNSColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(calibratedRed: 0.42, green: 0.72, blue: 1.0, alpha: 1)    // #6BB8FF on dark gray
        : NSColor(calibratedRed: 0.02, green: 0.31, blue: 0.68, alpha: 1)   // #0550AE on light gray
}
let bubbleLinkColor = Color(nsColor: bubbleLinkNSColor)

/// Message actions merged into the top of the text-selection context menu.
struct MessageMenuActions {
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCopyAll: (() -> Void)?
    var onOpenGitHub: (() -> Void)?
}

enum MarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case bullets([(indent: Int, text: String)])
    case ordered([(label: String, text: String)])
    case tasks([(done: Bool, text: String)])
    case quote(String)
    case code(String)
    case table(String)
    case rule
}

final class ParseBox<T> {
    let value: T
    init(_ value: T) { self.value = value }
}

enum MarkdownParser {
    // Transcripts re-render on every published change; parsing is cached so
    // typing in the composer doesn't re-parse every visible message.
    @MainActor private static let blockCache = NSCache<NSString, ParseBox<[MarkdownBlock]>>()
    @MainActor private static let inlineCache = NSCache<NSString, ParseBox<AttributedString>>()

    @MainActor static func parse(_ text: String) -> [MarkdownBlock] {
        if let hit = blockCache.object(forKey: text as NSString) { return hit.value }
        var blocks: [MarkdownBlock] = []
        let parts = text.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 {
                var code = part
                // Drop a leading language tag line ("swift\n…").
                if let nl = code.firstIndex(of: "\n"),
                   code[code.startIndex..<nl].allSatisfy({ !$0.isWhitespace }) {
                    code = String(code[code.index(after: nl)...])
                }
                let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { blocks.append(.code(trimmed)) }
            } else {
                blocks += parseBlocks(part)
            }
        }
        blockCache.setObject(ParseBox(blocks), forKey: text as NSString)
        return blocks
    }

    private static let headingRe = #/^(#{1,6})\s+(.+)$/#
    private static let taskRe = #/^\s*[-*+]\s+\[([ xX])\]\s+(.+)$/#
    private static let bulletRe = #/^(\s*)[-*+]\s+(.+)$/#
    private static let orderedRe = #/^\s*(\d{1,4})[.)]\s+(.+)$/#
    private static let quoteRe = #/^\s*>\s?(.*)$/#

    static func parseBlocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        var bullets: [(indent: Int, text: String)] = []
        var ordered: [(label: String, text: String)] = []
        var tasks: [(done: Bool, text: String)] = []
        var quote: [String] = []

        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        func flushBullets() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
        }
        func flushOrdered() {
            if !ordered.isEmpty { blocks.append(.ordered(ordered)); ordered = [] }
        }
        func flushTasks() {
            if !tasks.isEmpty { blocks.append(.tasks(tasks)); tasks = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flushAll() {
            flushPara(); flushBullets(); flushOrdered(); flushTasks(); flushQuote()
        }

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushAll(); i += 1; continue
            }
            if trimmed.count >= 3, Set(trimmed).count == 1, let f = trimmed.first, "-*_".contains(f) {
                flushAll(); blocks.append(.rule); i += 1; continue
            }
            if let m = trimmed.wholeMatch(of: headingRe) {
                flushAll(); blocks.append(.heading(m.1.count, String(m.2))); i += 1; continue
            }
            if let m = line.wholeMatch(of: taskRe) {
                flushPara(); flushBullets(); flushOrdered(); flushQuote()
                tasks.append((done: String(m.1).lowercased() == "x", text: String(m.2)))
                i += 1; continue
            }
            if let m = line.wholeMatch(of: bulletRe) {
                flushPara(); flushTasks(); flushOrdered(); flushQuote()
                bullets.append((indent: min(m.1.count / 2, 3), text: String(m.2)))
                i += 1; continue
            }
            if let m = line.wholeMatch(of: orderedRe) {
                flushPara(); flushTasks(); flushBullets(); flushQuote()
                ordered.append((label: String(m.1), text: String(m.2)))
                i += 1; continue
            }
            if let m = line.wholeMatch(of: quoteRe) {
                flushPara(); flushTasks(); flushBullets(); flushOrdered()
                quote.append(String(m.1))
                i += 1; continue
            }
            if line.contains("|"), i + 1 < lines.count {
                let sep = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if sep.contains("-"), sep.contains("|") || sep.hasPrefix("-"),
                   !sep.isEmpty, sep.allSatisfy({ "|-: \t".contains($0) }) {
                    flushAll()
                    var rows = [line]
                    i += 1
                    while i < lines.count, lines[i].contains("|") {
                        rows.append(lines[i]); i += 1
                    }
                    blocks.append(.table(rows.joined(separator: "\n")))
                    continue
                }
            }
            flushBullets(); flushOrdered(); flushTasks(); flushQuote()
            para.append(line)
            i += 1
        }
        flushAll()
        return blocks
    }

    // MARK: NSAttributedString variants (for the selectable NSTextView path)

    @MainActor private static let nsInlineCache = NSCache<NSString, NSAttributedString>()

    /// AttributedString presentation intents don't render outside SwiftUI's
    /// Text, so resolve them into concrete AppKit attributes.
    @MainActor static func nsInline(_ s: String, isMine: Bool) -> NSAttributedString {
        let key = (isMine ? "m|" : "o|") + s
        if let hit = nsInlineCache.object(forKey: key as NSString) { return hit }
        let source = inline(s, isMine: isMine)
        let baseColor = isMine ? NSColor.white : NSColor.labelColor
        let baseSize: CGFloat = 13
        let out = NSMutableAttributedString()
        for run in source.runs {
            let text = String(source.characters[run.range])
            var font = NSFont.systemFont(ofSize: baseSize)
            var color = baseColor
            var attrs: [NSAttributedString.Key: Any] = [:]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
                if intent.contains(.strikethrough) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let link = run.link {
                attrs[.link] = link
                color = isMine ? .white : bubbleLinkNSColor
                attrs[.underlineStyle] = 0
            }
            attrs[.font] = font
            attrs[.foregroundColor] = color
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        nsInlineCache.setObject(out, forKey: key as NSString)
        return out
    }

    @MainActor static func nsCode(_ s: String, isMine: Bool) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: isMine ? NSColor.white : NSColor.labelColor,
        ])
    }

    /// Inline markdown + @mention highlighting. Mentions become semibold links
    /// to the user's GitHub profile.
    @MainActor static func inline(_ s: String, isMine: Bool) -> AttributedString {
        let key = (isMine ? "m|" : "o|") + s
        if let hit = inlineCache.object(forKey: key as NSString) { return hit.value }

        var attr = (try? AttributedString(markdown: s, options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(s)

        let plain = String(attr.characters)
        // GitHub logins: alphanumeric + inner hyphens. The lookbehind keeps
        // emails and path-like strings ("a/b@c") from matching.
        if let re = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_/.\\-])@([A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38})"
        ) {
            let ns = plain as NSString
            for m in re.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
                guard let sr = Range(m.range, in: plain) else { continue }
                let startOffset = plain.distance(from: plain.startIndex, to: sr.lowerBound)
                let length = plain.distance(from: sr.lowerBound, to: sr.upperBound)
                let login = String(plain[sr].dropFirst())
                let aStart = attr.index(attr.startIndex, offsetByCharacters: startOffset)
                let aEnd = attr.index(aStart, offsetByCharacters: length)
                attr[aStart..<aEnd].inlinePresentationIntent = .stronglyEmphasized
                attr[aStart..<aEnd].link = URL(string: "https://github.com/\(login)")
                if !isMine {
                    attr[aStart..<aEnd].foregroundColor = bubbleLinkColor
                }
            }
        }
        inlineCache.setObject(ParseBox(attr), forKey: key as NSString)
        return attr
    }
}

// MARK: - Selectable text with message actions in its context menu

/// Read-only NSTextView so selection gets the full system menu (Look Up,
/// Translate, …) with the message actions merged in at the top.
final class MessageTextNSView: NSTextView {
    var actions: MessageMenuActions?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        var index = 0
        func insert(_ title: String, _ selector: Selector) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: index)
            index += 1
        }
        if actions?.onEdit != nil { insert("Edit Message", #selector(editAction)) }
        if actions?.onDelete != nil { insert("Delete Message…", #selector(deleteAction)) }
        if actions?.onCopyAll != nil { insert("Copy Message Text", #selector(copyAllAction)) }
        if actions?.onOpenGitHub != nil { insert("Open on GitHub", #selector(openGitHubAction)) }
        if index > 0 { menu.insertItem(.separator(), at: index) }
        return menu
    }

    @objc private func editAction() { actions?.onEdit?() }
    @objc private func deleteAction() { actions?.onDelete?() }
    @objc private func copyAllAction() { actions?.onCopyAll?() }
    @objc private func openGitHubAction() { actions?.onOpenGitHub?() }
}

struct SelectableMessageText: NSViewRepresentable {
    let attributed: NSAttributedString
    var actions: MessageMenuActions?

    func makeNSView(context: Context) -> MessageTextNSView {
        // Explicit TextKit 1 stack: TK2's measurement doesn't hug single lines,
        // which made short bubbles stretch to the full proposed width.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0.0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let view = MessageTextNSView(frame: NSRect.zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = NSSize.zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        // Per-run colors handle link styling; keep only the pointer cursor.
        view.linkTextAttributes = [NSAttributedString.Key.cursor: NSCursor.pointingHand]
        return view
    }

    func updateNSView(_ view: MessageTextNSView, context: Context) {
        if view.textStorage?.isEqual(to: attributed) != true {
            view.textStorage?.setAttributedString(attributed)
        }
        view.actions = actions
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MessageTextNSView, context: Context) -> CGSize? {
        var width = proposal.width ?? 456
        if !width.isFinite || width < 20 { width = 456 }
        // Measure the string directly — container-free and reliably tight.
        let bounds = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: min(width, max(bounds.width.rounded(.up) + 1, 2)),
                      height: max(bounds.height.rounded(.up), 2))
    }
}

// MARK: - Bubble body view

struct MessageTextView: View {
    let text: String
    let isMine: Bool
    var actions: MessageMenuActions? = nil

    private var base: Color { isMine ? .white : .primary }
    private var secondaryTone: Color { isMine ? .white.opacity(0.82) : Color.secondary }
    private var subtle: Color { isMine ? .white.opacity(0.65) : Color.secondary.opacity(0.85) }

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .tint(isMine ? Color.white : bubbleLinkColor)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 17
        case 2: 15.5
        case 3: 14.5
        default: 13.5
        }
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            SelectableMessageText(attributed: MarkdownParser.nsInline(s, isMine: isMine), actions: actions)

        case .heading(let level, let s):
            Text(MarkdownParser.inline(s, isMine: isMine))
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .foregroundStyle(base)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 2.5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").font(.system(size: 13, weight: .bold)).foregroundStyle(subtle)
                        inlineText(item.text)
                    }
                    .padding(.leading, CGFloat(item.indent) * 14)
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 2.5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(item.label).").font(.system(size: 12.5, weight: .medium)).foregroundStyle(subtle)
                        inlineText(item.text)
                    }
                }
            }

        case .tasks(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11.5))
                            .foregroundStyle(item.done ? (isMine ? Color.white : Color.green) : subtle)
                        inlineText(item.text, color: item.done ? secondaryTone : base)
                    }
                }
            }

        case .quote(let s):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(subtle)
                    .frame(width: 3)
                inlineText(s, color: secondaryTone)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let s):
            SelectableMessageText(attributed: MarkdownParser.nsCode(s, isMine: isMine), actions: actions)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(isMine ? 0.25 : 0.06)))

        case .table(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(base)
                    .padding(8)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(isMine ? 0.25 : 0.06)))

        case .rule:
            Rectangle()
                .fill(subtle.opacity(0.5))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func inlineText(_ s: String, color: Color? = nil) -> some View {
        Text(MarkdownParser.inline(s, isMine: isMine))
            .font(.system(size: 13))
            .foregroundStyle(color ?? base)
            .fixedSize(horizontal: false, vertical: true)
    }
}
