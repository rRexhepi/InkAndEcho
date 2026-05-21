# Ink and Echo

An audiobook + ebook sync reader. Plays an audiobook and its matching
ebook side-by-side, follows the narration with word- or sentence-level
highlighting, and lets you annotate freely.

Install instructions for end users live at
https://rrexhepi.github.io/ink-and-echo-app/

## Surfaces

Two source trees live in this repo. They share the alignment approach
and on-disk model but otherwise don't share code.

| Surface | Targets | Lives in |
|---|---|---|
| Apple (Catalyst) | iPhone, iPad, Mac | `App/` + `InkAndEchoCore/` + `InkAndEcho.xcodeproj` |
| Flutter port | Android, Windows, Linux | `xplatform/` |

The Apple build is the reference UI and is distributed via TestFlight.
The Flutter port has reached parity for the reader, audio, alignment,
and import paths.

## Apple build

Open the Xcode project and run the `InkAndEchoiOS` scheme:

```bash
open InkAndEcho.xcodeproj
```

Apple silicon and Intel both build. The app is sandboxed and ad-hoc
signed, so it runs without an Apple Developer Team. To regenerate
`InkAndEcho.xcodeproj` from `project.yml`:

```bash
brew install xcodegen
xcodegen generate
```

Core library tests:

```bash
cd InkAndEchoCore && swift test
```

## Flutter port

Cross-platform tree under `xplatform/`. Build for the local platform:

```bash
cd xplatform
flutter pub get
flutter build linux --release      # or: windows, apk
```

`xplatform/README.md` documents host prerequisites (ffmpeg, libmpv on
desktop; optional Calibre for PDF and KF8 conversion).

## Stack notes

- Word-level alignment is whisper.cpp on Apple and sherpa-onnx (ONNX
  Runtime, base.en quantised) on the Flutter port.
- Audio playback is AVAudioEngine on Apple, just_audio on Android, and
  just_audio_media_kit (libmpv) on Windows / Linux.
- EPUB import is implemented in-tree on both surfaces. MOBI on the
  Flutter port uses a bundled PalmDOC parser at
  `xplatform/lib/import/mobi_importer.dart`. PDF and other formats
  shell out to Calibre's `ebook-convert` on desktop; Android uses
  PDFBox via `read_pdf_text`.
- Annotations are anchored by paragraph index inside a spine itemref,
  so they survive re-import and re-pagination.

## Documents

- `DESIGN.md` UI conventions and reader-surface decisions.


## License

MIT. See `LICENSE`.
