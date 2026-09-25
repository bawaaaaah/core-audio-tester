enum LatencyStats {
    struct Summary {
        let mean: Double
        let median: Double
        let min: Double
        let max: Double
        let stddev: Double
        let outliers: Int
    }

    static func summarize(_ values: [Double]) -> Summary {
        guard !values.isEmpty else { return Summary(mean: 0, median: 0, min: 0, max: 0, stddev: 0, outliers: 0) }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        let median = middle(of: sorted)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let stddev = variance.squareRoot()

        let mad = middle(of: values.map { abs($0 - median) }.sorted())
        let outliers = mad > 0 ? values.filter { abs($0 - median) > 5 * mad }.count : 0

        return Summary(mean: mean, median: median, min: sorted[0], max: sorted[sorted.count - 1], stddev: stddev, outliers: outliers)
    }

    /// Median of an already-sorted, non-empty array (mean of the two middle values when even).
    private static func middle(of sorted: [Double]) -> Double {
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
