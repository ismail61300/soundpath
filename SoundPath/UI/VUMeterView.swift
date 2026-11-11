import SwiftUI

/// Stereo horizontal VU meter (RMS bar + peak-hold tick), drawn with a single Canvas.
struct VUMeterView: View {
    let meter: MeterState

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 2
            let barHeight = (size.height - gap) / 2
            drawBar(context, y: 0, width: size.width, height: barHeight,
                    level: CGFloat(meter.left), peak: CGFloat(meter.peakLeft))
            drawBar(context, y: barHeight + gap, width: size.width, height: barHeight,
                    level: CGFloat(meter.right), peak: CGFloat(meter.peakRight))
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }

    private static let gradient = Gradient(stops: [
        .init(color: .green, location: 0),
        .init(color: .green, location: 0.6),
        .init(color: .yellow, location: 0.85),
        .init(color: .red, location: 1),
    ])

    private func drawBar(_ context: GraphicsContext, y: CGFloat, width: CGFloat, height: CGFloat,
                         level: CGFloat, peak: CGFloat) {
        let track = Path(roundedRect: CGRect(x: 0, y: y, width: width, height: height), cornerRadius: height / 2)
        context.fill(track, with: .color(.primary.opacity(0.08)))
        if level > 0 {
            let rect = CGRect(x: 0, y: y, width: max(height, width * level), height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: height / 2),
                         with: .linearGradient(Self.gradient, startPoint: CGPoint(x: 0, y: y),
                                               endPoint: CGPoint(x: width, y: y)))
        }
        if peak > 0.01 {
            let x = min(width - 2, width * peak)
            context.fill(Path(CGRect(x: x, y: y, width: 2, height: height)),
                         with: .color(peak > 0.95 ? .red : .primary.opacity(0.6)))
        }
    }
}
