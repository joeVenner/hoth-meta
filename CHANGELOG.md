# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Baseline import of the HoTH iOS app (built before Oct 26, 2026): live-camera reporting, bilingual voice intake, explained priority with safety floors, neighbourhood feed and map, confirmations, moderated comments, nearby alerts, crew fix verification, on-device face and plate blur, and the offline eval harness.
- `MetaModelClient.transcribe(wav:model:languageHint:keywords:)` for Muse Voice Transcribe file mode (multipart `request` JSON + `audio` WAV, PUSH_TO_TALK, language and keyword biasing).
- `MetaModelClient.segment(image:concept:model:)` for SAM 3.1 concept segmentation, with `SAMOutputParser` for its box/mask token text (boxes in source pixels, optional confidence, masks kept encoded).
- `WAVAudio.canonicalPCM16(_:)` rewrites a recorded WAV to a 44-byte-header mono 16-bit PCM file (drops padding chunks such as `FLLR`) and rejects formats Muse Voice Transcribe refuses.
- Push-to-talk voice (`PushToTalkModel`): hold or tap the mic, record 24 kHz mono 16-bit WAV with `AVAudioRecorder` (temp file deleted after upload), transcribe with Muse Voice Transcribe, and read each reply aloud with `AVSpeechSynthesizer` in the reply's language (ar-SA / en-US). Mic denial and recording or transcription errors fall back to typing.

### Changed
- AI client is now `MetaModelClient` on the Meta Model API (`https://api.meta.ai/v1`): 60 s timeout, configurable reasoning effort (default low), no image `detail`, provider-neutral `ModelAPIError`, and error bodies scrubbed of `LLM_…` keys.
- prompts.json targets Meta models (`muse-spark-1.3` for vision and text, `muse-voice-transcribe-1.0`, `sam-3.1`). Schemas drop `minimum`/`maximum`/`maxItems` (clamped in Swift) and boxes use Muse Spark's 0-1000 grid, normalized once in `NormalizedBox`.
- App wiring and copy name Meta: the key is stored under Keychain service `HoTH.MetaKey` (DEBUG simulator falls back to `META_API_KEY`), Settings says "Meta Model API key" and Muse Spark with a new text model override for chat and moderation, and privacy copy (en + ar) says photos go to Meta's Muse Spark model. UI tests read `TEST_RUNNER_META_API_KEY`.
- Eval harness calls the Meta Model API (`META_API_KEY`, 60 s app timeout, reasoning effort low, no image `detail`) and prices runs at Muse Spark 1.3 Standard rates ($1.25 in, $0.15 cached in, $4.25 out per 1M tokens).

### Removed
- `realtime_tools` and `voice_persona` from prompts.json.
- The previous provider's realtime (WebRTC) voice interview; the interview runs as text until the Meta push-to-talk voice lands.
- The unused WebRTC Swift package from `ios/project.yml`.
