import Domain
import SwiftUI

/// Daily usage chart drawn with T3's monotone cubics, not Swift Charts.
///
/// SwiftUI `Shape`/`Path` views scale each path to its own bounding box, so a
/// quieter series would be stretched to the full plot height. `Canvas` keeps
/// every provider on the shared nice scale, matching T3's SVG.
struct UsageTrendChart: View {
    let metric: UsageMetric
    private let model: ChartModel

    init(points: [UsageDayPoint], metric: UsageMetric = .cost) {
        self.metric = metric
        self.model = ChartModel(points: points, metric: metric)
    }
    @State private var hoverIndex: Int?
    @State private var hoverPoint: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                yAxis(model)
                    .frame(width: 88, height: CGFloat(UsageChartMath.plotHeight))
                plot(model)
                    .frame(maxWidth: .infinity)
                    .frame(height: CGFloat(UsageChartMath.plotHeight))
            }
            xLabels(model)
                .padding(.leading, 96)
        }
        .frame(minHeight: 248)
        .accessibilityLabel(metric == .cost ? "Daily cost by provider" : "Daily processed tokens by provider")
    }

    private func yAxis(_ model: ChartModel) -> some View {
        ChartYAxisLayout(ticks: model.ticks, max: model.max) {
            ForEach(Array(model.ticks.enumerated()), id: \.offset) { _, tick in
                Text(tick == 0 ? "0" : model.format(tick))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(HarnaisPalette.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityHidden(true)
    }

    private func plot(_ model: ChartModel) -> some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(model: model, in: &context, size: size)
                }
                if let hoverIndex, model.dates.indices.contains(hoverIndex), let hoverPoint {
                    tooltip(model, index: hoverIndex)
                        .offset(
                            x: tooltipX(point: hoverPoint, width: width),
                            y: tooltipY(
                                point: hoverPoint,
                                height: geo.size.height,
                                providers: model.tooltipProviders.count
                            )
                        )
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverPoint = location
                    guard model.dates.count > 1 else {
                        hoverIndex = model.dates.isEmpty ? nil : 0
                        return
                    }
                    let fraction = min(max(location.x / width, 0), 1)
                    hoverIndex = Int((fraction * Double(model.dates.count - 1)).rounded())
                case .ended:
                    hoverIndex = nil
                    hoverPoint = nil
                }
            }
        }
    }

    private func draw(model: ChartModel, in context: inout GraphicsContext, size: CGSize) {
        let width = max(size.width, 1)
        let height = size.height
        for tick in model.ticks {
            let y = UsageChartMath.y(value: tick, max: model.max, height: Double(height))
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: width, y: y))
            context.stroke(grid, with: .color(HarnaisPalette.border), lineWidth: 1)
        }

        let series = model.paths(width: width, height: height)
        for item in series {
            context.fill(item.area, with: .color(HarnaisPalette.chartFill(for: item.provider)))
        }
        for item in series {
            context.stroke(
                item.line,
                with: .color(HarnaisPalette.chartStroke(for: item.provider)),
                style: StrokeStyle(lineWidth: 2, lineCap: .butt, lineJoin: .round)
            )
        }

        if let hoverIndex, !model.dates.isEmpty {
            let x: CGFloat
            if model.dates.count == 1 {
                x = width / 2
            } else {
                x = CGFloat(hoverIndex) * width / CGFloat(model.dates.count - 1)
            }
            var hairline = Path()
            hairline.move(to: CGPoint(x: x, y: UsageChartMath.plotTop))
            hairline.addLine(to: CGPoint(x: x, y: height))
            context.stroke(hairline, with: .color(HarnaisPalette.label), lineWidth: 1)
        }
    }

    private func tooltip(_ model: ChartModel, index: Int) -> some View {
        let date = model.dates[index]
        let total = model.providers.reduce(0.0) { $0 + model.value($1, at: date) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(model.axisLabel(date, uppercase: false))
                .font(.system(size: 11))
                .foregroundStyle(HarnaisPalette.label)
            ForEach(model.tooltipProviders, id: \.self) { provider in
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        ProviderMark(provider: provider, size: 12)
                        Text(provider.displayName)
                            .foregroundStyle(HarnaisPalette.label)
                    }
                    Spacer(minLength: 12)
                    Text(model.format(model.value(provider, at: date)))
                        .foregroundStyle(HarnaisPalette.text)
                        .monospacedDigit()
                }
            }
            Rectangle()
                .fill(HarnaisPalette.border)
                .frame(height: 1)
                .padding(.top, 2)
            HStack {
                Text("Total")
                    .foregroundStyle(HarnaisPalette.label)
                Spacer(minLength: 12)
                Text(model.format(total))
                    .foregroundStyle(HarnaisPalette.text)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 168, alignment: .leading)
        .background(HarnaisPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(HarnaisPalette.hairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 2)
        .allowsHitTesting(false)
    }

    private func tooltipX(point: CGPoint, width: CGFloat) -> CGFloat {
        let tooltipWidth: CGFloat = 168
        let gap: CGFloat = 12
        let preferred = point.x + gap + tooltipWidth <= width
            ? point.x + gap
            : point.x - gap - tooltipWidth
        return min(max(0, preferred), max(0, width - tooltipWidth))
    }

    private func tooltipY(point: CGPoint, height: CGFloat, providers: Int) -> CGFloat {
        let cardHeight = heightForTooltip(providers: providers)
        let gap: CGFloat = 12
        let preferred = point.y + gap + cardHeight <= height
            ? point.y + gap
            : point.y - gap - cardHeight
        return min(max(0, preferred), max(0, height - cardHeight))
    }

    private func heightForTooltip(providers: Int) -> CGFloat {
        let rows = CGFloat(1 + max(providers, 1) + 1)
        return 16 + 8 + rows * 18 + 12
    }

    private func xLabels(_ model: ChartModel) -> some View {
        HStack {
            Text(model.axisLabel(model.dates.first, uppercase: false))
            Spacer()
            if model.dates.count > 2 {
                Text(model.axisLabel(model.dates[model.dates.count / 2], uppercase: false))
            }
            Spacer()
            Text(model.axisLabel(model.dates.last, uppercase: false))
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(HarnaisPalette.tertiary)
        .textCase(.uppercase)
    }
}

