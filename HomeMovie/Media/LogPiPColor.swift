import AVFoundation
import CoreImage
import VideoToolbox
import Darwin

// Apple Log code values stay ungraded through spatial composition. The selected
// viewing LUT is applied only after composition for preview, playback and export.
enum LogPiPColor {
    static let pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    static func isTenBit(_ buffer: CVPixelBuffer) -> Bool {
        [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange].contains(CVPixelBufferGetPixelFormatType(buffer))
    }
    static func isLog(_ buffer: CVPixelBuffer) -> Bool {
        guard isTenBit(buffer), let value = CVBufferCopyAttachment(buffer, kCVImageBufferLogTransferFunctionKey, nil) else { return false }
        return (value as? String) == (kCVImageBufferLogTransferFunction_AppleLog as String)
    }
    static func verifyCapture(_ sample: CMSampleBuffer) -> Bool {
        guard let buffer = CMSampleBufferGetImageBuffer(sample), isTenBit(buffer) else { return false }
        if isLog(buffer) { return true }
        guard let format = CMSampleBufferGetFormatDescription(sample),
              (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_LogTransferFunction) as? String) ==
                (kCMFormatDescriptionLogTransferFunction_AppleLog as String) else { return false }
        attach(to: buffer)
        return true
    }
    static func attach(to buffer: CVPixelBuffer) {
        CVBufferRemoveAttachment(buffer, kCVImageBufferTransferFunctionKey)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferLogTransferFunctionKey, kCVImageBufferLogTransferFunction_AppleLog, .shouldPropagate)
    }
    static func contextOptions() -> [CIContextOption: Any] {
        [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAh.rawValue, .cacheIntermediates: false]
    }
    static func sourceHint(canvas: CGSize) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries as String: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_YCbCrMatrix as String: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            kCMFormatDescriptionExtension_LogTransferFunction as String: kCMFormatDescriptionLogTransferFunction_AppleLog]
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: pixelFormat,
            width: Int32(canvas.width), height: Int32(canvas.height), extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw HomeMovieError.message("The 10-bit Log recording format could not be created.") }
        return description
    }
    static func encodedTenBit(_ description: CMFormatDescription) -> Bool {
        guard CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC,
              let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let configuration = atoms["hvcC"] as? Data, configuration.count >= 23 else { return false }
        // HEVCDecoderConfigurationRecord carries the actual encoded component depths.
        return configuration[17] & 7 >= 2 && configuration[18] & 7 >= 2
    }
    // These documented AVFoundation constants were added in iOS 27. Resolve
    // their public symbols at runtime so an Xcode 26 build still runs on older OSes.
    // No guessed dictionary keys or private symbols are used.
    static let writerLogProperty: (key: String, value: String)? = {
        guard #available(iOS 27.0, *), let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let key = dlsym(handle, "AVVideoLogTransferFunctionKey"),
              let value = dlsym(handle, "AVVideoLogTransferFunction_AppleLog") else { return nil }
        return (key.assumingMemoryBound(to: CFString.self).pointee as String,
                value.assumingMemoryBound(to: CFString.self).pointee as String)
    }()
    static func videoSettings(canvas: CGSize) -> [String: Any] {
        var color: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                   AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        if let property = writerLogProperty { color[property.key] = property.value }
        return [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(canvas.width), AVVideoHeightKey: Int(canvas.height),
         AVVideoColorPropertiesKey: color,
         AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            AVVideoAverageBitRateKey: 28_000_000, AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 30]]
    }
}
