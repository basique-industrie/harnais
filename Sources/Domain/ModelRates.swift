import Foundation

public struct ModelPrice: Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public func cost(uncached: Double, cached: Double, cacheWrite write: Double, output tokens: Double) -> (cost: Double, cacheSavings: Double) {
        let cost = uncached * input + cached * cacheRead + write * self.cacheWrite + tokens * output
        let savings = max(0, cached * (input - cacheRead))
        return (cost, savings)
    }
}

public struct ModelRates: Sendable, Equatable {
    public var prices: [String: ModelPrice]

    public static let pricedAsOf = "Sep 2026"

    public static let standard = ModelRates(
        prices: [
            "claude-opus-5": ModelPrice(input: 5e-6, output: 2.5e-5, cacheRead: 5e-7, cacheWrite: 6.25e-6),
            "claude-fable-5": ModelPrice(input: 1e-5, output: 5e-5, cacheRead: 1e-6, cacheWrite: 1.25e-5),
            "claude-fable-5-1": ModelPrice(input: 1e-5, output: 5e-5, cacheRead: 2.5e-7, cacheWrite: 1.25e-5),
            "claude-sonnet-4-6": ModelPrice(input: 3e-6, output: 1.5e-5, cacheRead: 3e-7, cacheWrite: 3.75e-6),
            "gpt-6-astra": ModelPrice(input: 1e-5, output: 5e-5, cacheRead: 1e-6, cacheWrite: 1.25e-5),
            "gpt-5.6-sol": ModelPrice(input: 4e-6, output: 2e-5, cacheRead: 4e-7, cacheWrite: 5e-6),
        ]
    )

    public init(prices: [String: ModelPrice]) {
        self.prices = prices
    }

    public func price(for model: String) -> ModelPrice {
        let key = Self.normalize(model)
        if let exact = prices[key] { return exact }
        if let match = prices.first(where: { key.hasPrefix($0.key) || key.contains($0.key) }) {
            return match.value
        }
        return ModelPrice(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
    }

    public func price(_ event: UsageEvent) -> (cost: Double, cacheSavings: Double) {
        if let reported = event.reportedCost {
            return (reported, 0)
        }
        return price(for: event.model).cost(
            uncached: event.uncachedInput,
            cached: event.cachedInput,
            cacheWrite: event.cacheWrite,
            output: event.output
        )
    }

    public static func normalize(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}
