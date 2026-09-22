import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: ArchiveViewModel
    @State private var isTargeted = false
    @State private var showFlashConfirm = false
    @State private var showNitroConfirm = false
    @State private var showOrganizeConfirm = false
    // Legacy controls are no longer shown, but their private views still
    // compile for now while the UI stays intentionally limited to 3 modes.
    @State private var showFullBatchConfirm = false
    @State private var showExtremeConfirm = false
    @State private var showPhotoConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    sourceCard
                    operationsCard
                    queueCard
                }
                .padding(22)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "Video Archive Compressor",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )
        ) {
            Button("OK") {
                model.lastError = nil
            }
        } message: {
            Text(model.lastError ?? "")
        }
        .confirmationDialog(
            "FLASH 720p starten?",
            isPresented: $showFlashConfirm,
            titleVisibility: .visible
        ) {
            Button("Start FLASH 720p", role: .destructive) {
                model.startFlash720VideoOnly()
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(
                "Allersnelste archiefmodus: hardware H.264, maximaal 1280×720 en agressieve bitrate. " +
                "Framerate, audio-indeling en timecode worden bewaakt voor Final Cut."
            )
        }
        .confirmationDialog(
            "MAX COMPRESSIE starten?",
            isPresented: $showNitroConfirm,
            titleVisibility: .visible
        ) {
            Button("Start MAX COMPRESSIE", role: .destructive) {
                model.startNitroVideoOnly()
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(
                "Behoudt de oorspronkelijke resolutie en gebruikt directe VideoToolbox HEVC-hardwarecompressie. " +
                "Kleiner met betere kwaliteit, maar duidelijk langzamer dan FLASH 720p."
            )
        }
        .confirmationDialog(
            "Schijf opruimen en herstructureren?",
            isPresented: $showOrganizeConfirm,
            titleVisibility: .visible
        ) {
            Button("Opruimen & sorteren", role: .destructive) {
                model.startOrganizeOnly()
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(
                "Geen video-encode. Final Cut cache wordt verwijderd en projecten/documenten/screenshots/audio worden op jaar en type geordend."
            )
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Video Archive Compressor")
                    .font(.title2.weight(.semibold))

                Text("Comprimeren • FCP-archief • hele schijven automatisch opruimen")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if model.finalCutIsRunning {
                Label(
                    "Sluit Final Cut eerst",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.medium))
                .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var sourceCard: some View {
        GroupBox {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isTargeted
                                ? Color.accentColor
                                : Color.secondary.opacity(0.35),
                            style: StrokeStyle(
                                lineWidth: isTargeted ? 2 : 1,
                                dash: [7]
                            )
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(
                                    isTargeted
                                        ? Color.accentColor.opacity(0.06)
                                        : Color.clear
                                )
                        )
                        .frame(height: 112)

                    VStack(spacing: 8) {
                        Image(systemName: "externaldrive.badge.plus")
                            .font(.system(size: 28))

                        if let url = model.sourceURL {
                            Text(url.lastPathComponent)
                                .font(.headline)

                            Text(url.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Sleep een .fcpbundle, map of harde schijf hierheen")
                                .font(.headline)

                            Text("of klik om te kiezen")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.chooseSource()
                }
                .onDrop(
                    of: [UTType.fileURL.identifier],
                    isTargeted: $isTargeted
                ) { providers in
                    guard let provider = providers.first else {
                        return false
                    }

                    provider.loadItem(
                        forTypeIdentifier: UTType.fileURL.identifier,
                        options: nil
                    ) { item, _ in
                        var resolvedURL: URL?

                        if let data = item as? Data {
                            resolvedURL = URL(
                                dataRepresentation: data,
                                relativeTo: nil
                            )
                        } else if let url = item as? URL {
                            resolvedURL = url
                        }

                        if let resolvedURL {
                            Task { @MainActor in
                                model.acceptSource(resolvedURL)
                            }
                        }
                    }

                    return true
                }

                HStack(spacing: 10) {
                    Button("Kies bron…") {
                        model.chooseSource()
                    }

                    Button("Opnieuw scannen") {
                        Task {
                            await model.scan()
                        }
                    }
                    .disabled(
                        model.sourceURL == nil ||
                        model.isRunning ||
                        model.isScanning
                    )

                    Spacer()

                    if model.isScanning {
                        ProgressView()
                            .controlSize(.small)

                        Text("Scannen…")
                            .foregroundColor(.secondary)
                    } else {
                        Text(model.statusText)
                            .foregroundColor(.secondary)
                    }
                }

                if model.unsupportedCount > 0 {
                    Label(
                        "\(model.unsupportedCount) MTS/MXF/AVI of externe links " +
                        "worden bewust niet aangeraakt.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        } label: {
            Label("1. Bron", systemImage: "folder")
        }
    }

    private var operationsCard: some View {
        GroupBox {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    OperationTile(
                        icon: "folder.badge.gearshape",
                        title: "1. OPRUIMEN",
                        subtitle: "BEGIN HIER. Geen video-encode. Verwijdert hermaakbare Final Cut-cache en sorteert projecten en losse bestanden op jaar/type.",
                        buttonTitle: "STAP 1 • RUIM & SORTEER",
                        prominent: true
                    ) {
                        showOrganizeConfirm = true
                    }
                    .disabled(
                        model.sourceURL == nil ||
                        model.isRunning ||
                        model.isScanning ||
                        model.finalCutIsRunning
                    )

                    OperationTile(
                        icon: "hare.fill",
                        title: "2. FLASH 720p",
                        subtitle: "GRUWELIJK SNEL + KLEIN. Hardware H.264, maximaal 1280×720 en ±1,5–2,2 Mbit/s. Dit is de snelste archiefmodus.",
                        buttonTitle: "STAP 2 • START 720p"
                    ) {
                        showFlashConfirm = true
                    }
                    .disabled(
                        model.sourceURL == nil ||
                        model.isRunning ||
                        model.isScanning ||
                        model.finalCutIsRunning
                    )

                    OperationTile(
                        icon: "shippingbox.fill",
                        title: "3. MAX COMPRESSIE",
                        subtitle: "Originele resolutie blijft behouden. Hardware HEVC met zeer lage bitrate: 1080p ±1,8–2,5 en 4K ±4,5–6 Mbit/s. Kleiner, maar trager.",
                        buttonTitle: "STAP 3 • MAX COMPRESSIE"
                    ) {
                        showNitroConfirm = true
                    }
                    .disabled(
                        model.sourceURL == nil ||
                        model.isRunning ||
                        model.isScanning ||
                        model.finalCutIsRunning
                    )
                }

                if model.isRunning {
                    Divider()

                    VStack(spacing: 7) {
                        HStack {
                            Text(model.statusText)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button("Stop na huidige") {
                                model.stop()
                            }
                        }

                        ProgressView(
                            value: max(
                                model.utilityProgress,
                                model.overallProgress
                            )
                        )
                    }
                }

                if let summary = model.utilitySummary {
                    Divider()

                    Label(summary, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(.green)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Label(
                    "Aanbevolen volgorde: eerst OPRUIMEN, daarna voor oud noodarchief FLASH 720p. Gebruik MAX COMPRESSIE alleen als je de oorspronkelijke resolutie echt wilt bewaren.",
                    systemImage: "arrow.right.circle"
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        } label: {
            Label(
                "3 duidelijke stappen",
                systemImage: "list.number"
            )
        }
    }

    private var presetCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                ForEach(ArchivePreset.allCases) { preset in
                    PresetTile(
                        preset: preset,
                        selected: model.preset == preset
                    ) {
                        model.preset = preset
                    }
                }
            }
            .padding(10)
        } label: {
            Label(
                "2. Hoe klein mag het worden?",
                systemImage: "slider.horizontal.3"
            )
        }
    }

    private var actionCard: some View {
        GroupBox {
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Eerst 3 clips testen")
                            .font(.headline)

                        Text(
                            "De nieuwe clips krijgen exact dezelfde naam en plek. " +
                            "De oude versies blijven verborgen als backup."
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("TEST 3 CLIPS") {
                        model.startTest()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.jobs.isEmpty ||
                        model.isRunning ||
                        model.finalCutIsRunning
                    )
                }

                Divider()

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Daarna de hele batch")
                            .font(.headline)

                        Text(
                            "Geslaagde clips worden vervangen, maar alle originelen blijven als verborgen herstelbackup staan. " +
                            "Na controle in Final Cut kun je ze met één knop verwijderen."
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("START HELE BATCH") {
                        showFullBatchConfirm = true
                    }
                    .disabled(
                        model.jobs.isEmpty ||
                        model.isRunning ||
                        model.finalCutIsRunning
                    )
                }

                if model.existingBackupCount > 0 {
                    Divider()

                    HStack {
                        Label(
                            "\(model.existingBackupCount) testbackup(s) gevonden",
                            systemImage: "arrow.uturn.backward.circle"
                        )
                        .foregroundColor(.secondary)

                        Spacer()

                        Button("Herstel originelen") {
                            model.restoreTestBackups()
                        }
                        .disabled(model.isRunning)

                        Button("Testbackups verwijderen") {
                            model.deleteTestBackups()
                        }
                        .disabled(model.isRunning)
                    }
                }

                if model.isRunning {
                    Divider()

                    VStack(spacing: 8) {
                        HStack {
                            Text(model.statusText)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Text("\(Int(model.overallProgress * 100))%")
                                .monospacedDigit()
                        }

                        ProgressView(value: model.overallProgress)

                        HStack {
                            Text(
                                model.savedBytes > 0
                                    ? "\(model.savedBytes.storageString) bespaard"
                                    : "Bezig met eerste bestand…"
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)

                            Spacer()

                            Button("Stop na huidige") {
                                model.stop()
                            }

                            Button("Annuleer huidige", role: .destructive) {
                                model.cancelCurrent()
                            }
                        }
                    }
                }
            }
            .padding(10)
        } label: {
            Label("3. Start", systemImage: "play.circle")
        }
    }

    private var queueCard: some View {
        GroupBox {
            VStack(spacing: 0) {
                HStack {
                    Text("\(model.jobs.count) bestanden")
                    Text("•")
                    Text(model.totalBytes.storageString)

                    if model.savedBytes > 0 {
                        Text("•")

                        Text("\(model.savedBytes.storageString) bespaard")
                            .foregroundColor(.green)
                    }

                    Spacer()
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()

                if model.jobs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)

                        Text("Nog geen video's")
                            .font(.headline)

                        Text("Kies eerst een bron hierboven.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.jobs) { job in
                            JobRow(job: job)
                            Divider()
                        }
                    }
                }
            }
        } label: {
            Label("Batch", systemImage: "list.bullet.rectangle")
        }
    }
}

private struct OperationTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let buttonTitle: String
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.accentColor)

                Text(title)
                    .font(.headline)

                Spacer()
            }

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if prominent {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 165, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    prominent
                        ? Color.accentColor.opacity(0.09)
                        : Color.secondary.opacity(0.05)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    prominent
                        ? Color.accentColor.opacity(0.8)
                        : Color.secondary.opacity(0.16),
                    lineWidth: prominent ? 1.5 : 1
                )
        )
    }
}

