import SwiftUI

/// Backtick-delimited commands use the same inline treatment throughout settings.
struct CommandText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        if text.contains("`") {
            CommandTextLayout {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Group {
                        if part.code {
                            Text(part.text)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(HarnaisPalette.code)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(HarnaisPalette.accentHover, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(HarnaisPalette.border, lineWidth: 0.5))
                        } else {
                            Text(part.text)
                        }
                    }
                    .layoutValue(key: CommandLeadingSpace.self, value: part.leadingSpace)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text.replacingOccurrences(of: "`", with: ""))
        } else {
            Text(text)
        }
    }

    private struct Part {
        var text: String
        var code: Bool
        var leadingSpace: Bool
    }

    private var parts: [Part] {
        guard let expression = try? NSRegularExpression(pattern: #"`[^`]+`|[^\s`]+"#) else { return [] }
        let source = text as NSString
        var previousEnd = 0
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let value = source.substring(with: match.range)
            let space = source.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd)).contains(where: \.isWhitespace)
            previousEnd = NSMaxRange(match.range)
            let code = value.hasPrefix("`") && value.hasSuffix("`")
            return Part(text: code ? String(value.dropFirst().dropLast()) : value, code: code, leadingSpace: space)
        }
    }
}

private struct CommandLeadingSpace: LayoutValueKey {
    static let defaultValue = false
}

/// Wrap whole commands and align their text baseline with surrounding prose.
private struct CommandTextLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in layout.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading,
                                 proposal: ProposedViewSize(width: layout.widths[index], height: nil))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint], widths: [CGFloat]) {
        let limit = max(1, width)
        var points = [CGPoint](repeating: .zero, count: subviews.count)
        var widths = [CGFloat](repeating: 0, count: subviews.count)
        var row: [(index: Int, x: CGFloat, baseline: CGFloat)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var baseline: CGFloat = 0
        var descent: CGFloat = 0
        var maxWidth: CGFloat = 0
        func finishRow() {
            guard !row.isEmpty else { return }
            for item in row { points[item.index] = CGPoint(x: item.x, y: y + baseline - item.baseline) }
            maxWidth = max(maxWidth, x)
            y += baseline + descent + 5
            row = []
            x = 0
            baseline = 0
            descent = 0
        }
        for (index, view) in subviews.enumerated() {
            let dimensions = view.dimensions(in: ProposedViewSize(width: limit.isFinite ? limit : nil, height: nil))
            let gap: CGFloat = view[CommandLeadingSpace.self] && !row.isEmpty ? 3 : 0
            if !row.isEmpty && x + gap + dimensions.width > limit { finishRow() }
            if !row.isEmpty { x += gap }
            let textBaseline = dimensions[.firstTextBaseline]
            row.append((index, x, textBaseline))
            widths[index] = dimensions.width
            x += dimensions.width
            baseline = max(baseline, textBaseline)
            descent = max(descent, dimensions.height - textBaseline)
        }
        finishRow()
        return (CGSize(width: maxWidth, height: max(0, y - 5)), points, widths)
    }
}
