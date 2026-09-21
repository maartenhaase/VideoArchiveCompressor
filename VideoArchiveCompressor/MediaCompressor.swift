import Foundation
import AVFoundation
import CoreMedia

enum CompressionError: LocalizedError {
    case noVideo
    case unsupportedPreset
    case unsupportedContainer
    case exportFailed(String)
    case invalidOutput
    case durationMismatch(source: Double, output: Double)
    case frameRateMismatch(source: Float, output: Float)
    case audioTrackMismatch(source: Int, output: Int)
    case audioChannelMismatch(track: Int, source: Int, output: Int)
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
        case .notSmaller:
            return "nieuwe video is niet kleiner"
        case .replaceFailed(let message):
            return message
        }
    }
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
        let tmp = tempURL(for: source)
        let backup = backupURL(for: source)

        try? fm.removeItem(at: tmp)

        export.outputURL = tmp
        export.outputFileType = fileType
        export.shouldOptimizeForNetworkUse = false

        if #available(macOS 15.0, *) {
            export.audioTrackGroupHandling = .preserveAlternateTracks
        }

        let progressTask = Task {
            while !Task.isCancelled {
                onProgress(Double(export.progress))

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
        onProgress(Double(export.progress))

        guard export.status == .completed else {
            try? fm.removeItem(at: tmp)

            if export.status == .cancelled {
                throw CancellationError()
            }

            throw CompressionError.exportFailed(
                export.error?.localizedDescription ?? "export mislukt"
            )
        }

        let newBytes = Int64(
            (try tmp.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        )

        guard newBytes > 256_000 else {
            try? fm.removeItem(at: tmp)
            throw CompressionError.invalidOutput
        }

        guard originalBytes == 0 || newBytes < originalBytes else {
            try? fm.removeItem(at: tmp)
            throw CompressionError.notSmaller
        }

        do {
            try await verifyFinalCutCompatibility(
                source: source,
                output: tmp
            )
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }

        try? fm.removeItem(at: backup)

        do {
            try fm.moveItem(at: source, to: backup)

            do {
                try fm.moveItem(at: tmp, to: source)
            } catch {
                try? fm.moveItem(at: backup, to: source)
                try? fm.removeItem(at: tmp)

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
            try? fm.removeItem(at: tmp)

            throw CompressionError.replaceFailed(
                error.localizedDescription
            )
        }

        return newBytes
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
            // FCP requires replacement media to be long enough to cover every
            // referenced clip. Do not accept a meaningfully shorter file.
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

    private func tempURL(for source: URL) -> URL {
        source
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(source.deletingPathExtension().lastPathComponent).VAC_TEMP_\(UUID().uuidString)"
            )
            .appendingPathExtension(source.pathExtension)
    }

    private func backupURL(for source: URL) -> URL {
        source
            .deletingLastPathComponent()
            .appendingPathComponent(".\(source.lastPathComponent).VAC_ORIGINAL")
    }
}
