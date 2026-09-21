import Foundation
import AVFoundation
import CoreMedia

enum CompressionError: LocalizedError {
    case noVideo
    case unsupportedPreset
    case unsupportedContainer
    case exportFailed(String)
    case remuxFailed(String)
    case invalidOutput
    case durationMismatch(source: Double, output: Double)
    case frameRateMismatch(source: Float, output: Float)
    case audioTrackMismatch(source: Int, output: Int)
    case audioChannelMismatch(track: Int, source: Int, output: Int)
    case timecodeTrackMismatch(source: Int, output: Int)
    case notSmaller
    case replaceFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo:
            return "geen videotrack"
        case .unsupportedPreset:
            return "preset niet ondersteund"
        case .unsupportedContainer:
            return "container niet veilig vervangbaar"
        case .exportFailed(let message):
            return message
        case .remuxFailed(let message):
            return "FCP-remux mislukt: \(message)"
        case .invalidOutput:
            return "nieuwe video is ongeldig"
        case .durationMismatch(let source, let output):
            return String(
                format: "duur wijkt af: bron %.3fs, nieuw %.3fs",
                source,
                output
            )
        case .frameRateMismatch(let source, let output):
            return String(
                format: "framerate wijkt af: bron %.3f fps, nieuw %.3f fps",
                source,
                output
            )
        case .audioTrackMismatch(let source, let output):
            return "aantal audiotracks wijkt af: bron \(source), nieuw \(output)"
        case .audioChannelMismatch(let track, let source, let output):
            return "audiokanalen track \(track) wijken af: bron \(source), nieuw \(output)"
        case .timecodeTrackMismatch(let source, let output):
            return "timecode-track ontbreekt of wijkt af: bron \(source), nieuw \(output)"
        case .notSmaller:
            return "nieuwe video is niet kleiner"
        case .replaceFailed(let message):
            return message
        }
    }
}

private struct PassthroughPair {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    let label: String
}

final class MediaCompressor {
    private(set) var activeExport: AVAssetExportSession?

    func cancelCurrent() {
        activeExport?.cancelExport()
    }

    func compress(
        source: URL,
        preset: ArchivePreset,
        keepBackup: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let fm = FileManager.default
        let asset = AVURLAsset(url: source)

        let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !sourceVideoTracks.isEmpty else {
            throw CompressionError.noVideo
        }

        if preset == .extremeOriginalResolution &&
            source.pathExtension.lowercased() == "mov" {
            return try await compressExtremeMOV(
                source: source,
                keepBackup: keepBackup,
                onProgress: onProgress
            )
        }

        let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
        guard compatible.contains(preset.exportPresetName) else {
            throw CompressionError.unsupportedPreset
        }

        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: preset.exportPresetName
        ) else {
            throw CompressionError.unsupportedPreset
        }

        activeExport = export
        defer { activeExport = nil }

        let originalValues = try source.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let originalBytes = Int64(originalValues.fileSize ?? 0)

        let fileType = try chooseFileType(
            for: source,
            supported: export.supportedFileTypes
        )

        let encodedTemp = tempURL(for: source, marker: "VAC_ENCODE")
        let fcpTemp = tempURL(for: source, marker: "VAC_FCP")
        let backup = backupURL(for: source)

        try? fm.removeItem(at: encodedTemp)
        try? fm.removeItem(at: fcpTemp)

        export.outputURL = encodedTemp
        export.outputFileType = fileType
        export.shouldOptimizeForNetworkUse = false

