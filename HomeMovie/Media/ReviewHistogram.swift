import Foundation
import CoreVideo

struct ReviewHistogram: Equatable, Sendable {
    let bins: [Int]
    let samples: Int
    let blackSamples: Int
    let whiteSamples: Int
    var blackFraction: Double { samples == 0 ? 0 : Double(blackSamples) / Double(samples) }
    var whiteFraction: Double { samples == 0 ? 0 : Double(whiteSamples) / Double(samples) }
    // This is a bounded spatial sample of the rendered SDR frame, not a claim
    // that original camera data at the displayed limits is unrecoverable.
    static func measure(_ buffer: CVPixelBuffer) -> ReviewHistogram? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let dx = max(1, width / 192), dy = max(1, height / 108)
        var bins = Array(repeating: 0, count: 64)
        var count = 0, black = 0, white = 0
        for y in stride(from: dy / 2, to: height, by: dy) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: dx / 2, to: width, by: dx) {
                let p = row.advanced(by: x * 4)
                guard p[3] >= 128 else { continue }
                let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                let luma = (2126 * r + 7152 * g + 722 * b) / 10000
                bins[min(63, luma * 64 / 256)] += 1; count += 1
                if max(r, max(g, b)) <= 1 { black += 1 }
                if max(r, max(g, b)) >= 254 { white += 1 }
            }
        }
        return ReviewHistogram(bins: bins, samples: count, blackSamples: black, whiteSamples: white)
    }
}

// CVPixelBuffer is retained immutably until this one off-main analysis finishes.
final class HistogramFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}
actor ReviewHistogramAnalyzer {
    func measure(_ frame: HistogramFrame) -> ReviewHistogram? { ReviewHistogram.measure(frame.buffer) }
}
