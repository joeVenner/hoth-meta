# Privacy and safety

HoTH asks residents to photograph public spaces and talk about them, and those photos often include bystanders and cars. This page covers what the app does to protect people, what still leaves the phone, and where the protections stop.

## On-device blur, before any upload

Code: `ios/HoTH/Privacy/FaceAndPlateBlur.swift`.

**Detection.** Apple Vision runs on the phone and looks for two things:

- faces, with `VNDetectFaceRectanglesRequest`
- plate-like text, with `VNRecognizeTextRequest`. A text box counts as plate-like when all of these hold:
  - it is wide and short (aspect 1.5–6.5)
  - it is small (0.02%–5% of the image)
  - it has 2–10 characters, mostly alphanumeric, with at least one digit

**Blur.** Each detected region is padded and covered with a blur plus pixellation. The rest of the image is left untouched.

**Every Meta upload uses the blurred JPEG.** `FaceAndPlateBlur.redactForUpload` produces it for:

- vision analysis
- the SAM 3.1 outline
- both photos in the duplicate judge. The existing report's public photo is blurred again before it is sent.
- the intake agent's `segment_hazard` tool
- the fix check, before and after photos

**Fail closed.** If detection or rendering fails, or the blur takes longer than 10 s (`FaceAndPlateBlur.uploadTimeout`), nothing is sent:

- The report shows "I couldn't blur faces and number plates on this photo, so it wasn't sent. Please take it again."
- The fix check shows "Couldn't blur faces and number plates on these photos, so nothing was sent."

Both messages exist in English and Arabic.

**Posting.** The feed only ever shows the blurred photo. The original stays on the phone, for the resident's own ticket.

**Proof in tests.** `ios/HoTHTests/UploadRedactionTests.swift` checks that every image in every Meta request is an output of the redactor and never the original's bytes. It also checks that a failed redaction makes no request, and that the 10 s timeout fails closed.

In DEBUG capture mode, `UploadAudit` logs each redaction and each photo-carrying request with random ids. Images and keys are never logged.

**Limits:**

- Detection can miss faces and plates (angle, distance, partial occlusion, unusual plates). The app's privacy copy says "faces and plates your phone detects".
- Blur latency has been measured only on the simulator (0.21–0.38 s on the spring rider photo), not yet on a real iPhone.
- Offline canned demo analyses send nothing, so they skip the upload blur.

## What leaves the phone

| Data | Sent to | When |
|---|---|---|
| Blurred photo (≤ 1024 px JPEG) | Meta Model API (Muse Spark, SAM 3.1) | Analysis, outline, duplicate judge, agent `segment_hazard`, fix check |
| Approximate GPS: lat and lon rounded to 3 decimals, plus accuracy | Muse Spark | In the vision prompt's place hint |
| Interview text: typed or transcribed answers, report summary, nearby-report titles and distances | Muse Spark | Each interview turn |
| Voice clip (WAV, unredacted audio) | Muse Voice Transcribe | Each push-to-talk turn. The temp file is deleted after upload. |
| Comment text and report title | Muse Spark | Moderating a comment when a key is set |
| Coordinates for a point-of-interest search | Apple MapKit | Child-relevant place lookup (100 m). Not in demo mode or on the simulator. |

**What the requests set.** Muse Spark structured calls and the agent's tool rounds set `store: false` on the request. SAM and transcription requests have no such field. This page describes only what the app sends. How Meta handles that data is governed by Meta's own terms.

**What stays on the phone.** All reports, comments, votes and points live in local SwiftData. There is no HoTH server, and nothing is shared with other users' devices.

## Live camera only

- Reporting offers only the live camera. There is no photo-library picker.
- Bundled demo photos are accepted only in demo mode, or on a device with no camera, such as the simulator.
- `Plausibility.evaluate` (`ios/Packages/HoTHCore/Sources/HoTHCore/Plausibility.swift`) adds deterministic checks:

| Check | Result |
|---|---|
| Library photo outside demo mode | rejected |
| Capture time more than 2 minutes old, or more than 60 s in the future | retake |
| No GPS fix | rejected |
| GPS accuracy worse than 100 m | retake |
| Muse Spark flags screen or print, or stock or watermark | retake |
| No visible neighbourhood issue | retake |

These checks are best-effort signals, not proof that a photo is real. The design goal is to make fraud expensive and obvious, not impossible.

## Safety floors

Code: `ios/Packages/HoTHCore/Sources/HoTHCore/PriorityAgent.swift`.

Muse Spark proposes a severity. `PriorityAgent.decide` then applies deterministic floors, and the final level is the highest of the proposal, the strongest floor and the score band. **Floors can only raise the level, never lower it.**

| Condition | Floor |
|---|---|
| Child-use equipment (swing, slide, spring rider…) with a sharp edge or fall hazard | **HIGH** |
| … plus child context: playground or school location, a child in the photo, or "children using it now" | **CRITICAL** ("CRITICAL — child safety") |
| Category `open_manhole` | **CRITICAL** |
| Electrical hazard (category or hazard kind) | **HIGH** |
| … plus child context, sparking, or water nearby | **CRITICAL** |

**Inputs to the decision:**

- The location type comes from a MapKit point of interest within ~100 m, or else the scene Muse Spark described.
- Interview answers such as `children_using_now: yes` or `sparking: yes` re-run the decision before the ticket is made.
- Confirmations add score (6 points each, capped at 30).

Every factor becomes a chip under "Why this priority", in English and Arabic. The floor that set the level, if any, is named.

**Guarantees and limits:**

- The intake agent's output schema has no priority field, so the model cannot write a priority directly.
- The floors depend on Muse Spark's category and hazard kinds. If the model calls a photo `not_an_issue`, the report stays LOW and is flagged for review, and no floor fires. That is the main failure mode in the eval (see [evaluation.md](evaluation.md)).

## Safety sheet and urgent answers

A safety sheet with advice appears before the interview when the priority is CRITICAL and the photo shows one of these:

- an open manhole
- an electrical hazard
- a child on broken child equipment

During the interview, an urgent answer has the same effect. Urgent answers include "children using it now" on child equipment, and sparking or water near an electrical hazard. The priority is recomputed, the interview stops, and the ticket appears behind the safety sheet.

## Comment moderation

Code: `ios/HoTH/Features/Feed/CommentModeration.swift`.

1. **Local checks run first, always.** They block e-mail addresses and phone numbers of 8 or more digits, including Arabic-Indic digits, plus a short list of unambiguous insults in English and Arabic.
2. **Then Muse Spark,** when a key is set. It runs the `moderation` prompt and returns allow or block with a reason.
3. **On any API error,** the local verdict stands, which means allow if the local checks passed.

## API key handling

- The Meta key is typed into Settings and stored in the iOS Keychain:
  - service `HoTH.MetaKey`
  - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it does not sync to other devices or move to backups restored on another device
- The UI only ever shows `••••` plus the last four characters.
- No key is bundled in the app or committed to the repo.
- DEBUG simulator builds can read `META_API_KEY` from the scheme environment.
- "Reset app and remove Meta API key" deletes the key.
- `ModelAPIError` never carries the key, and error bodies are scrubbed before they are logged or shown.
