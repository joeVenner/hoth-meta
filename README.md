# HoTH: Heroes of the Hay (حيّ · Hay = neighbourhood)

HoTH is a neighbourhood social network for reporting unsafe public spaces. A resident takes a live photo of a hazard (a broken playground spring rider, an open manhole, a pothole), talks to an AI assistant in Arabic or English, and gets a structured, prioritised ticket in about a minute. Neighbours confirm it ("I saw it too"), comment on it, and celebrate the fix once a crew's before/after photo pair is verified.

> **Status:** being adapted to Meta's models (Muse Spark, Muse Voice Transcribe, SAM 3.1). Until that lands, the app still calls its previous provider. See [CHANGELOG.md](CHANGELOG.md).

## Features

- **Live-camera-only capture.** No photo-library picker; photos are stamped with GPS and time on the device.
- **Voice-first, bilingual intake.** Arabic (including Khaleeji) or English, at most two short questions, then a read-back.
- **Explained priority.** Every ticket shows why it is ranked where it is. Deterministic safety floors in `HoTHCore` mean child-safety hazards are never ranked below CRITICAL, whatever the model says.
- **Neighbourhood layer.** Feed and map, "I saw it too" confirmations, moderated comments, nearby-hazard alerts, reputation levels.
- **Verified fixes.** A case closes only when the before/after pair is accepted.
- **Privacy.** Faces and licence plates the phone detects are blurred on device before any upload (detection can miss some); the photo posted to the feed is always the blurred one.

## Meta adaptation (in progress)

| Feature | Meta model |
|---|---|
| Photo analysis, intake agent, duplicate check, fix check, comment moderation | Muse Spark 1.3 (vision, structured output, tool calling) |
| Push-to-talk speech-to-text (Arabic, English) | Muse Voice Transcribe |
| Hazard outline on the report, "what's left" on fix check | SAM 3.1 |
| Spoken replies | On-device `AVSpeechSynthesizer` |

## Project layout

| Path | What |
|---|---|
| `ios/HoTH/` | SwiftUI + SwiftData app (iOS 17+) |
| `ios/Packages/HoTHCore/` | Pure Swift logic: priority floors, plausibility, dedup, rewards, AI client and schemas |
| `ios/HoTH/Resources/prompts.json` | All prompts, JSON schemas and model ids |
| `ios/HoTHTests/`, `ios/HoTHUITests/` | App unit and UI tests |
| `tools/eval/` | Offline eval of the app's prompts on a labelled image set |

## Build and test

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
make gen     # generate ios/HoTH.xcodeproj
make build   # build for the simulator
make test    # run app unit + UI tests on the first available iPhone simulator
cd ios/Packages/HoTHCore && swift test   # core logic tests
```

API keys are entered in the app's Settings and stored in the iOS Keychain. No key is bundled in the app or committed to this repo. Demo mode (on by default in Settings) adds bundled sample photos for walkthroughs.

## Credits

Image sources and licences: [ios/HoTH/Resources/IMAGE_CREDITS.md](ios/HoTH/Resources/IMAGE_CREDITS.md) and [tools/eval/dataset/ATTRIBUTION.md](tools/eval/dataset/ATTRIBUTION.md).
