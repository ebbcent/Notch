import SwiftUI

enum CardLayout {
    static let textFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let header: CGFloat = 20
    static let gap: CGFloat = 10
    static let boxPadding: CGFloat = 12
    static let buttons: CGFloat = 28
    static var innerWidth: CGFloat { Layout.expandedBodyWidth - 2 * Layout.outerPadding }

    /// Height of the full text at the card's width.
    static func textHeight(_ text: String) -> CGFloat {
        let bounds = NSAttributedString(string: text, attributes: [.font: textFont])
            .boundingRect(with: NSSize(width: innerWidth - 2 * boxPadding, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height) + 2
    }

    /// Height of the card below the notch; the text box scrolls past `maxText`.
    static func height(for text: String, maxText: CGFloat) -> CGFloat {
        // Very long requests (a large file write) scroll anyway: skip measuring them.
        let measured = text.utf8.count > 50_000 ? maxText : textHeight(text)
        let box = min(measured, maxText) + 2 * boxPadding
        return Layout.tileTopGap + header + gap + box + 12 + buttons + Layout.tileTopGap
    }
}

/// A permission request, shown whole. "Allow" works only once every line has been on screen.
struct PermissionCard: View {
    let request: PermissionRequest
    let palette: Palette
    let pendingCount: Int
    @EnvironmentObject var claude: ClaudeService
    @State private var viewportHeight: CGFloat = 0
    @State private var markerY: CGFloat = .greatestFiniteMagnitude

    private func checkSeen() {
        if viewportHeight > 0, markerY <= viewportHeight + 0.5 {
            claude.lastLineVisible(for: request.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: request.tool == "Bash" ? "terminal" : "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text(request.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 8)
                if pendingCount > 1 {
                    Text("+\(pendingCount - 1) waiting")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondary)
                }
                if !request.project.isEmpty {
                    Label(request.project, systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondary)
                }
            }
            .lineLimit(1)
            .frame(height: CardLayout.header)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(request.body)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Reaching this marker means the last line is on screen.
                    GeometryReader { geo in
                        Color.clear.preference(key: EndMarkerKey.self,
                                               value: geo.frame(in: .named("requestScroll")).maxY)
                    }
                    .frame(height: 1)
                }
                .padding(CardLayout.boxPadding)
            }
            .coordinateSpace(name: "requestScroll")
            .background(GeometryReader { geo in
                Color.clear.preference(key: ViewportKey.self, value: geo.size.height)
            })
            .onPreferenceChange(EndMarkerKey.self) { endY in
                MainActor.assumeIsolated {
                    markerY = endY
                    checkSeen()
                }
            }
            .onPreferenceChange(ViewportKey.self) { height in
                MainActor.assumeIsolated {
                    viewportHeight = height
                    checkSeen()
                }
            }
            .background(RoundedRectangle(cornerRadius: Layout.tileRadius, style: .continuous).fill(palette.tile))
            .padding(.top, CardLayout.gap)

            HStack(spacing: 8) {
                Button("Ask in Terminal") { claude.answer(request.id, with: nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .help("Let Claude Code ask in its own window")
                if !claude.currentFullySeen {
                    Text("Scroll to the end to allow")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                }
                Spacer()
                CardButton(title: "Deny", shortcut: claude.shortcutsAvailable ? HotKeys.deny.label : nil,
                           fill: palette.secondary.opacity(0.2), text: palette.text) {
                    claude.answer(request.id, with: false)
                }
                CardButton(title: "Allow", shortcut: claude.shortcutsAvailable ? HotKeys.allow.label : nil,
                           fill: palette.accent, text: palette.background) {
                    claude.answer(request.id, with: true)
                }
                .disabled(!claude.currentFullySeen)
                .opacity(claude.currentFullySeen ? 1 : 0.4)
            }
            .frame(height: CardLayout.buttons)
            .padding(.top, 12)
        }
        .padding(.horizontal, Layout.outerPadding)
        .padding(.top, Layout.tileTopGap)
        .padding(.bottom, Layout.tileTopGap)
    }
}

private struct EndMarkerKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct CardButton: View {
    let title: String
    let shortcut: String?
    let fill: Color
    let text: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let shortcut {
                    Text(shortcut).font(.system(size: 11, weight: .medium)).opacity(0.7)
                }
            }
            .foregroundStyle(text)
            .padding(.horizontal, 14)
            .frame(height: CardLayout.buttons)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Compact pill while Claude works: the current step on the left, a small animated grid on the right.
struct ClaudeCompactView: View {
    let palette: Palette
    let notchSize: CGSize
    @EnvironmentObject var claude: ClaudeService

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: claude.activity?.symbol ?? "sparkle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Layout.compactSide)
                .help(claude.activity.map { "\($0.verb) \($0.detail)" } ?? "")
            Spacer().frame(width: notchSize.width)
            WorkingGrid(color: palette.accent)
                .frame(width: Layout.compactSide)
        }
        .frame(height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude Code: \(claude.activity?.verb ?? "working")")
    }
}

/// 3×3 dots lighting up in a diagonal wave.
struct WorkingGrid: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Grid(horizontalSpacing: 2.5, verticalSpacing: 2.5) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { col in
                            let phase = t * 4 - Double(row + col) * 0.6
                            Circle()
                                .fill(color)
                                .frame(width: 3, height: 3)
                                .opacity(0.25 + 0.75 * max(0, sin(phase)))
                        }
                    }
                }
            }
        }
    }
}
