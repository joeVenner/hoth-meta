# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Baseline import of the HoTH iOS app (built before Oct 26, 2026): live-camera reporting, bilingual voice intake, explained priority with safety floors, neighbourhood feed and map, confirmations, moderated comments, nearby alerts, crew fix verification, on-device face and plate blur, and the offline eval harness.
- `MetaModelClient.transcribe(wav:model:languageHint:keywords:)` for Muse Voice Transcribe file mode (multipart `request` JSON + `audio` WAV, PUSH_TO_TALK, language and keyword biasing).
- `MetaModelClient.segment(image:concept:model:)` for SAM 3.1 concept segmentation, with `SAMOutputParser` for its box/mask token text (boxes in source pixels, optional confidence, masks kept encoded).
- `HazardSegmenter` outlines a report category with SAM 3.1: one noun phrase per category from prompts.json `segment_concepts` (none for `other` / `not_an_issue`), a 20 s budget (`Failure.timedOut`), and `SegmentSelection` keeping up to 3 boxes by score while dropping specks, low scores and boxes whose `w`/`h` aspect does not match the sent JPEG. `OverlayGeometry` maps 0...1 boxes into aspect-fit and aspect-fill views.
- `WAVAudio.canonicalPCM16(_:)` rewrites a recorded WAV to a 44-byte-header mono 16-bit PCM file (drops padding chunks such as `FLLR`) and rejects formats Muse Voice Transcribe refuses.
- Push-to-talk voice (`PushToTalkModel`): hold or tap the mic, record 24 kHz mono 16-bit WAV with `AVAudioRecorder` (temp file deleted after upload), transcribe with Muse Voice Transcribe, and read each reply aloud with `AVSpeechSynthesizer` in the reply's language (ar-SA / en-US). Mic denial and recording or transcription errors fall back to typing. The audio session (`.playAndRecord` + `.defaultToSpeaker`) is set up on the first spoken reply or press, so the opening reply is not muted by the silent switch.
- Report flow outlines the hazard with SAM 3.1: after a live Muse Spark analysis, the same JPEG goes to SAM with the category's concept, and up to 3 boxes draw in (dashed, teal glow) over the analysis photo and the ticket thumbnail, with an "Outlined by SAM 3.1" chip (en + ar). SAM runs alongside priority and dedup, is cancelled on retake or merge, and any failure or timeout just leaves no overlay. Offline canned analyses and UI tests make no SAM call, and no SAM results are bundled.
- Crew fix check shows SAM 3.1 "what's left" boxes on a rejected live verdict: SAM runs on the exact after JPEG the verifier saw with the report's concept, its boxes replace Muse Spark's `remaining_issues` when it finds something (with the SAM chip), and a timeout, error or zero matches keeps Spark's boxes. Canned demo verdicts make no SAM call.
- `MetaModelClient.respond(model:input:tools:schema:)` sends Muse Spark function tools over the Responses API with stateless encrypted reasoning replay (`store: false`, `include: ["reasoning.encrypted_content"]`), and `ToolLoop.run` pairs every `function_call` with a `function_call_output`, replays each round's output verbatim, caps tool rounds (default 4) and decodes the final json_schema answer.

### Changed
- The interview offers push-to-talk inside the chat when a Meta key is set: the orb shows listening, transcribing, thinking and speaking, "Type instead" and a mic button switch modes without losing the conversation, and "Start interview with voice" picks the starting mode (UI tests stay on the local typed chat). The Talk/Type picker is gone, and the Settings caption and en + ar strings describe the new voice.
- AI client is now `MetaModelClient` on the Meta Model API (`https://api.meta.ai/v1`): 60 s timeout, configurable reasoning effort (default low), no image `detail`, provider-neutral `ModelAPIError`, and error bodies scrubbed of `LLM_…` keys.
- prompts.json targets Meta models (`muse-spark-1.3` for vision and text, `muse-voice-transcribe-1.0`, `sam-3.1`). Schemas drop `minimum`/`maximum`/`maxItems` (clamped in Swift) and boxes use Muse Spark's 0-1000 grid, normalized once in `NormalizedBox`.
- App wiring and copy name Meta: the key is stored under Keychain service `HoTH.MetaKey` (DEBUG simulator falls back to `META_API_KEY`), Settings says "Meta Model API key" and Muse Spark with a new text model override for chat and moderation, and privacy copy (en + ar) says photos go to Meta's Muse Spark model. UI tests read `TEST_RUNNER_META_API_KEY`.
- Eval harness calls the Meta Model API (`META_API_KEY`, 60 s app timeout, reasoning effort low, no image `detail`) and prices runs at Muse Spark 1.3 Standard rates ($1.25 in, $0.15 cached in, $4.25 out per 1M tokens).

### Removed
- `realtime_tools` and `voice_persona` from prompts.json.
- The previous provider's realtime (WebRTC) voice interview, replaced by Meta push-to-talk.
- Localized strings left over from the realtime voice screens.
- The unused WebRTC Swift package from `ios/project.yml`.
- The realtime-only mid-call urgency path in `ReportFlowModel` (`voiceFlaggedUrgent`, `SafetyAlert.keepsInterview`, `urgentAnswers`); push-to-talk urgency goes through the chat like typing.

### Fixed
- Muse Spark's hazard boxes on the analysis photo are laid out left-to-right in Arabic too, like the SAM layer and the fix-check boxes, so the two never disagree under RTL.
- The repair photo is made upright and downsized to 1024 px before the fix check, so boxes from the model land on the shown image (camera shots arrive `.right`-oriented at full resolution).
