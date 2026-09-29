import Domain
import SwiftUI

/// Shared visual vocabulary for every connection, including tools without a brand asset.
struct ConnectionMark: View {
    let name: String
    var size: CGFloat = 30

    private var kind: IntegrationKind? {
        IntegrationKind.allCases.first { $0 != .custom && InventoryEntry.serviceName(name) == $0.rawValue }
    }

    private var symbol: String {
        let name = name.lowercased()
        if name.contains("spreadsheet") { return "tablecells" }
        if name.contains("presentation") { return "rectangle.stack" }
        if name.contains("document") || name.contains("pdf") { return "doc.text" }
        if name.contains("browser") || name.contains("chrome") { return "globe" }
        if name.contains("computer") { return "cursorarrow.rays" }
        if name.contains("security") { return "shield" }
        if name.contains("design") || name.contains("excalidraw") { return "paintbrush.pointed" }
        if name.contains("lsp") || name.contains("repl") { return "terminal" }
        if name.contains("visual") { return "chart.bar" }
        if name.contains("template") { return "square.grid.2x2" }
        return "puzzlepiece.extension"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(HarnaisPalette.muted)
            if let kind {
                IntegrationMark(kind: kind, size: size * 0.64)
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(HarnaisPalette.accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ConnectionCatalogRow: View {
    let item: CatalogConnection
    var onManage: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ConnectionMark(name: item.name, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).font(HarnaisType.rowTitle).foregroundStyle(HarnaisPalette.text)
                HStack(spacing: 6) {
                    ForEach(item.providers) { provider in ProviderMark(provider: provider, size: 12) }
                    Text("\(item.providerLabel) · \(item.categoryLabel) · \(item.accountCount) account\(item.accountCount == 1 ? "" : "s")")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                }
            }
            if item.origin == .builtIn && item.occurrences.contains(where: { $0.entry.origin == .added }) {
                Text("Also added").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            }
            Spacer(minLength: 8)
            if item.warningCount > 0 {
                Label("Needs attention", systemImage: "exclamationmark.triangle")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.warning)
            }
            if item.warningCount == 0 {
                Text(item.activationSummary).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            }
            HarnaisButton(title: "Manage", prominence: .ghostMuted, action: onManage)
                .accessibilityLabel("Manage \(item.displayName)")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
