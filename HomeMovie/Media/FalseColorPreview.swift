import AVFoundation
import CoreImage

/// Display-only Apple Log exposure map. Never pass this output to a movie writer.
/// Stops are relative to 18% gray; the high/low zones are exposure guides, not
/// calibrated sensor saturation or noise-floor measurements.
enum FalseColorPreview {
    static let preferenceKey = "falseColorPreview"
    private static let kernel: Result<CIColorKernel, Error> = Result {
        guard let url = Bundle.main.url(forResource: "FilmEffects", withExtension: "metallib") else {
            throw HomeMovieError.message("False Color could not load. Recording is unaffected.")
        }
        return try CIColorKernel(functionName: "logFalseColor", fromMetalLibraryData: Data(contentsOf: url))
    }
    static func apply(to image: CIImage) throws -> CIImage {
        let arguments: [Any] = [image] + FalseColorZone.allCases.map { $0.kernelValue as Any }
        guard let output = try kernel.get().apply(extent: image.extent, arguments: arguments) else {
            throw HomeMovieError.message("False Color preview is unavailable. Recording is unaffected.")
        }
        return output
    }
    static func image(_ buffer: CVPixelBuffer) throws -> CIImage {
        // Reject unverified SDR/HLG frames, including during camera handoffs.
        guard LogPiPColor.isLog(buffer) else {
            throw HomeMovieError.message("False Color requires verified Apple Log frames.")
        }
        // Core Image expands the pixel format's video/full range and YCbCr matrix.
        // Disable color management so the Apple Log code values reach the kernel intact.
        return try apply(to: CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]))
    }
    static func image(background: CVPixelBuffer, presenter: CVPixelBuffer?, canvas: CGSize,
                      backgroundAngle: CGFloat, presenterAngle: CGFloat,
                      presentation: PiPPresentation) throws -> CIImage {
        let rear = try image(background)
        let visiblePresenter = presentation.opacity > 0 && presentation.isPlaceable && !presentation.rect.isEmpty
        let front = try (visiblePresenter ? presenter : nil).map { try image($0) }
        return PiPCompositor.image(background: rear, presenter: front, canvas: canvas,
            backgroundAngle: backgroundAngle, presenterAngle: presenterAngle, presentation: presentation)
    }
}


// Keep existing preference keys while exposing exactly one viewfinder choice.
// False Color wins when reading older settings that enabled both switches.
enum CameraPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case look, log, falseColor
    static let originalLogPreferenceKey = "originalLogPreview"
    var id: String { rawValue }
    var title: String {
        switch self { case .look: "With Look"; case .log: "Log"; case .falseColor: "False Color" }
    }
    var explanation: String {
        switch self {
        case .look: "Shows the selected movie look."
        case .log: "Shows the flat, original Log image."
        case .falseColor: "Shows exposure colors instead of the movie look."
        }
    }
    var usesOriginalLog: Bool { self == .log }
    var usesFalseColor: Bool { self == .falseColor }
    init(originalLog: Bool, falseColor: Bool) {
        self = falseColor ? .falseColor : originalLog ? .log : .look
    }
    static func read(from defaults: UserDefaults = .standard) -> Self {
        Self(originalLog: defaults.bool(forKey: originalLogPreferenceKey),
             falseColor: defaults.bool(forKey: FalseColorPreview.preferenceKey))
    }
    func store(in defaults: UserDefaults = .standard) {
        defaults.set(usesOriginalLog, forKey: Self.originalLogPreferenceKey)
        defaults.set(usesFalseColor, forKey: FalseColorPreview.preferenceKey)
    }
}


// These exact RGB values and stop thresholds feed both the Metal map and UI key.
// Fixed relative exposure zones are not calibrated sensor clipping/noise limits.
enum FalseColorZone: Int, CaseIterable, Identifiable, Sendable {
    case purple, blue, middleGray, pink, orange, red
    var id: Int { rawValue }
    static let grayHalfWidth = 0.15
    var rgb: SIMD3<Float> {
        switch self {
        case .purple: SIMD3(0.55, 0, 0.85)
        case .blue: SIMD3(0, 0.25, 1)
        case .middleGray: SIMD3(0.1, 0.8, 0.2)
        case .pink: SIMD3(1, 0.45, 0.65)
        case .orange: SIMD3(1, 0.65, 0)
        case .red: SIMD3(1, 0.08, 0.03)
        }
    }
    // Purple/blue use upper bounds, orange/red use lower bounds;
    // green carries the reference half-width and pink its +1-stop center.
    var boundary: Double {
        switch self { case .purple: -6; case .blue: -4; case .middleGray: Self.grayHalfWidth
        case .pink: 1; case .orange: 3; case .red: 4 }
    }
    var kernelValue: CIVector {
        CIVector(x: CGFloat(rgb.x), y: CGFloat(rgb.y), z: CGFloat(rgb.z), w: CGFloat(boundary))
    }
    var colorName: String {
        switch self { case .purple: "Purple"; case .blue: "Blue"; case .middleGray: "Green"
        case .pink: "Pink"; case .orange: "Orange"; case .red: "Red" }
    }
    var title: String {
        switch self { case .purple: "Very Low"; case .blue: "Low"; case .middleGray: "18% Middle Gray"
        case .pink: "One Stop Above Gray"; case .orange: "High"; case .red: "Very High" }
    }
    var rangeLabel: String {
        switch self {
        case .purple: "Below −6 stops"
        case .blue: "−6 to below −4 stops"
        case .middleGray: "−0.15 to +0.15 stops"
        case .pink: "+0.85 to +1.15 stops"
        case .orange: "+3 to below +4 stops"
        case .red: "+4 stops and above"
        }
    }
}
