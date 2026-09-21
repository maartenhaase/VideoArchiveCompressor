import Foundation

enum ProjectCategory: String, CaseIterable {
    case wedding = "Trouwfilms"
    case corporateLarge = "Bedrijfsfilms - Groot"
    case corporateSmall = "Bedrijfsfilms - Klein"
    case personal = "Persoonlijk"
    case otherLarge = "Overig - Groot"
    case otherSmall = "Overig - Klein"
}

enum ProjectKind: String {
    case finalCutLibrary = "Final Cut Library"
    case folder = "Projectmap"
}

struct ArchiveProject: Identifiable {
    let id = UUID()
    let url: URL
    let kind: ProjectKind
    let year: Int
    let category: ProjectCategory
    let bytes: Int64

    var name: String { url.lastPathComponent }
}

struct OrganizeSummary {
    var movedProjects = 0
    var movedLooseFiles = 0
    var skippedFiles = 0
    var cacheBytesRemoved: Int64 = 0
}

enum ArchiveOrganizer {
    static let archiveFolderName = "ARCHIEF_GESORTEERD"

    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mts", "m2ts", "mxf", "avi"
    ]

    private static let groupingWords: Set<String> = [
        "projecten", "projects", "archief", "archive",
        "video", "videos", "films", "film",
        "bruiloften", "trouwfilms", "weddings",
        "zakelijk", "bedrijven", "corporate",
        "elements", "elementen", "werk", "jobs",
        "downloads", "desktop", "documents", "documenten",
        "pictures", "photos", "afbeeldingen", "fotos", "foto's",
        "audio", "music", "muziek", "samples",
        "overig", "misc", "unsorted", "sorteren", "losse bestanden"
    ]

    private static let protectedSystemFolders: Set<String> = [
        "system", "applications", "library", "users",
        ".spotlight-v100", ".fseventsd", ".trashes",
        ".documentrevisions-v100", "backups.backupdb"
    ]

    static func discoverProjects(in root: URL) -> [ArchiveProject] {
        let fm = FileManager.default
        var projects: [ArchiveProject] = []

        if root.pathExtension.lowercased() == "fcpbundle" {
            let bytes = folderSize(root)

            return [
                ArchiveProject(
                    url: root,
                    kind: .finalCutLibrary,
                    year: detectedYear(for: root),
                    category: category(for: root, bytes: bytes),
                    bytes: bytes
                )
            ]
        }

        func walk(_ folder: URL, depth: Int) {
            guard depth <= 5 else { return }

            guard let children = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isPackageKey
                ],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            for child in children {
                if child.lastPathComponent == archiveFolderName {
                    continue
                }

                if protectedSystemFolders.contains(
                    child.lastPathComponent.lowercased()
                ) {
                    continue
                }

                let values = try? child.resourceValues(
                    forKeys: [.isDirectoryKey, .isPackageKey]
                )

                guard values?.isDirectory == true else { continue }

                if child.pathExtension.lowercased() == "fcpbundle" {
                    let bytes = folderSize(child)

                    projects.append(
                        ArchiveProject(
                            url: child,
                            kind: .finalCutLibrary,
                            year: detectedYear(for: child),
                            category: category(for: child, bytes: bytes),
                            bytes: bytes
                        )
                    )
                    continue
                }

                // Never inspect arbitrary package internals.
                if values?.isPackage == true {
                    continue
                }

                if isGroupingFolder(child) {
                    walk(child, depth: depth + 1)
                    continue
                }

                if containsVideoRecursively(child, maxDepth: 4) {
                    let bytes = folderSize(child)

                    projects.append(
                        ArchiveProject(
                            url: child,
                            kind: .folder,
                            year: detectedYear(for: child),
                            category: category(for: child, bytes: bytes),
                            bytes: bytes
                        )
                    )
                } else {
                    walk(child, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)

        // Prefer the highest-level project folder so nested video folders
        // remain inside their parent project.
        return projects
            .sorted { $0.url.path.count < $1.url.path.count }
            .reduce(into: [ArchiveProject]()) { result, project in
                let covered = result.contains {
                    project.url.path.hasPrefix($0.url.path + "/")
                }

                if !covered {
                    result.append(project)
                }
            }
    }

    static func purgeGeneratedFinalCutMedia(in root: URL) -> Int64 {
        let fm = FileManager.default
        var reclaimed: Int64 = 0

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        while let url = enumerator.nextObject() as? URL {
            let lower = url.path.lowercased()

            guard lower.contains(".fcpbundle/") else { continue }

            let name = url.lastPathComponent.lowercased()

            if [
                "render files",
                "transcoded media",
                "analysis files"
            ].contains(name) {
                reclaimed += folderSize(url)
                try? fm.removeItem(at: url)
                enumerator.skipDescendants()
            }
        }

        return reclaimed
    }

    static func sortLooseFiles(
        in root: URL,
        protecting projects: [ArchiveProject]
    ) -> (moved: Int, skipped: Int) {
        let fm = FileManager.default

        guard root.pathExtension.lowercased() != "fcpbundle" else {
            return (0, 0)
        }

        let archiveRoot = root.appendingPathComponent(
            archiveFolderName,
            isDirectory: true
        )

        let protectedPaths = projects.map { $0.url.path }

        func isProtected(_ url: URL) -> Bool {
            protectedPaths.contains { path in
                url.path == path || url.path.hasPrefix(path + "/")
            }
        }

        var files: [URL] = []

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isPackageKey,
                .isHiddenKey
            ],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return (0, 0)
        }

        while let url = enumerator.nextObject() as? URL {
            if url.path.hasPrefix(archiveRoot.path + "/") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if isProtected(url) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try? url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isPackageKey,
                    .isHiddenKey
                ]
            )

            if values?.isDirectory == true {
                let lowerName = url.lastPathComponent.lowercased()

                if protectedSystemFolders.contains(lowerName) ||
                    values?.isPackage == true {
                    enumerator.skipDescendants()
                }

                continue
            }

            guard values?.isRegularFile == true else { continue }
            guard values?.isHidden != true else { continue }

            let name = url.lastPathComponent

            if name.hasPrefix(".") ||
                name.contains(".VAC_ORIGINAL") ||
                name.contains(".VAC_TEMP") ||
                name == ".DS_Store" {
                continue
            }

            files.append(url)
        }

        var moved = 0
        var skipped = 0

        for file in files {
            guard fm.fileExists(atPath: file.path) else {
                skipped += 1
                continue
            }

            guard let destinationFolder = destinationFolder(
                for: file,
                archiveRoot: archiveRoot
            ) else {
                skipped += 1
                continue
            }

            do {
                try fm.createDirectory(
                    at: destinationFolder,
                    withIntermediateDirectories: true
                )

                let destination = uniqueDestination(
                    for: file.lastPathComponent,
                    in: destinationFolder
                )

                try fm.moveItem(at: file, to: destination)
                moved += 1
            } catch {
                skipped += 1
            }
        }

        removeEmptyFolders(
            under: root,
            excluding: archiveRoot,
            protectedPaths: protectedPaths
        )

        return (moved, skipped)
    }

    static func organizeProjects(
        _ projects: [ArchiveProject],
        in root: URL
    ) -> (moved: Int, skipped: Int) {
        let fm = FileManager.default

        if root.pathExtension.lowercased() == "fcpbundle" {
            return (0, 1)
        }

        let archiveRoot = root.appendingPathComponent(
            archiveFolderName,
            isDirectory: true
        )

        var moved = 0
        var skipped = 0

        for project in projects {
            guard fm.fileExists(atPath: project.url.path) else {
                skipped += 1
                continue
            }

            if project.url.path.hasPrefix(archiveRoot.path + "/") {
                skipped += 1
                continue
            }

            // External/symlinked media can depend on paths. Do not move that
            // library automatically.
            if project.kind == .finalCutLibrary &&
                finalCutBundleHasExternalMedia(project.url) {
                skipped += 1
                continue
            }

            if project.kind == .folder &&
                folderContainsExternallyLinkedFinalCutLibrary(project.url) {
                skipped += 1
                continue
            }

            let destinationFolder = archiveRoot
                .appendingPathComponent(
                    String(project.year),
                    isDirectory: true
                )
                .appendingPathComponent(
                    "Projecten",
                    isDirectory: true
                )
                .appendingPathComponent(
                    project.category.rawValue,
                    isDirectory: true
                )

            do {
                try fm.createDirectory(
                    at: destinationFolder,
                    withIntermediateDirectories: true
                )

                let destination = uniqueDestination(
                    for: project.url.lastPathComponent,
                    in: destinationFolder
                )

                try fm.moveItem(
                    at: project.url,
                    to: destination
                )

                moved += 1
            } catch {
                skipped += 1
            }
        }

        return (moved, skipped)
    }

    private static func destinationFolder(
        for file: URL,
        archiveRoot: URL
    ) -> URL? {
        let year = detectedYear(for: file)
        let base = archiveRoot.appendingPathComponent(
            String(year),
            isDirectory: true
        )

        let name = file.lastPathComponent
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            .lowercased()

        let ext = file.pathExtension.lowercased()

        if name.contains("schermafbeelding") ||
            name.contains("screenshot") ||
            name.contains("screen shot") {
            return base
                .appendingPathComponent("Afbeeldingen", isDirectory: true)
                .appendingPathComponent(
                    "Schermafbeeldingen",
                    isDirectory: true
                )
        }

        switch ext {
        case "pdf":
            return docs(base, "PDF")
        case "doc", "docx", "odt", "pages", "rtf":
            return docs(base, "Tekstdocumenten")
        case "xls", "xlsx", "ods", "numbers", "csv":
            return docs(base, "Spreadsheets")
        case "ppt", "pptx", "odp", "key":
            return docs(base, "Presentaties")
        case "txt", "md":
            return docs(base, "Tekst")
        case "epub", "mobi":
            return docs(base, "E-books")

        case "jpg", "jpeg", "heic":
            return images(base, "Foto's")
        case "png", "gif", "webp", "tif", "tiff", "bmp":
            return images(base, "Afbeeldingen")
        case "cr2", "cr3", "nef", "arw", "raf", "dng", "orf", "rw2":
            return images(base, "RAW")

        case "mov", "mp4", "m4v", "mts", "m2ts", "mxf", "avi":
            return base
                .appendingPathComponent("Video", isDirectory: true)
                .appendingPathComponent("Losse video's", isDirectory: true)

        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg":
            return base
                .appendingPathComponent("Audio", isDirectory: true)
                .appendingPathComponent(
                    audioSubtype(name: name),
                    isDirectory: true
                )

        case "zip", "rar", "7z", "tar", "gz", "bz2":
            return base.appendingPathComponent(
                "Archieven & ZIP",
                isDirectory: true
            )

        case "dmg", "pkg":
            return base.appendingPathComponent(
                "Installatiebestanden",
                isDirectory: true
            )

        case "psd", "psb":
            return creative(base, "Photoshop")
        case "ai", "eps", "svg":
            return creative(base, "Illustrator & Vector")
        case "indd", "idml":
            return creative(base, "InDesign")
        case "fcpxml":
            return creative(base, "Final Cut XML")
        case "prproj":
            return creative(base, "Premiere")
        case "aep", "aepx":
            return creative(base, "After Effects")

        default:
            if ext.isEmpty {
                return base
                    .appendingPathComponent("Overig", isDirectory: true)
                    .appendingPathComponent(
                        "Zonder extensie",
                        isDirectory: true
                    )
            }

            return base
                .appendingPathComponent("Overig", isDirectory: true)
                .appendingPathComponent(
                    ext.uppercased(),
                    isDirectory: true
                )
        }
    }

    private static func docs(
        _ base: URL,
        _ subtype: String
    ) -> URL {
        base
            .appendingPathComponent("Documenten", isDirectory: true)
            .appendingPathComponent(subtype, isDirectory: true)
    }

    private static func images(
        _ base: URL,
        _ subtype: String
    ) -> URL {
        base
            .appendingPathComponent("Afbeeldingen", isDirectory: true)
            .appendingPathComponent(subtype, isDirectory: true)
    }

    private static func creative(
        _ base: URL,
        _ subtype: String
    ) -> URL {
        base
            .appendingPathComponent("Creatief", isDirectory: true)
            .appendingPathComponent(subtype, isDirectory: true)
    }

    private static func audioSubtype(name: String) -> String {
        if name.contains("voice") ||
            name.contains("memo") ||
            name.contains("opname") ||
            name.contains("recording") {
            return "Opnames"
        }

        return "Muziek & Audio"
    }

    private static func finalCutBundleHasExternalMedia(
        _ bundle: URL
    ) -> Bool {
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: bundle,
            includingPropertiesForKeys: [
                .isSymbolicLinkKey,
                .isAliasFileKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        while let url = enumerator.nextObject() as? URL {
            let lower = url.path.lowercased()

            if lower.contains("/original media/") {
                let values = try? url.resourceValues(
                    forKeys: [
                        .isSymbolicLinkKey,
                        .isAliasFileKey
                    ]
                )

                if values?.isSymbolicLink == true ||
                    values?.isAliasFile == true {
                    return true
                }
            }
        }

        return false
    }

    private static func folderContainsExternallyLinkedFinalCutLibrary(
        _ folder: URL
    ) -> Bool {
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "fcpbundle" else {
                continue
            }

            if finalCutBundleHasExternalMedia(url) {
                return true
            }

            enumerator.skipDescendants()
        }

        return false
    }

    private static func uniqueDestination(
        for name: String,
        in folder: URL
    ) -> URL {
        let fm = FileManager.default
        let original = folder.appendingPathComponent(name)

        guard !fm.fileExists(atPath: original.path) else {
            let ns = name as NSString
            let ext = ns.pathExtension
            let base = ns.deletingPathExtension
            var counter = 2

            while true {
                let candidateName = ext.isEmpty
                    ? "\(base) \(counter)"
                    : "\(base) \(counter).\(ext)"

                let candidate = folder.appendingPathComponent(
                    candidateName
                )

                if !fm.fileExists(atPath: candidate.path) {
                    return candidate
                }

                counter += 1
            }
        }

        return original
    }

    private static func detectedYear(for url: URL) -> Int {
        let path = url.path

        let regex = try? NSRegularExpression(
            pattern: #"(?<!\d)(19[89]\d|20[0-4]\d)(?!\d)"#
        )

        if let match = regex?.firstMatch(
            in: path,
            range: NSRange(path.startIndex..., in: path)
        ),
           let range = Range(match.range(at: 1), in: path),
           let year = Int(path[range]) {
            return year
        }

        let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .creationDateKey]
        )

        let date = values?.contentModificationDate ??
            values?.creationDate ??
            Date()

        return Calendar.current.component(.year, from: date)
    }

    private static func category(
        for url: URL,
        bytes: Int64
    ) -> ProjectCategory {
        let text = url.path
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            .lowercased()

        let weddingWords = [
            "bruiloft", "trouw", "wedding", "huwelijk",
            "bride", "groom", "same day edit", "sde"
        ]

        if weddingWords.contains(where: { text.contains($0) }) ||
            looksLikeCoupleName(
                url.deletingPathExtension().lastPathComponent
            ) {
            return .wedding
        }

        let personalWords = [
            "vakantie", "holiday", "familie", "family",
            "prive", "persoonlijk", "birthday", "verjaardag"
        ]

        if personalWords.contains(where: { text.contains($0) }) {
            return .personal
        }

        let corporateWords = [
            "bedrijf", "bedrijfs", "corporate", "commercial",
            "promo", "product", "recruitment", "interview",
            "social", "klant", "campaign", "campagne"
        ]

        let isLarge = bytes >= 50 * 1_000_000_000

        if corporateWords.contains(where: { text.contains($0) }) {
            return isLarge ? .corporateLarge : .corporateSmall
        }

        return isLarge ? .otherLarge : .otherSmall
    }

    private static func looksLikeCoupleName(
        _ name: String
    ) -> Bool {
        let cleaned = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let patterns = [
            #"\b[A-ZÀ-Ý][A-Za-zÀ-ÿ']+\s*&\s*[A-ZÀ-Ý][A-Za-zÀ-ÿ']+\b"#,
            #"\b[A-ZÀ-Ý][A-Za-zÀ-ÿ']+\s+en\s+[A-ZÀ-Ý][A-Za-zÀ-ÿ']+\b"#,
            #"\b[A-ZÀ-Ý][A-Za-zÀ-ÿ']+\s*\+\s*[A-ZÀ-Ý][A-Za-zÀ-ÿ']+\b"#
        ]

        return patterns.contains { pattern in
            cleaned.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    private static func isGroupingFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            .lowercased()

        if groupingWords.contains(name) {
            return true
        }

        return Int(name) != nil && name.count == 4
    }

    private static func containsVideoRecursively(
        _ folder: URL,
        maxDepth: Int
    ) -> Bool {
        let fm = FileManager.default
        let baseComponents = folder.pathComponents.count

        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isPackageKey
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return false
        }

        while let url = enumerator.nextObject() as? URL {
            let depth = url.pathComponents.count - baseComponents

            if depth > maxDepth {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isPackageKey]
            )

            if values?.isDirectory == true {
                if url.pathExtension.lowercased() == "fcpbundle" {
                    return true
                }

                if values?.isPackage == true {
                    enumerator.skipDescendants()
                }

                continue
            }

            if videoExtensions.contains(
                url.pathExtension.lowercased()
            ) {
                return true
            }
        }

        return false
    }

    private static func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0

        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )

            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }

        return total
    }

    private static func removeEmptyFolders(
        under root: URL,
        excluding archiveRoot: URL,
        protectedPaths: [String]
    ) {
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var folders: [URL] = []

        while let url = enumerator.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }

            if url.path == archiveRoot.path ||
                url.path.hasPrefix(archiveRoot.path + "/") {
                enumerator.skipDescendants()
                continue
            }

            if protectedPaths.contains(where: {
                url.path == $0 || url.path.hasPrefix($0 + "/")
            }) {
                enumerator.skipDescendants()
                continue
            }

            folders.append(url)
        }

        for folder in folders.sorted(
            by: { $0.path.count > $1.path.count }
        ) {
            if let contents = try? fm.contentsOfDirectory(
                atPath: folder.path
            ),
               contents.isEmpty {
                try? fm.removeItem(at: folder)
            }
        }
    }
}
