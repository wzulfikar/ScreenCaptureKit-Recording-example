//
//  ScreenCaptureKit-Recording-example
//
//  Created by Tom Lokhorst on 2023-01-18.
//

import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import VideoToolbox
import AudioToolbox

enum RecordMode {
    case h264_sRGB
    case hevc_displayP3

    // I haven't gotten HDR recording working yet.
    // The commented out code is my best attempt, but still results in "blown out whites".
    //
    // Any tips are welcome!
    // - Tom
//    case hevc_displayP3_HDR
}

// Create a screen recording
do {
    // Check for screen recording permission, make sure your terminal has screen recording permission
    guard CGPreflightScreenCaptureAccess() else {
        throw RecordingError("No screen capture permission")
    }

    let url = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "recording \(Date()).mov")
//    let cropRect = CGRect(x: 0, y: 0, width: 960, height: 540)
    let screenRecorder = try await ScreenRecorder(url: url, displayID: CGMainDisplayID(), cropRect: nil, mode: .h264_sRGB)

    print("Starting screen recording of main display")
    try await screenRecorder.start()

    print("Hit Return to end recording")
    _ = readLine()
    try await screenRecorder.stop()

    print("Recording ended, opening video")
    NSWorkspace.shared.open(url)
} catch {
    print("Error during recording:", error)
}



struct ScreenRecorder {
    private let videoSampleBufferQueue = DispatchQueue(label: "ScreenRecorder.VideoSampleBufferQueue")

    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput // system audio
    private var micInput: AVAssetWriterInput? // separate mic track (mono)
    private let streamOutput: StreamOutput
    private var stream: SCStream

    init(url: URL, displayID: CGDirectDisplayID, cropRect: CGRect?, mode: RecordMode) async throws {

        // Create AVAssetWriter for a QuickTime movie file
        self.assetWriter = try AVAssetWriter(url: url, fileType: .mov)

        // MARK: AVAssetWriter setup

        // Get size and pixel scale factor for display
        // Used to compute the highest possible qualitiy
        let displaySize = CGDisplayBounds(displayID).size

        // The number of physical pixels that represent a logic point on screen, currently 2 for MacBook Pro retina displays
        let displayScaleFactor: Int
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            displayScaleFactor = mode.pixelWidth / mode.width
        } else {
            displayScaleFactor = 1
        }

        // AVAssetWriterInput supports maximum resolution of 4096x2304 for H.264
        // Downsize to fit a larger display back into in 4K
        let videoSize = downsizedVideoSize(source: cropRect?.size ?? displaySize, scaleFactor: displayScaleFactor, mode: mode)

        // Use the preset as large as possible, size will be reduced to screen size by computed videoSize
        guard let assistant = AVOutputSettingsAssistant(preset: mode.preset) else {
            throw RecordingError("Can't create AVOutputSettingsAssistant")
        }
        assistant.sourceVideoFormat = try CMVideoFormatDescription(videoCodecType: mode.videoCodecType, width: videoSize.width, height: videoSize.height)

        guard var outputSettings = assistant.videoSettings else {
            throw RecordingError("AVOutputSettingsAssistant has no videoSettings")
        }
        outputSettings[AVVideoWidthKey] = videoSize.width
        outputSettings[AVVideoHeightKey] = videoSize.height

        // Configure video color properties and compression properties based on RecordMode
        // See AVVideoSettings.h and VTCompressionProperties.h
        outputSettings[AVVideoColorPropertiesKey] = mode.videoColorProperties
        if let videoProfileLevel = mode.videoProfileLevel {
            var compressionProperties: [String: Any] = outputSettings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
            compressionProperties[AVVideoProfileLevelKey] = videoProfileLevel
            outputSettings[AVVideoCompressionPropertiesKey] = compressionProperties as NSDictionary
        }

        // Create AVAssetWriter input for video, based on the output settings from the Assistant
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        videoInput.expectsMediaDataInRealTime = true

