# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Baseline import of the HoTH iOS app (built before Oct 26, 2026): live-camera reporting, bilingual voice intake, explained priority with safety floors, neighbourhood feed and map, confirmations, moderated comments, nearby alerts, crew fix verification, on-device face and plate blur, and the offline eval harness.
- `MetaModelClient.transcribe(wav:model:languageHint:keywords:)` for Muse Voice Transcribe file mode (multipart `request` JSON + `audio` WAV, PUSH_TO_TALK, language and keyword biasing).
- `MetaModelClient.segment(image:concept:model:)` for SAM 3.1 concept segmentation, with `SAMOutputParser` for its box/mask token text (boxes in source pixels, optional confidence, masks kept encoded).

### Changed
- AI client is now `MetaModelClient` on the Meta Model API (`https://api.meta.ai/v1`): 60 s timeout, configurable reasoning effort (default low), no image `detail`, provider-neutral `ModelAPIError`, and error bodies scrubbed of `LLM_…` keys.

### Removed
- OpenAI Realtime (WebRTC) voice interview; the interview runs as text until the Meta push-to-talk voice lands.