        let progressTask = Task {
            while !Task.isCancelled {
                // Export is most of the work. Reserve the last 8% for the
                // QuickTime remux that restores original audio + timecode.
                onProgress(Double(export.progress) * 0.92)

                if export.status != .waiting && export.status != .exporting {
                    break
                }

                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        await withCheckedContinuation { continuation in
            export.exportAsynchronously {
                continuation.resume()
            }
        }

        progressTask.cancel()

        guard export.status == .completed else {
            try? fm.removeItem(at: encodedTemp)

            if export.status == .cancelled {
                throw CancellationError()
            }

            throw CompressionError.exportFailed(
                export.error?.localizedDescription ?? "export mislukt"
            )
        }

        var finalTemp = encodedTemp

        // Final Cut identifies professional camera media by more than just
        // filename + duration. MOV camera originals commonly contain a
        // dedicated QuickTime timecode track. AVAssetExportSession drops it.
        //
        // Rebuild the MOV using:
        // - the newly encoded HEVC video track
        // - ORIGINAL audio tracks unchanged (PCM stays PCM)
        // - ORIGINAL timecode track(s) unchanged
        //
        // This keeps the media range that FCP uses for relinking.
        if source.pathExtension.lowercased() == "mov" {
            onProgress(0.93)

            do {
                try await remuxMOVForFinalCut(
                    original: source,
                    encodedVideoFile: encodedTemp,
                    destination: fcpTemp
                )

                try? fm.removeItem(at: encodedTemp)
                finalTemp = fcpTemp
                onProgress(0.99)
            } catch {
                try? fm.removeItem(at: encodedTemp)
                try? fm.removeItem(at: fcpTemp)
                throw error
            }
        }

        let newBytes = Int64(
            (try finalTemp.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        )

        guard newBytes > 256_000 else {
            try? fm.removeItem(at: finalTemp)
            throw CompressionError.invalidOutput
        }

        guard originalBytes == 0 || newBytes < originalBytes else {
            try? fm.removeItem(at: finalTemp)
            throw CompressionError.notSmaller
        }

        do {
            try await verifyFinalCutCompatibility(
                source: source,
                output: finalTemp
            )
        } catch {
            try? fm.removeItem(at: finalTemp)
            throw error
        }

        // Never destroy an existing recovery backup automatically.
        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: finalTemp)
            throw CompressionError.replaceFailed(
                "er bestaat al een .VAC_ORIGINAL-backup voor dit bestand"
            )
        }

        do {
            try fm.moveItem(at: source, to: backup)

            do {
                try fm.moveItem(at: finalTemp, to: source)
            } catch {
                try? fm.moveItem(at: backup, to: source)
                try? fm.removeItem(at: finalTemp)

                throw CompressionError.replaceFailed(
                    error.localizedDescription
                )
            }

            if let modificationDate = originalValues.contentModificationDate {
                try? fm.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: source.path
                )
            }

            if !keepBackup {
                try? fm.removeItem(at: backup)
            }
        } catch let error as CompressionError {
            throw error
        } catch {
            try? fm.removeItem(at: finalTemp)

            throw CompressionError.replaceFailed(
                error.localizedDescription
            )
        }