private struct ChartYAxisLayout: Layout {
    var ticks: [Double]
    var max: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 76, height: proposal.height ?? CGFloat(UsageChartMath.plotHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for index in subviews.indices {
            let tick = ticks.indices.contains(index) ? ticks[index] : 0
            let y = UsageChartMath.y(value: tick, max: max, height: bounds.height)
            subviews[index].place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + y),
                anchor: .trailing,
                proposal: .unspecified
            )
        }
    }
}

private struct ChartModel {
    var metric: UsageMetric
    var dates: [Date]
    var providers: [ProviderKind]
    var values: [ProviderKind: [Date: Double]]
    var max: Double
    var ticks: [Double]

    var tooltipProviders: [ProviderKind] {
        ProviderKind.allCases.filter(providers.contains)
    }

    struct Series {
        var provider: ProviderKind
        var area: Path
        var line: Path
    }

    init(points: [UsageDayPoint], metric: UsageMetric) {
        self.metric = metric
        dates = Array(Set(points.map(\.date))).sorted()
        var values: [ProviderKind: [Date: Double]] = [:]
        var totals: [ProviderKind: Double] = [:]
        var peak = 0.0
        for point in points {
            let value = metric == .cost ? point.cost : point.tokens
            var bucket = values[point.provider] ?? [:]
            bucket[point.date, default: 0] += value
            values[point.provider] = bucket
            totals[point.provider, default: 0] += value
            peak = Swift.max(peak, bucket[point.date] ?? 0)
        }
        self.values = values
        providers = totals.keys.sorted { (totals[$0] ?? 0) > (totals[$1] ?? 0) }
        let scale = UsageChartMath.niceScale(peak: peak)
        max = scale.max
        ticks = scale.ticks
    }

    func value(_ provider: ProviderKind, at date: Date) -> Double {
        values[provider]?[date] ?? 0
    }

    func format(_ value: Double) -> String {
        metric == .cost ? UsageFormat.usd(value) : UsageFormat.tokens(value)
    }

    func axisLabel(_ date: Date?, uppercase: Bool) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        let text = formatter.string(from: date)
        return uppercase ? text.uppercased() : text
    }

    func paths(width: CGFloat, height: CGFloat) -> [Series] {
        guard !dates.isEmpty, width > 0 else { return [] }
        if dates.count == 1 {
            let x = Double(width) / 2
            return providers.map { provider in
                let y = UsageChartMath.y(
                    value: value(provider, at: dates[0]),
                    max: max,
                    height: Double(height)
                )
                var line = Path()
                line.addEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
                return Series(provider: provider, area: Path(), line: line)
            }
        }
        let step = Double(width) / Double(dates.count - 1)
        return providers.map { provider in
            let points = dates.enumerated().map { index, date in
                UsageChartMath.Point(
                    x: Double(index) * step,
                    y: UsageChartMath.y(value: value(provider, at: date), max: max, height: Double(height))
                )
            }
            let segments = UsageChartMath.smoothCurve(points)
            var line = Path()
            var area = Path()
            if let first = segments.first {
                line.move(to: cg(first.from))
                area.move(to: cg(first.from))
                for segment in segments {
                    line.addCurve(to: cg(segment.to), control1: cg(segment.c1), control2: cg(segment.c2))
                    area.addCurve(to: cg(segment.to), control1: cg(segment.c1), control2: cg(segment.c2))
                }
                if let last = segments.last {
                    area.addLine(to: CGPoint(x: last.to.x, y: height))
                    area.addLine(to: CGPoint(x: first.from.x, y: height))
                    area.closeSubpath()
                }
            }
            return Series(provider: provider, area: area, line: line)
        }
    }

    private func cg(_ point: UsageChartMath.Point) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }
}
