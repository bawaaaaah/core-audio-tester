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
        let median = sorted[sorted.count / 2]
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let stddev = variance.squareRoot()

        let deviations = values.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        let outliers = mad > 0 ? values.filter { abs($0 - median) > 5 * mad }.count : 0

        return Summary(mean: mean, median: median, min: sorted.first!, max: sorted.last!, stddev: stddev, outliers: outliers)
    }
}