        onProgress(1.0)
        return newBytes
    }

    private func compressExtremeMOV(
        source: URL,
        keepBackup: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let fm = FileManager.default
        let originalValues = try source.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let originalBytes = Int64(originalValues.fileSize ?? 0)

        let encodedTemp = tempURL(
            for: source,
            marker: "VAC_EXTREME_ENCODE"
        )
        let fcpTemp = tempURL(
            for: source,
            marker: "VAC_EXTREME_FCP"
        )
        let backup = backupURL(for: source)

        try? fm.removeItem(at: encodedTemp)
        try? fm.removeItem(at: fcpTemp)

        try await encodeExtremeHEVCVideo(
            source: source,
            destination: encodedTemp,
            onProgress: { value in
                onProgress(value * 0.92)
            }
        )

        onProgress(0.93)

        do {
            try await remuxMOVForFinalCut(
                original: source,
                encodedVideoFile: encodedTemp,
                destination: fcpTemp
            )
        } catch {
            try? fm.removeItem(at: encodedTemp)
            try? fm.removeItem(at: fcpTemp)
            throw error
        }

        try? fm.removeItem(at: encodedTemp)
        onProgress(0.98)

        let newBytes = Int64(
            (try fcpTemp.resourceValues(
                forKeys: [.fileSizeKey]
            )).fileSize ?? 0
        )

        guard newBytes > 256_000 else {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.invalidOutput
        }

        guard originalBytes == 0 || newBytes < originalBytes else {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.notSmaller
        }

        do {
            try await verifyFinalCutCompatibility(
                source: source,
                output: fcpTemp
            )
        } catch {
            try? fm.removeItem(at: fcpTemp)
            throw error
        }

        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.replaceFailed(
                "er bestaat al een .VAC_ORIGINAL-backup voor dit bestand"
            )
        }

        do {
            try fm.moveItem(at: source, to: backup)

            do {
                try fm.moveItem(at: fcpTemp, to: source)
            } catch {
                try? fm.moveItem(at: backup, to: source)
                try? fm.removeItem(at: fcpTemp)
                throw CompressionError.replaceFailed(
                    error.localizedDescription
                )
            }

            if let modificationDate = originalValues.contentModificationDate {
                try? fm.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: source.path
                )
            }

            if !keepBackup {
                try? fm.removeItem(at: backup)
            }
        } catch let error as CompressionError {
            throw error
        } catch {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.replaceFailed(
                error.localizedDescription
            )
        }

        onProgress(1.0)
        return newBytes
    }

    private func encodeExtremeHEVCVideo(
        source: URL,
        destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(
            withMediaType: .video
        )

        guard let track = videoTracks.first else {
            throw CompressionError.noVideo
        }

        let reader: AVAssetReader

        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CompressionError.exportFailed(
                error.localizedDescription
            )
        }

        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
        )

        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw CompressionError.exportFailed(
                "videotrack kan niet worden gelezen"
            )
        }

        reader.add(readerOutput)

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)

        let width = max(16, Int(abs(naturalSize.width).rounded()))
        let height = max(16, Int(abs(naturalSize.height).rounded()))
        let pixels = width * height

        // Aggressive archive bitrates. Resolution and frame timing stay intact.
        // The reader converts 10-bit originals to efficient 8-bit 4:2:0,
        // which is intentional for this archival use case.
        let bitrate: Int

        if pixels <= 1920 * 1080 {
            bitrate = fps > 30 ? 4_500_000 : 3_500_000
        } else if pixels <= 2560 * 1440 {
            bitrate = fps > 30 ? 6_500_000 : 5_000_000
        } else if pixels <= 3840 * 2160 {
            bitrate = fps > 30 ? 10_000_000 : 8_000_000
        } else {
            bitrate = fps > 30 ? 15_000_000 : 12_000_000
        }

        let writer: AVAssetWriter

        do {
            writer = try AVAssetWriter(
                outputURL: destination,
                fileType: .mov
            )
        } catch {
            throw CompressionError.exportFailed(
                error.localizedDescription
            )
        }

        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey:
                        max(1, Int(fps.rounded())),
                    AVVideoMaxKeyFrameIntervalKey:
                        max(30, Int(max(fps, 25) * 2))
                ]
            ]
        )

        writerInput.transform = transform
        writerInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(writerInput) else {
            throw CompressionError.exportFailed(
                "HEVC-writer ondersteunt deze videotrack niet"
            )
        }

        writer.add(writerInput)

        guard writer.startWriting() else {
            throw CompressionError.exportFailed(
                writer.error?.localizedDescription ??
                "HEVC-writer kon niet starten"
            )
        }

        guard reader.startReading() else {
            writer.cancelWriting()
            throw CompressionError.exportFailed(
                reader.error?.localizedDescription ??
                "videoreader kon niet starten"
            )
        }

        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(
            0.001,
            CMTimeGetSeconds(duration)
        )

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            let queue = DispatchQueue(
                label: "nl.maarten.VideoArchiveCompressor.extremeHEVC"
            )

            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(sample) {
                            writerInput.markAsFinished()
                            reader.cancelReading()
                            writer.cancelWriting()

                            continuation.resume(
                                throwing: CompressionError.exportFailed(
                                    writer.error?.localizedDescription ??
                                    "HEVC-frame kon niet worden geschreven"
                                )
                            )
                            return
                        }

                        let seconds = CMTimeGetSeconds(
                            CMSampleBufferGetPresentationTimeStamp(sample)
                        )

                        if seconds.isFinite {
                            onProgress(
                                min(
                                    0.99,
                                    max(0, seconds / totalSeconds)
                                )
                            )
                        }
                    } else {
                        writerInput.markAsFinished()

                        if reader.status == .failed {
                            writer.cancelWriting()
                            continuation.resume(
                                throwing: CompressionError.exportFailed(
                                    reader.error?.localizedDescription ??
                                    "videoreader is mislukt"
                                )
                            )
                            return
                        }

                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(
                                    throwing: CompressionError.exportFailed(
                                        writer.error?.localizedDescription ??
                                        "HEVC-export kon niet worden afgerond"
                                    )
                                )
                            }
                        }

                        return
                    }
                }
            }
        }
    }

    private func remuxMOVForFinalCut(
        original: URL,
        encodedVideoFile: URL,
        destination: URL
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)

        let originalAsset = AVURLAsset(url: original)
        let encodedAsset = AVURLAsset(url: encodedVideoFile)

        let encodedVideos = try await encodedAsset.loadTracks(withMediaType: .video)
        guard let encodedVideo = encodedVideos.first else {
            throw CompressionError.remuxFailed(
                "HEVC-export bevat geen videotrack"
            )
        }

        let originalAudio = try await originalAsset.loadTracks(withMediaType: .audio)
        let originalTimecode = try await originalAsset.loadTracks(withMediaType: .timecode)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        } catch {
            throw CompressionError.remuxFailed(error.localizedDescription)
        }

        var pairs: [PassthroughPair] = []

        // Encoded HEVC video: stream-copy it, so there is no second encode.
        let videoPair = try await makePassthroughPair(
            asset: encodedAsset,
            track: encodedVideo,
            writer: writer,
            label: "video"
        )

        let videoTransform = try await encodedVideo.load(.preferredTransform)
        videoPair.input.transform = videoTransform
        pairs.append(videoPair)

        // Original audio: preserve codec, sample rate, channel layout and
        // number of tracks exactly. This is especially important for FCP.
        for (index, track) in originalAudio.enumerated() {
            let pair = try await makePassthroughPair(
                asset: originalAsset,
                track: track,
                writer: writer,
                label: "audio \(index + 1)"
            )
            pairs.append(pair)
        }

        // Original QuickTime timecode track(s). Apple documents timecode as a
        // separate 'tmcd' media track associated with the video track.
        for (index, track) in originalTimecode.enumerated() {
            let pair = try await makePassthroughPair(
                asset: originalAsset,
                track: track,
                writer: writer,
                label: "timecode \(index + 1)"
            )

            let associationType = AVAssetTrack.AssociationType.timecode.rawValue

            guard videoPair.input.canAddTrackAssociation(
                withTrackOf: pair.input,
                type: associationType
            ) else {
                throw CompressionError.remuxFailed(
                    "timecode kan niet aan videotrack worden gekoppeld"
                )
            }

            videoPair.input.addTrackAssociation(
                withTrackOf: pair.input,
                type: associationType
            )

            pairs.append(pair)
        }

        guard writer.startWriting() else {
            throw CompressionError.remuxFailed(
                writer.error?.localizedDescription ?? "writer kon niet starten"
            )
        }

        writer.startSession(atSourceTime: .zero)

        for pair in pairs {
            guard pair.reader.startReading() else {
                writer.cancelWriting()
                throw CompressionError.remuxFailed(
                    pair.reader.error?.localizedDescription ??
                    "\(pair.label)-reader kon niet starten"
                )
            }
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            let group = DispatchGroup()
            let lock = NSLock()
            var firstError: Error?

            func setFirstError(_ error: Error) {
                lock.lock()
                if firstError == nil {
                    firstError = error
                }
                lock.unlock()
            }

            for (index, pair) in pairs.enumerated() {
                group.enter()

                let queue = DispatchQueue(
                    label: "nl.maarten.VideoArchiveCompressor.remux.\(index)"
                )

                pair.input.requestMediaDataWhenReady(on: queue) {
                    while pair.input.isReadyForMoreMediaData {
                        if let sample = pair.output.copyNextSampleBuffer() {
                            if !pair.input.append(sample) {
                                let error = writer.error ??
                                    CompressionError.remuxFailed(
                                        "\(pair.label) kon niet worden geschreven"
                                    )

                                setFirstError(error)
                                pair.input.markAsFinished()
                                group.leave()
                                return
                            }
                        } else {
                            if pair.reader.status == .failed {
                                setFirstError(
                                    pair.reader.error ??
                                    CompressionError.remuxFailed(
                                        "\(pair.label) kon niet worden gelezen"
                                    )
                                )
                            }

                            pair.input.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                lock.lock()
                let copyError = firstError
                lock.unlock()

                if let copyError {
                    writer.cancelWriting()
                    continuation.resume(throwing: copyError)
                    return
                }

                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: CompressionError.remuxFailed(
                                writer.error?.localizedDescription ??
                                "MOV kon niet worden afgerond"
                            )
                        )
                    }
                }
            }
        }
    }

    private func makePassthroughPair(
        asset: AVAsset,
        track: AVAssetTrack,
        writer: AVAssetWriter,
        label: String
    ) async throws -> PassthroughPair {
        let reader: AVAssetReader

        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CompressionError.remuxFailed(
                "\(label): \(error.localizedDescription)"
            )
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )

        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw CompressionError.remuxFailed(
                "\(label): reader-output niet ondersteund"
            )
        }

        reader.add(output)

        let descriptions = try await track.load(.formatDescriptions)
        let formatHint = descriptions.first

        let input = AVAssetWriterInput(
            mediaType: track.mediaType,
            outputSettings: nil,
            sourceFormatHint: formatHint
        )

        input.expectsMediaDataInRealTime = false

        guard writer.canAdd(input) else {
            throw CompressionError.remuxFailed(
                "\(label): writer-input niet ondersteund"
            )
        }

        writer.add(input)

        return PassthroughPair(
            reader: reader,
            output: output,
            input: input,
            label: label
        )
    }

    private func verifyFinalCutCompatibility(
        source: URL,
        output: URL
    ) async throws {
        let oldAsset = AVURLAsset(url: source)
        let newAsset = AVURLAsset(url: output)

        let oldVideoTracks = try await oldAsset.loadTracks(withMediaType: .video)
        let newVideoTracks = try await newAsset.loadTracks(withMediaType: .video)

        guard let oldVideo = oldVideoTracks.first,
              let newVideo = newVideoTracks.first else {
            throw CompressionError.invalidOutput
        }

        let oldDuration = try await oldAsset.load(.duration)
        let newDuration = try await newAsset.load(.duration)

        let oldSeconds = CMTimeGetSeconds(oldDuration)
        let newSeconds = CMTimeGetSeconds(newDuration)

        if oldSeconds.isFinite && newSeconds.isFinite && oldSeconds > 0 {
            // Replacement media must cover the complete original range.
            let tolerance = 0.005

            guard newSeconds + tolerance >= oldSeconds else {
                throw CompressionError.durationMismatch(
                    source: oldSeconds,
                    output: newSeconds
                )
            }
        }

        let oldFPS = try await oldVideo.load(.nominalFrameRate)
        let newFPS = try await newVideo.load(.nominalFrameRate)

        if oldFPS > 0 && newFPS > 0 {
            guard abs(oldFPS - newFPS) < 0.01 else {
                throw CompressionError.frameRateMismatch(
                    source: oldFPS,
                    output: newFPS
                )
            }
        }

        let oldAudio = try await oldAsset.loadTracks(withMediaType: .audio)
        let newAudio = try await newAsset.loadTracks(withMediaType: .audio)

        guard oldAudio.count == newAudio.count else {
            throw CompressionError.audioTrackMismatch(
                source: oldAudio.count,
                output: newAudio.count
            )
        }

        for index in oldAudio.indices {
            let oldChannels = try await channelCount(for: oldAudio[index])
            let newChannels = try await channelCount(for: newAudio[index])

            if let oldChannels, let newChannels {
                guard oldChannels == newChannels else {
                    throw CompressionError.audioChannelMismatch(
                        track: index + 1,
                        source: oldChannels,
                        output: newChannels
                    )
                }
            }
        }

        let oldTimecode = try await oldAsset.loadTracks(withMediaType: .timecode)
        let newTimecode = try await newAsset.loadTracks(withMediaType: .timecode)

        guard oldTimecode.count == newTimecode.count else {
            throw CompressionError.timecodeTrackMismatch(
                source: oldTimecode.count,
                output: newTimecode.count
            )
        }
    }

    private func channelCount(
        for track: AVAssetTrack
    ) async throws -> Int? {
        let descriptions = try await track.load(.formatDescriptions)

        for description in descriptions {
            guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else {
                continue
            }

            guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(
                description
            ) else {
                continue
            }

            return Int(basic.pointee.mChannelsPerFrame)
        }

        return nil
    }

    private func chooseFileType(
        for url: URL,
        supported: [AVFileType]
    ) throws -> AVFileType {
        let ext = url.pathExtension.lowercased()

        let desired: AVFileType

        switch ext {
        case "mov":
            desired = .mov
        case "mp4":
            desired = .mp4
        case "m4v":
            desired = .m4v
        default:
            throw CompressionError.unsupportedContainer
        }

        guard supported.contains(desired) else {
            throw CompressionError.unsupportedContainer
        }

        return desired
    }

    private func tempURL(
        for source: URL,
        marker: String
    ) -> URL {
        source
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(source.deletingPathExtension().lastPathComponent).\(marker)_\(UUID().uuidString)"
            )
            .appendingPathExtension(source.pathExtension)
    }

    private func backupURL(for source: URL) -> URL {
        source
            .deletingLastPathComponent()
            .appendingPathComponent(".\(source.lastPathComponent).VAC_ORIGINAL")
    }
}