private struct PresetTile: View {
    let preset: ArchivePreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(preset.title)
                        .font(.headline)

                    Spacer()

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                }

                Text(preset.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)

                if preset == .extremeOriginalResolution {
                    Text("NITRO MAX / SNELST")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(13)
            .frame(
                maxWidth: .infinity,
                minHeight: 98,
                alignment: .topLeading
            )
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(
                        selected
                            ? Color.accentColor.opacity(0.10)
                            : Color.secondary.opacity(0.06)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(
                        selected
                            ? Color.accentColor
                            : Color.secondary.opacity(0.18),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct JobRow: View {
    let job: MediaJob

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if case .encoding = job.state {
                    ProgressView(value: job.progress)
                } else {
                    Text(job.state.label)
                        .font(.caption)
                        .foregroundColor(stateColor)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(job.originalBytes.storageString)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if job.savedBytes > 0 {
                    Text("−\(job.savedBytes.storageString)")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.green)
                }
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch job.state {
        case .queued:
            Image(systemName: "circle")
                .foregroundColor(.secondary)

        case .encoding:
            ProgressView()
                .controlSize(.small)

        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)

        case .skipped:
            Image(systemName: "minus.circle.fill")
                .foregroundColor(.secondary)

        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
    }

    private var stateColor: Color {
        switch job.state {
        case .failed:
            return .red
        case .done:
            return .green
        default:
            return .secondary
        }
    }
}
