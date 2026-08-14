import AppKit
import SwiftUI

/// The menu bar status item icon: the VoxBox V-wave monogram, drawn as a
/// template image so it adapts to the menu bar's light/dark appearance and
/// tinting like a native icon.
///
/// While a recording is in progress the bars step through a small equalizer
/// animation (frames cycled by a TimelineView, which re-renders the status
/// item), then settle back into the resting V shape.
struct MenuBarIconView: View {
    @ObservedObject private var audioRecorder = AudioRecordingService.shared

    /// Resting bar heights — the V of VoxBox (fractions of full height).
    private static let idleHeights: [CGFloat] = [0.42, 0.68, 1.0, 0.68, 0.42]

    /// Equalizer frames cycled while recording. Each keeps a rough V
    /// silhouette so the mark stays recognizable mid-animation.
    private static let recordingFrames: [[CGFloat]] = [
        [0.42, 0.68, 1.00, 0.68, 0.42],
        [0.55, 0.85, 0.80, 0.90, 0.50],
        [0.35, 0.60, 1.00, 0.55, 0.65],
        [0.60, 0.75, 0.90, 0.80, 0.40],
        [0.45, 0.95, 0.70, 0.65, 0.55],
        [0.38, 0.70, 1.00, 0.85, 0.48],
    ]

    /// Pre-rendered template images. Rendered once — the TimelineView only
    /// swaps images. `idleImage` is also reused by the menu bar dashboard
    /// header so the mark matches everywhere.
    static let idleImage = renderFrame(heights: idleHeights)
    private static let recordingImages = recordingFrames.map { renderFrame(heights: $0) }

    var body: some View {
        if audioRecorder.isRecording {
            TimelineView(.periodic(from: .now, by: 0.22)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.22)
                Image(nsImage: Self.recordingImages[tick % Self.recordingImages.count])
            }
        } else {
            Image(nsImage: Self.idleImage)
        }
    }

    /// Draw the five V-wave capsules into an 18×18pt template NSImage
    /// (the standard menu bar icon size; AppKit rasterizes at the right scale).
    private static func renderFrame(heights: [CGFloat]) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let barWidth: CGFloat = 2.4
        let spacing: CGFloat = 0.9
        let maxBarHeight: CGFloat = 14
        let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
        let startX = (size.width - totalWidth) / 2

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for (index, fraction) in heights.enumerated() {
                let barHeight = max(barWidth, maxBarHeight * fraction)
                let x = startX + CGFloat(index) * (barWidth + spacing)
                // Bars hang from a common top edge, mirroring the app icon.
                let y = size.height - 2 - barHeight
                let rect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
                NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                    .fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
