# Meta models in HoTH

HoTH calls three Meta models through the Meta Model API at `https://api.meta.ai/v1`. Everything goes through one client in `HoTHCore`:

| File | Endpoint | Model |
|---|---|---|
| `ios/Packages/HoTHCore/Sources/HoTHCore/MetaModelClient.swift` | `POST /v1/responses` (structured output) | `muse-spark-1.3` |
| `ios/Packages/HoTHCore/Sources/HoTHCore/MetaModelClient+Tools.swift` | `POST /v1/responses` (function tools) | `muse-spark-1.3` |
| `ios/Packages/HoTHCore/Sources/HoTHCore/MetaModelClient+Segment.swift` | `POST /v1/responses` (SAM) | `sam-3.1` |
| `ios/Packages/HoTHCore/Sources/HoTHCore/MetaModelClient+Transcribe.swift` | `POST /v1/asr/transcribe` (multipart) | `muse-voice-transcribe-1.0` |

Common transport (`MetaModelClient.send`):

- `Authorization: Bearer <key>`. The key is fetched from the Keychain at call time.
- 60 s request timeout.
- 401 maps to `invalidKey`, 429 to `rateLimited`, and other non-2xx codes to `http(code, message)` with the message scrubbed of the key, `LLM_…`, `sk-…` and `Bearer …` tokens and cut to 200 characters.
- A cancelled task throws `CancellationError`.

## prompts.json

`ios/HoTH/Resources/prompts.json` is the single source of prompts for the app and for `tools/eval`. It is decoded by `Prompts.swift`.

| Key | Contents |
|---|---|
| `models` | `vision` and `text` (`muse-spark-1.3`), `transcribe` (`muse-voice-transcribe-1.0`), `segment` (`sam-3.1`) |
| `categories`, `severity_levels` | The 10 report categories and `low` / `medium` / `high` / `critical` |
| `segment_concepts` | One SAM noun phrase per category: `pothole`, `exposed cable`, `manhole`, `garbage` and so on. `other` and `not_an_issue` have none, so they make no SAM call. |
| `segment_concepts_ar` | Arabic display names for those concepts. These are for the UI only; SAM always gets the English concept. |
| `shared_rules` | Rules common to every prompt: describe only what is visible, never identify people, and so on |
| `vision_analyze` | System prompt, user template and strict schema `vision_analysis` |
| `fix_verify` | Schema `fix_verification` |
| `same_issue` | Schema `same_issue_check` |
| `moderation` | Schema `comment_moderation` |
| `slots` | Up to two interview questions per category in en and ar. Some are marked `urgent_if` (for example `children_using_now: yes`). |
| `chat_intake` | Interview system prompt. Its output schema `chat_turn` is defined in `ChatIntakeModel.swift`. |
| `intake_agent` | Extra tool rules for the agent, `max_tool_rounds` (4) and the three function tools |

Templates use `{{name}}` placeholders (`Prompts.fill`). Schemas avoid `minimum`, `maximum` and `maxItems`; the app clamps values in Swift instead.

## Muse Spark: structured calls

`MetaModelClient.structured(model:system:user:images:schema:as:)` sends:

```json
{
  "model": "muse-spark-1.3",
  "store": false,
  "input": [
    {"role": "system", "content": [{"type": "input_text", "text": "<system prompt>"}]},
    {"role": "user", "content": [
      {"type": "input_text", "text": "<filled user template>"},
      {"type": "input_image", "image_url": "data:image/jpeg;base64,..."}
    ]}
  ],
  "text": {"format": {"type": "json_schema", "name": "vision_analysis", "strict": true, "schema": {}}},
  "reasoning": {"effort": "low"}
}
```

The response is read by walking `output[] → message → content[] → output_text`, then decoding into the Swift type. A `refusal` part throws `refused`, and `status: "incomplete"` throws `incomplete(reason)`.

