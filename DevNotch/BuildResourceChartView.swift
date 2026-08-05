import SwiftUI
import Charts

struct BuildResourceChartView: View {
    let samples: [BuildResourceSample]

    private var visibleSamples: [BuildResourceSample] {
        guard let latestTimestamp = samples.last?.timestamp else { return samples }
        let cutoff = latestTimestamp.addingTimeInterval(-20)
        return samples.filter { $0.timestamp >= cutoff }
    }

    private var yAxisMax: Double {
        let peak = visibleSamples.map(\.totalCPUPercent).max() ?? 0
        return max(peak * 1.3, 10)
    }

    var body: some View {
        Chart(visibleSamples) { sample in
            LineMark(
                x: .value("Time", sample.timestamp),
                y: .value("CPU %", sample.totalCPUPercent)
            )
        }
        .chartYScale(domain: 0...yAxisMax)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
    }
}
