import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PhotoCompressionResult {
    let url: URL
    let oldBytes: Int64
    let newBytes: Int64
    let didCompress: Bool
    let error: String?

    var savedBytes: Int64 {
        guard didCompress else { return 0 }
        return max(0, oldBytes - newBytes)
    }
}

enum PhotoCompressor {
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif"
    ]

    static func discover(in root: URL) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isHiddenKey
            ],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        while let url = enumerator.nextObject() as? URL {
            let lower = url.path.lowercased()

            if lower.contains("/\(ArchiveOrganizer.archiveFolderName.lowercased())/") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            // Do not touch stills inside FCP packages automatically.
            if lower.contains(".fcpbundle/") {
                if url.pathExtension.lowercased() == "fcpbundle" {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try? url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isHiddenKey
                ]
            )

            if values?.isDirectory == true {
                continue
            }

            guard values?.isRegularFile == true,
                  values?.isHidden != true else {
                continue
            }

            if supportedExtensions.contains(
                url.pathExtension.lowercased()
            ) {
                urls.append(url)
            }
        }

        return urls
    }

    static func compress(
        _ url: URL,
        quality: Double = 0.67
    ) -> PhotoCompressionResult {
        let fm = FileManager.default

        let oldBytes = Int64(
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        )

        guard oldBytes > 200_000 else {
            return PhotoCompressionResult(
                url: url,
                oldBytes: oldBytes,
                newBytes: oldBytes,
                didCompress: false,
                error: nil
            )
        }

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ),
        CGImageSourceGetCount(source) > 0,
        let type = CGImageSourceGetType(source) else {
            return PhotoCompressionResult(
                url: url,
                oldBytes: oldBytes,
                newBytes: oldBytes,
                didCompress: false,
                error: "afbeelding kon niet worden gelezen"
            )
        }

        let scratch = fm.temporaryDirectory
            .appendingPathComponent(
                "VideoArchiveCompressorPhotos",
                isDirectory: true
            )

        try? fm.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )

        let temp = scratch
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)

        try? fm.removeItem(at: temp)

        guard let destination = CGImageDestinationCreateWithURL(
            temp as CFURL,
            type,
            1,
            nil
        ) else {
            return PhotoCompressionResult(
                url: url,
                oldBytes: oldBytes,
                newBytes: oldBytes,
                didCompress: false,
                error: "afbeeldingsencoder niet beschikbaar"
            )
        }

        let options: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality:
                max(0.3, min(0.9, quality))
        ] as CFDictionary

        CGImageDestinationAddImageFromSource(
            destination,
            source,
            0,
            options
        )

        guard CGImageDestinationFinalize(destination) else {
            try? fm.removeItem(at: temp)

            return PhotoCompressionResult(
                url: url,
                oldBytes: oldBytes,
                newBytes: oldBytes,
                didCompress: false,
                error: "foto kon niet worden geschreven"
            )
        }

        let newBytes = Int64(
            (try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        )

        // Only replace if it actually makes a meaningful difference.
        guard newBytes > 0,
              newBytes < Int64(Double(oldBytes) * 0.88) else {
            try? fm.removeItem(at: temp)

            return PhotoCompressionResult(
                url: url,
                oldBytes: oldBytes,
                newBytes: oldBytes,
                didCompress: false,
                error: nil
            )
        }

        let oldProperties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [CFString: Any]

        guard let checkSource = CGImageSourceCreateWithURL(
            temp as CFURL,
            nil
        ),
        let newProperties = CGImageSourceCopyPropertiesAtIndex(
            checkSource,
            0,
            nil
        ) as? [CFString: Any] else {
            try? fm.removeItem(at: temp)

            return PhotoCompressionResult(
                url: url,
                oldBytes: oldBytes,
                newBytes: oldBytes,
                didCompress: false,
                error: "controle van gecomprimeerde foto mislukt"
            )
        }

        let oldWidth = oldProperties?[kCGImagePropertyPixelWidth] as? Int
        let oldHeight = oldProperties?[kCGImagePropertyPixelHeight] as? Int
        let newWidth = newProperties[kCGImagePropertyPixelWidth] as? Int
        let newHeight = newProperties[kCGImagePropertyPixelHeight] as? Int

        guard oldWidth == newWidth,
              oldHeight == newHeight else {
            try? fm.removeItem(at: temp)

            return PhotoCompressionResult(
                url: url,
                oldBytes: oldBytes,
                newBytes: oldBytes,
                didCompress: false,
                error: "resolutie veranderde onverwacht"
            )
        }

        let modificationDate = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate

        let backup = url
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).VAC_PHOTO_ORIGINAL"
            )

        do {
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: url, to: backup)

            do {
                try fm.copyItem(at: temp, to: url)
                try? fm.removeItem(at: temp)
            } catch {
                try? fm.moveItem(at: backup, to: url)
                try? fm.removeItem(at: temp)
                throw error
            }

            if let modificationDate {
                try? fm.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: url.path
                )
            }

            try? fm.removeItem(at: backup)

            return PhotoCompressionResult(
                url: url,
                oldBytes: oldBytes,
                newBytes: newBytes,
                didCompress: true,
                error: nil
            )
        } catch {
            try? fm.removeItem(at: temp)

            return PhotoCompressionResult(
                url: url,
                oldBytes: oldBytes,
                newBytes: oldBytes,
                didCompress: false,
                error: error.localizedDescription
            )
        }
    }
}
