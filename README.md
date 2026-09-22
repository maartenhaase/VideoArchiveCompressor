# Video Archive Compressor

## NITRO MAX

De snelste videomodus gebruikt nu rechtstreeks Apple's **VideoToolbox `VTCompressionSession`** in plaats van AVAssetWriter de encoder te laten kiezen. Hardware-HEVC wordt eerst verplicht aangevraagd, speed-priority en realtime encoding staan aan, frame-reordering staat uit en tijdelijke encode-data gaat naar de interne Mac-schijf. Daarna worden originele audio en QuickTime-timecode teruggezet voor Final Cut-compatibiliteit.


Native macOS-app om oude videodrives en Final Cut Pro-archieven **kleiner én opgeruimd** te maken.

## EXTREME ONE CLICK

Kies een hele externe harde schijf of hoofdmap en druk op **RUIM ALLES OP**.

De app doet daarna automatisch:

1. Final Cut `Render Files`, `Transcoded Media` en `Analysis Files` verwijderen.
2. Geschikte video's comprimeren naar HEVC.
3. Bij MOV-camera-originals de originele resolutie behouden met een agressieve archiefbitrate.
4. Originele audio en QuickTime-timecode bewaren voor Final Cut relinking.
5. Projectmappen en FCP libraries herkennen.
6. Projecten indelen op **jaar + soort**.
7. Losse documenten, screenshots, foto's, audio, archieven en overige bestanden sorteren.
8. Lege, achtergebleven mapjes opruimen.

De eerste echte videoconversies vormen automatisch een veiligheidstest. Een clip wordt pas vervangen nadat framerate, duur, audiotracks/audiokanalen en timecode technisch zijn gecontroleerd.

## Automatische mappenstructuur

Voorbeeld:

```text
ARCHIEF_GESORTEERD/
├── 2025/
│   ├── Projecten/
│   │   ├── Trouwfilms/
│   │   ├── Bedrijfsfilms - Groot/
│   │   ├── Bedrijfsfilms - Klein/
│   │   ├── Persoonlijk/
│   │   ├── Overig - Groot/
│   │   └── Overig - Klein/
│   ├── Documenten/
│   │   ├── PDF/
│   │   ├── Tekstdocumenten/
│   │   ├── Spreadsheets/
│   │   └── Presentaties/
│   ├── Afbeeldingen/
│   │   ├── Schermafbeeldingen/
│   │   ├── Foto's/
│   │   └── RAW/
│   ├── Video/
│   ├── Audio/
│   ├── Creatief/
│   ├── Archieven & ZIP/
│   ├── Installatiebestanden/
│   └── Overig/
└── 2024/
    └── ...
```

Bestanden met **schermafbeelding**, **screenshot** of **screen shot** in de bestandsnaam komen automatisch in `Afbeeldingen/Schermafbeeldingen`.

## Projecten blijven intact

De organizer haalt documenten, logo's of andere bestanden **niet uit herkende videoprojecten**. Een projectmap wordt als één geheel verplaatst.

Een `.fcpbundle` blijft eveneens één bestand/package.

Final Cut-libraries of projectmappen met extern gelinkte/alias-media worden uit voorzorg niet automatisch verplaatst.

## Final Cut compatibiliteit

Binnen een `.fcpbundle` verwerkt de compressor alleen `Original Media`.

De app bewaart bij MOV-camera-originals:
- bestandsnaam en pad tijdens compressie;
- resolutie;
- framerate;
- oorspronkelijke audiotracks en kanaalindeling;
- oorspronkelijke QuickTime timecode-track.

Daardoor blijft de oorspronkelijke media-range beschikbaar voor Final Cut.

## Ondersteunde video voor automatische vervanging

Momenteel:
- `.mov`
- `.mp4`
- `.m4v`

MTS, M2TS, MXF, AVI en externe/symlinked media worden gerapporteerd maar bewust niet destructief vervangen.

## Handmatige FCP-modus

Voor één belangrijke library kun je nog steeds:
1. **TEST 3 CLIPS**
2. de library openen in Final Cut;
3. daarna **START HELE BATCH** gebruiken.

## Build

De app is volledig native SwiftUI + AVFoundation.

Geen Python.  
Geen Homebrew.  
Geen FFmpeg.

GitHub Actions bouwt bij iedere push automatisch de macOS-app en publiceert de nieuwste geslaagde build als GitHub Release.

De build is niet genotariseerd met een betaald Apple Developer-certificaat. macOS kan daarom bij de eerste start vragen om **rechtsklik → Open**.