        // Create AVAssetWriter input for system audio (encode to AAC)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 192_000
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        // Create optional microphone track using same AAC settings (will be mono if mic supplies 1 ch)
        if #available(macOS 15.0, *) {
            // Use mono AAC for microphone track
            let micSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVNumberOfChannelsKey: 1,  // mono for mic
                AVSampleRateKey: 48000,  // match actual mic sample rate
                AVEncoderBitRateKey: 96_000  // lower bitrate for mono
            ]
            let micWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            micWriterInput.expectsMediaDataInRealTime = true
            self.micInput = micWriterInput
        }

        streamOutput = StreamOutput(assetWriter: assetWriter, videoInput: videoInput, audioInput: audioInput, micInput: micInput)

        // Adding inputs to assetWriter
        guard assetWriter.canAdd(videoInput) else {
            throw RecordingError("Can't add video input to asset writer")
        }
        assetWriter.add(videoInput)

        guard assetWriter.canAdd(audioInput) else {
            throw RecordingError("Can't add audio input to asset writer")
        }
        assetWriter.add(audioInput)

        if let micInput = micInput {
            if assetWriter.canAdd(micInput) { assetWriter.add(micInput) }
        }

        guard assetWriter.startWriting() else {
            if let error = assetWriter.error {
                throw error
            }
            throw RecordingError("Couldn't start writing to AVAssetWriter")
        }

        // MARK: SCStream setup

        // Create a filter for the specified display
        let sharableContent = try await SCShareableContent.current
        guard let display = sharableContent.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError("Can't find display with ID \(displayID) in sharable content")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let configuration = SCStreamConfiguration()

        // Increase the depth of the frame queue to ensure high fps at the expense of increasing
        // the memory footprint of WindowServer.
        configuration.queueDepth = 6 // 4 minimum, or it becomes very stuttery
        configuration.showsCursor = true
        configuration.capturesAudio = true  // system audio

#if compiler(>=5.10)
#endif
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        // Make sure to take displayScaleFactor into account
        // otherwise, image is scaled up and gets blurry
        if let cropRect = cropRect {
            // ScreenCaptureKit uses top-left of screen as origin
            configuration.sourceRect = cropRect
            configuration.width = Int(cropRect.width) * displayScaleFactor
            configuration.height = Int(cropRect.height) * displayScaleFactor
        } else {
            configuration.width = Int(displaySize.width) * displayScaleFactor
            configuration.height = Int(displaySize.height) * displayScaleFactor
        }

        // Set pixel format an color space, see CVPixelBuffer.h
        switch mode {
        case .h264_sRGB:
            configuration.pixelFormat = kCVPixelFormatType_32BGRA // 'BGRA'
            configuration.colorSpaceName = CGColorSpace.sRGB
        case .hevc_displayP3:
            configuration.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked // 'l10r'
            configuration.colorSpaceName = CGColorSpace.displayP3
//        case .hevc_displayP3_HDR:
//            configuration.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked // 'l10r'
//            configuration.colorSpaceName = CGColorSpace.displayP3
        }

        // Create SCStream and add local StreamOutput object to receive samples
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: videoSampleBufferQueue)
        try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: videoSampleBufferQueue)
        if micInput != nil {
            if #available(macOS 15.0, *) {
                try stream.addStreamOutput(streamOutput, type: .microphone, sampleHandlerQueue: videoSampleBufferQueue)
            }
        }
    }

    func start() async throws {
        // Start capturing, wait for stream to start
        try await stream.startCapture()

        // Defer startSession until first sample buffer arrives for zero-copy path
        streamOutput.sessionStarted = true
    }

    func stop() async throws {
        // Stop capturing, wait for stream to stop
        try await stream.stopCapture()

        // End the AVAssetWriter session at last received sample
        assetWriter.endSession(atSourceTime: streamOutput.lastPresentationTime)

        // Finish writing
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        if let micInput = micInput { micInput.markAsFinished() }
        await assetWriter.finishWriting()
    }

    private class StreamOutput: NSObject, SCStreamOutput {
        let assetWriter: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput // system audio
        let micInput: AVAssetWriterInput?  // mic track
        var sessionStarted = false
        private var baseTime: CMTime?
        var lastPresentationTime: CMTime = .zero

        init(assetWriter: AVAssetWriter, videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput, micInput: AVAssetWriterInput?) {
            self.assetWriter = assetWriter
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.micInput = micInput
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            // Return early if session hasn't started yet
            guard sessionStarted else { return }

            // Return early if the sample buffer is invalid
            guard sampleBuffer.isValid else { return }

            // Helper to create retimed buffer
            func append(_ sb: CMSampleBuffer, to input: AVAssetWriterInput) {
                guard input.isReadyForMoreMediaData else { return }
                guard let base = baseTime else { return }
                let newPTS = sb.presentationTimeStamp - base
                var timing = CMSampleTimingInfo(duration: sb.duration,
                                                presentationTimeStamp: newPTS,
                                                decodeTimeStamp: sb.decodeTimeStamp)
                if let retimed = try? CMSampleBuffer(copying: sb, withNewTiming: [timing]) {
                    input.append(retimed)
                    lastPresentationTime = newPTS
                }
            }

            switch type {
            case .screen:
                // Validate that frame is complete to avoid tears
                guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                      let attachments = attachmentsArray.first,
                      let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                      let status = SCFrameStatus(rawValue: statusRawValue),
                      status == .complete
                else { return }

                // Start writer session on first complete video frame
                if baseTime == nil {
                    baseTime = sampleBuffer.presentationTimeStamp
                    assetWriter.startSession(atSourceTime: .zero)
                }

                append(sampleBuffer, to: videoInput)

            case .audio:
                // Only process audio if video session has started
                guard baseTime != nil else { return }
                append(sampleBuffer, to: audioInput)

            case .microphone where baseTime != nil:
                // Handle microphone samples on macOS 15+ (only after video started)
                if #available(macOS 15.0, *), let mic = micInput {
                    append(sampleBuffer, to: mic)
                }

            @unknown default:
                break
            }
        }
    }
}


