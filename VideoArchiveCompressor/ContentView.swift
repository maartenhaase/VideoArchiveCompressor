import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: ArchiveViewModel
    @State private var isTargeted = false
    @State private var showFullBatchConfirm = false
    @State private var showExtremeConfirm = false
    @State private var showNitroConfirm = false
    @State private var showOrganizeConfirm = false
    @State private var showPhotoConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    sourceCard
                    operationsCard
                    presetCard
                    actionCard
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
            "NITRO video-compressie starten?",
            isPresented: $showNitroConfirm,
            titleVisibility: .visible
        ) {
            Button("Start NITRO", role: .destructive) {
                model.startNitroVideoOnly()
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(
                "Video's worden agressief naar hardware-HEVC gecomprimeerd met behoud van resolutie. " +
                "De eerste clips worden automatisch als veiligheidstest gecontroleerd op Final Cut-compatibiliteit."
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
                "Projectmappen worden per jaar en type geordend, losse documenten/foto's/audio worden gesorteerd " +
                "en opnieuw maakbare Final Cut render/proxy/analysebestanden worden verwijderd."
            )
        }
        .confirmationDialog(
            "Foto's snel comprimeren?",
            isPresented: $showPhotoConfirm,
            titleVisibility: .visible
        ) {
            Button("Start FOTO TURBO", role: .destructive) {
                model.startPhotoCompressionOnly()
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(
                "JPEG- en HEIC-foto's worden parallel opnieuw gecomprimeerd. De pixelresolutie blijft gelijk; " +
                "foto's die nauwelijks kleiner worden blijven onaangeraakt."
            )
        }
        .confirmationDialog(
            "EXTREME ONE CLICK starten?",
            isPresented: $showExtremeConfirm,
            titleVisibility: .visible
        ) {
            Button("JA — ruim deze schijf op", role: .destructive) {
                model.startExtremeOneClick()
            }

            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(
                "De app verwijdert opnieuw maakbare Final Cut render/proxy/analysebestanden, " +
                "comprimeert geschikte video's agressief met behoud van resolutie, " +
                "controleert eerst automatisch enkele FCP-clips en ordent daarna projecten en losse bestanden in ARCHIEF_GESORTEERD. " +
                "Bestanden die niet veilig verwerkt kunnen worden blijven staan."
            )
        }
        .confirmationDialog(
            "Hele batch starten?",
            isPresented: $showFullBatchConfirm,
            titleVisibility: .visible
        ) {
            Button("Start hele batch", role: .destructive) {
                model.startFullBatch()
            }

            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(
                "De gecomprimeerde clips worden actief, maar de originele bestanden blijven als herstelbackup staan. " +
                "Verwijder die backups pas nadat je de library in Final Cut hebt gecontroleerd."
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
                        icon: "bolt.fill",
                        title: "NITRO MAX",
                        subtitle: "Alleen video's. Directe VideoToolbox hardware-HEVC, speed-priority, agressieve bitrate en interne SSD als tijdelijke werkruimte.",
                        buttonTitle: "START NITRO MAX",
                        prominent: true
                    ) {
                        showNitroConfirm = true
                    }
                    .disabled(
                        model.sourceURL == nil ||
                        model.isRunning ||
                        model.isScanning ||
                        model.finalCutIsRunning
                    )

                    OperationTile(
                        icon: "folder.badge.gearshape",
                        title: "OPRUIMEN",
                        subtitle: "Geen video-encode. Projecten per jaar/type, documenten/screenshots/audio sorteren en FCP-cache verwijderen.",
                        buttonTitle: "RUIM & SORTEER"
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
                        icon: "photo.stack.fill",
                        title: "FOTO TURBO",
                        subtitle: "JPEG/HEIC parallel kleiner maken. Zelfde pixelresolutie; vooral bedoeld voor grote losse fotoarchieven.",
                        buttonTitle: "COMPRESS FOTO'S"
                    ) {
                        showPhotoConfirm = true
                    }
                    .disabled(
                        model.sourceURL == nil ||
                        model.isRunning ||
                        model.isScanning
                    )
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Alles liever automatisch achter elkaar?")
                            .font(.subheadline.weight(.semibold))

                        Text(
                            "De bestaande One Click-modus combineert video-compressie + opruimen/sorteren."
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("ALLES IN ÉÉN") {
                        showExtremeConfirm = true
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
                } else if let summary = model.extremeSummary {
                    Divider()

                    Label(summary, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(.green)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Label(
                    "Snelheidswinst: NITRO encodeert via Apple's hardware-encoder en schrijft tijdelijke videodata naar de interne Mac-schijf in plaats van tegelijk te lezen én schrijven op dezelfde externe HDD.",
                    systemImage: "speedometer"
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        } label: {
            Label(
                "Snelle functies",
                systemImage: "bolt.horizontal.circle.fill"
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