| Use | Caller | Images | Output (required fields) |
|---|---|---|---|
| Photo analysis | `VisionAnalyzer` | 1 (blurred, ≤ 1024 px, JPEG q0.82) | `category`, `title_en/ar`, `description_en/ar`, `hazards[]` (`label`, `label_ar`, `kind`, `box`), `child_use_equipment`, `child_present`, `scene_type`, `severity_proposal`, `severity_reason_en/ar`, `plausibility{}`, `suggested_questions[]`, `confidence` |
| Duplicate judge | `DuplicateJudge` | 2 (new and existing, both blurred) | `same_issue`, `reason` |
| Fix check | `FixVerifier` | 2 (before and after, both blurred) | `resolved`, `reason_en/ar`, `remaining_issues[]`, `same_location_likely` |
| Comment moderation | `ModelCommentModerator` | 0 | `decision` (allow or block), `reason` |
| Single-turn interview | `ChatIntakeModel` | 0 | `chat_turn` (see below) |

**Boxes.** Muse Spark returns hazard boxes as integer `x_min, y_min, x_max, y_max` on a 0–1000 grid over the image. `NormalizedBox` in `Schemas.swift` is the one place that grid is converted to 0…1.

**Vision user template.** The template carries the capture time, a place hint and the resident's language. The place hint is the GPS position rounded to 3 decimals with its accuracy (`placeHint(for:)` in `ReportFlowModel.swift`).

## Muse Spark: the intake agent (tool calling)

The interview is a tool-calling agent when a key is set and the "Interview agent tools" setting is on (the default). Code: `ChatIntakeModel.swift`, `IntakeTools.swift`, `MetaModelClient+Tools.swift`.

**Request.** `MetaModelClient.respond(model:input:tools:schema:)` sends:

- `store: false` and `include: ["reasoning.encrypted_content"]`. This is stateless replay: the whole input is resent every round, and `previous_response_id` is never used.
- `tools`: flat function tools (`type`, `name`, `description`, `parameters`), sent without `strict`.
- The `chat_turn` json_schema as `text.format`.
- No `tool_choice` field, so the default (`auto`) applies.

**Loop.** `ToolLoop.run` handles each round:

- Every `function_call` output item gets exactly one `function_call_output`, including unknown tools and bad arguments, which get an error JSON.
- Output items are replayed verbatim on the next round.
- After `max_tool_rounds` (4) the loop returns `roundLimit`.
- It checks for cancellation between rounds.

**Tools** (definitions in `prompts.json` `intake_agent.tools`; they run on the phone):

| Tool | Arguments | What the app does |
|---|---|---|
| `find_nearby_reports` | `radius_m` (integer) | Clamps the radius to 10…500 m and returns up to 5 open or in-progress reports from SwiftData, nearest first: id, category, titles, distance, confirmations, status. No reporter, comments or photos. Only ids returned here can later be confirmed from the chat. |
| `segment_hazard` | `concept` (string) | Checks the phrase with `HazardSegmenter.sanitizedConcept` (≤ 4 words, ≤ 40 characters, letters, digits, spaces, `-` and `'`), then runs SAM 3.1 on the blurred analysis photo. Returns a count and 0–1 boxes. Each concept runs at most once per report. Left out when there is no SAM outliner. |
| `get_place_context` | none | Returns the MapKit point of interest within 100 m (or `none_found`), the scene type and `child_use_equipment` from the vision analysis. |

**Output schema `chat_turn`** (strict): `reply`, `done`, `urgent`, `urgent_reason`, `summary_en`, `summary_ar`, `answers[]` (`id`, `answer`), `user_language`, `wants_to_post`, `anonymous`, `confirm_report_id`.

There is no priority field. Answers go through `PriorityAgent`, so the safety floors stay authoritative.

**Fallbacks:**

