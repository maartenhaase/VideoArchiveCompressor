# Video Archive Compressor

Native macOS-app voor het verkleinen van oude Final Cut Pro-media-archieven.

## Doel

Deze app is bedoeld voor oude `.fcpbundle`-libraries en archiefschijven waar de originele camera-kwaliteit niet meer nodig is, maar waar je de projecten later nog wel wilt kunnen openen.

- native SwiftUI-interface
- geen Python, Homebrew of FFmpeg
- gebruikt AVFoundation van macOS
- batchverwerking met zichtbare voortgang
- scant binnen Final Cut libraries alleen `Original Media`
- laat `Render Files`, `Transcoded Media` en `Analysis Files` met rust
- testmodus voor 3 clips met verborgen backup van het origineel
- nieuwe clip blijft op exact dezelfde locatie en met exact dezelfde bestandsnaam staan

## Aanbevolen workflow

1. Sluit Final Cut Pro.
2. Kies of sleep een `.fcpbundle`, map of harde schijf in de app.
3. Kies **Tiny HD** voor maximaal 1080p HEVC.
4. Klik **TEST 3 CLIPS**.
5. Open daarna de library in Final Cut Pro en controleer de drie clips.
6. Als alles goed werkt, start de hele batch.

## Ondersteunde bestanden

Voor veilige in-place vervanging worden voorlopig automatisch verwerkt:

- `.mov`
- `.mp4`
- `.m4v`

MTS, M2TS, MXF, AVI en symlinks worden bewust overgeslagen.

## Build

De GitHub Actions-workflow bouwt bij iedere push automatisch een macOS Release-build en maakt daarvan een ZIP-artifact.

De GitHub-build is niet genotariseerd met een Apple Developer-certificaat. Bij de eerste keer openen kan macOS daarom vragen om via **rechtsklik → Open** toestemming te geven.
