import SwiftUI

struct WaveformView: View {
    let url: URL
    var durationSeconds: UInt64 = 0
    var barCount: Int = 96

    @State private var peaks: [Float] = []
    @State private var display: [Float] = Self.idleWave

    private static let idleWave: [Float] = (0..<96).map { index in
        0.12 + 0.06 * abs(sin(Float(index) / 7.5))
    }

    var body: some View {
        Canvas { context, size in
            let values = display
            guard values.count > 1, size.width > 1, size.height > 1 else { return }

            let midY = size.height / 2
            let amplitude = size.height * 0.42
            let step = size.width / CGFloat(values.count - 1)

            var upper = Path()
            var lower = Path()
            upper.move(to: CGPoint(x: 0, y: midY))
            lower.move(to: CGPoint(x: 0, y: midY))

            for index in values.indices {
                let x = CGFloat(index) * step
                let rise = CGFloat(values[index]) * amplitude
                upper.addLine(to: CGPoint(x: x, y: midY - rise))
                lower.addLine(to: CGPoint(x: x, y: midY + rise))
            }

            upper.addLine(to: CGPoint(x: size.width, y: midY))
            upper.closeSubpath()
            lower.addLine(to: CGPoint(x: size.width, y: midY))
            lower.closeSubpath()

            let fill = Color.primary.opacity(peaks.isEmpty ? 0.06 : 0.10)
            let stroke = Color.primary.opacity(peaks.isEmpty ? 0.16 : 0.28)

            context.fill(upper, with: .color(fill))
            context.fill(lower, with: .color(fill))
            context.stroke(upper, with: .color(stroke), lineWidth: 0.75)
            context.stroke(lower, with: .color(stroke), lineWidth: 0.75)

            var midline = Path()
            midline.move(to: CGPoint(x: 0, y: midY))
            midline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(midline, with: .color(.primary.opacity(0.08)), lineWidth: 0.5)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .allowsHitTesting(false)
        .task(id: "\(url.path)-\(durationSeconds)") {
            let url = url
            let barCount = barCount
            let next = await Task.detached(priority: .utility) {
                WaveformCache.peaks(for: url, barCount: barCount)
            }.value
            peaks = next
            display = smooth(next.isEmpty ? Self.idleWave : next)
        }
    }

    private func smooth(_ source: [Float]) -> [Float] {
        guard source.count > 2 else { return source }
        return source.indices.map { index in
            let previous = source[max(0, index - 1)]
            let current = source[index]
            let next = source[min(source.count - 1, index + 1)]
            return (previous + current * 2 + next) / 4
        }
    }
}

struct MicMeterView: View {
    var level: Float
    var color: Color = .red

    private let weights: [CGFloat] = [0.35, 0.7, 1, 0.7, 0.35]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.15 + Double(level) * 0.75))
                    .frame(width: 3.5, height: barHeight(index))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let talking = CGFloat(min(1, max(0, level)))
        let idle: CGFloat = 4
        let span: CGFloat = 18
        return idle + span * talking * weights[index]
    }
}

private enum WaveformCache {
    private static let lock = NSLock()
    private static var storage: [String: [Float]] = [:]

    static func peaks(for url: URL, barCount: Int) -> [Float] {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = "\(url.path):\(barCount):\(stamp)"
        lock.lock()
        if let cached = storage[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let peaks = WavIO.waveformPeaks(at: url, barCount: barCount)
        lock.lock()
        storage[key] = peaks
        lock.unlock()
        return peaks
    }
}