| What went wrong | What the interview does |
|---|---|
| HTTP 400 or an undecodable turn | Tools are switched off for the session and the turn is retried single-turn. |
| Round limit | That turn finishes single-turn, with the tool results in the prompt. |
| Key, billing, rate-limit or network error | Switches to the deterministic local chat, which asks the category's slot questions, reads back and asks about posting. |

Across turns, earlier tool results are resent as text ("Tool results so far"), so the agent does not call them again.

## SAM 3.1

`MetaModelClient.segment(image:concept:model:includeConfidence:)` sends one concept per request. There is no system prompt, reasoning or `text.format`:

```json
{
  "model": "sam-3.1",
  "input": [{"type": "message", "role": "user", "content": [
    {"type": "input_text", "text": "pothole"},
    {"type": "input_image", "image_url": "data:image/jpeg;base64,..."}
  ]}],
  "metadata": {"include_confidence": "true", "mask_encoding": "one_bit"}
}
```

**Response.** SAM's output text uses special tokens, one line per frame:

```
<0f>12<|box;x1=..;y1=..;x2=..;y2=..;w=..;h=..;c=..|><|mask;...;data=H,W,!payload|>,13<|box;...|>...
```

`SAMOutputParser` reads it into `SegmentedInstance`: object id, frame, a `PixelBox` in source pixels, an optional score, and the mask kept encoded. A completed response with no text means zero matches. Malformed records are skipped.

**Selection** (`SegmentSelection` in `HazardSegmenter.swift`) keeps up to 3 boxes, best score first. It drops:

- boxes scoring below 0.25
- boxes smaller than 0.05% of the image
- boxes whose `w`/`h` does not match the JPEG that was sent (2% tolerance)

**Where it is used:**

- The analysis card and ticket, as dashed overlays with an "Outlined by SAM 3.1" chip.
- The intake agent's `segment_hazard` tool.
- Rejected fix checks: SAM boxes replace Muse Spark's `remaining_issues` boxes when SAM finds something.

**Budget and limits:**

- `HazardSegmenter` gives each call 20 s. A timeout or error just leaves no overlay, and the report never waits for SAM.
- Masks are requested but not decoded or drawn. Only boxes are used.

## Muse Voice Transcribe

`MetaModelClient.transcribe(wav:model:languageHint:keywords:)` sends `POST /v1/asr/transcribe` as `multipart/form-data` with two parts.

`request` (JSON):

```json
{"audioEncoding": "WAV", "languageBias": ["Arabic", "English"], "mode": "PUSH_TO_TALK", "model": "muse-voice-transcribe-1.0"}
```

An Arabic hint sends `["Arabic", "English"]` (residents often code-switch). An English hint sends `["English"]`. An unknown hint omits the field. The client also supports `keywords`, but the app does not send any today.

`audio`: `audio.wav`, `audio/wav`.

Response: `{sessionId, transcript, audioDurationMs, turns[]}`. Only `transcript` is required.

**Audio format:**

- `AVAudioRecorder` records 24 kHz mono 16-bit PCM WAV (`PushToTalkAudio.swift`).
- `WAVAudio.canonicalPCM16` rewrites it to a plain 44-byte-header file, dropping padding chunks such as `FLLR`. It rejects anything other than mono 16-bit at 16 or 24 kHz.
- Clips shorter than 400 ms are not sent. A hold is capped at 60 s.
- The temp file is deleted after upload.

**Spoken replies** use `AVSpeechSynthesizer` on the device (`ar-SA` or `en-US`). Meta offers no TTS model.

## Live checks

`ios/Packages/HoTHCore/Tests/HoTHCoreTests/LiveMetaTests.swift` has 10 opt-in tests that hit the real API through the real client:

- `GET /v1/models`
- vision analysis
- fix verify, accept and reject
- duplicate judge
- moderation
- English and Arabic transcription on `say`-generated WAVs
- SAM boxes
- a tool-calling round trip

They are skipped unless `META_API_KEY` is set:

```bash
cd ios/Packages/HoTHCore
META_API_KEY=... swift test --filter LiveMetaTests
```