// AVAssetWriterInput supports maximum resolution of 4096x2304 for H.264
private func downsizedVideoSize(source: CGSize, scaleFactor: Int, mode: RecordMode) -> (width: Int, height: Int) {
    let maxSize = mode.maxSize

    let w = source.width * Double(scaleFactor)
    let h = source.height * Double(scaleFactor)
    let r = max(w / maxSize.width, h / maxSize.height)

    return r > 1
        ? (width: Int(w / r), height: Int(h / r))
        : (width: Int(w), height: Int(h))
}

struct RecordingError: Error, CustomDebugStringConvertible {
    var debugDescription: String
    init(_ debugDescription: String) { self.debugDescription = debugDescription }
}

// Extension properties for values that differ per record mode
extension RecordMode {
    var preset: AVOutputSettingsPreset {
        switch self {
        case .h264_sRGB: return .preset3840x2160
        case .hevc_displayP3: return .hevc7680x4320
//        case .hevc_displayP3_HDR: return .hevc7680x4320
        }
    }

    var maxSize: CGSize {
        switch self {
        case .h264_sRGB: return CGSize(width: 4096, height: 2304)
        case .hevc_displayP3: return CGSize(width: 7680, height: 4320)
//        case .hevc_displayP3_HDR: return CGSize(width: 7680, height: 4320)
        }
    }

    var videoCodecType: CMFormatDescription.MediaSubType {
        switch self {
        case .h264_sRGB: return .h264
        case .hevc_displayP3: return .hevc
//        case .hevc_displayP3_HDR: return .hevc
        }
    }

    var videoColorProperties: NSDictionary {
        switch self {
        case .h264_sRGB:
            return [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        case .hevc_displayP3:
            return [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
//        case .hevc_displayP3_HDR:
//            return [
//                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
//                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
//                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
//            ]
        }
    }

    var videoProfileLevel: CFString? {
        switch self {
        case .h264_sRGB:
            return nil
        case .hevc_displayP3:
            return nil
//        case .hevc_displayP3_HDR:
//            return kVTProfileLevel_HEVC_Main10_AutoLevel
        }
    }
}
