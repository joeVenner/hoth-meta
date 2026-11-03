# Development

## Setup

| Need | Notes |
|---|---|
| macOS + Xcode 26 | Deployment target is iOS 17.0 (`ios/project.yml`). |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | Generates `ios/HoTH.xcodeproj`, which is gitignored. |
| An iPhone simulator runtime | Needed for `make test`. |
| [uv](https://docs.astral.sh/uv/) (optional) | Only for the Python eval in `tools/eval/`. |

```bash
make gen     # cd ios && xcodegen generate
make build   # simulator build into build/DerivedData
make test    # unit + UI tests on the first available iPhone simulator (override: make test SIM_ID=<udid>)
make clean   # remove build/DerivedData and the generated project
```

To run on a device, open `ios/HoTH.xcodeproj` and set your development team under Signing. `DEVELOPMENT_TEAM` is empty in `project.yml`.

**API key.** Paste the key in **Settings → Meta Model API key**, where it is saved to the Keychain. For simulator runs you can instead set `META_API_KEY` in the scheme's environment, which DEBUG simulator builds only. Never commit a key.

## Tests

| Suite | Command | Last observed |
|---|---|---|
| HoTHCore (pure Swift) | `cd ios/Packages/HoTHCore && swift test` | 159 tests, 0 failures, 10 skipped (`LiveMetaTests`, opt-in) |
| App unit tests (`ios/HoTHTests/`) | `make test` | 187 tests, 1 skipped |
| UI tests (`ios/HoTHUITests/`) | `make test` | pass. `DemoCaptureUITests` (4 scenes) are opt-in. |
| Eval metric tests | `cd tools/eval && uv run pytest` | No network |

### Notable test files

| File | What it covers |
|---|---|
| `UploadRedactionTests` | Every image in every Meta request is the redactor's output. Failed redaction makes no request. 10 s timeout. |
| `IntakeAgentTests` | Tool loop, fallbacks, confirm-from-chat |
| `SAMOutlineTests` | Overlay selection and wiring |
| `PushToTalkTests` | Voice states and turns |
| `GoldenPathUITests` | Spring-rider report from photo to ticket |
| `CrewUITests` | Fix check: reject, then accept |
| `CommentComposerUITests` | Posting a comment with the keyboard up, in English and Arabic |
| `PriorityAgentTests`, `PlausibilityTests`, `DedupTests` (HoTHCore) | The deterministic rules |
| `MetaModelClientTests` (HoTHCore) | Request bodies and response parsing against recorded fixtures in `Tests/HoTHCoreTests/Resources/` |

### Live (paid) tests

These are off by default and need a key:

```bash
# HoTHCore: every Meta integration through the real client
cd ios/Packages/HoTHCore && META_API_KEY=... swift test --filter LiveMetaTests
```

`LiveRedactedVisionTests` (app) runs the spring rider photo through the blurred upload path several times. It needs `TEST_RUNNER_HOTH_LIVE_REDACTED=1` and `TEST_RUNNER_META_API_KEY`, with optional `TEST_RUNNER_HOTH_LIVE_RUNS` (default 5) and `TEST_RUNNER_HOTH_LIVE_OUT`.

## Test hooks

All of these are launch environment variables read only in **DEBUG** builds. Release builds ignore them.

| Variable | Effect |
|---|---|
| `HOTH_UITEST=1` | In-memory store, no splash, local typed chat interview, no SAM, push-to-talk or agent tools. Repeatable UI tests that make at most one live call (vision). |
| `HOTH_DEMO_CAPTURE=1` | Demo-film capture mode: in-memory store reseeded every launch, confirmations and alert state cleared. Every live Meta path stays on. It never implies `HOTH_UITEST`. |
| `HOTH_CAPTURE_ONBOARDING=1` | In capture mode, also shows onboarding again. |
| `HOTH_CAPTURE_SKIP_SPLASH=1` | In capture mode, skips the splash. |
| `HOTH_PTT_WAV_DIR` | In capture mode, push-to-talk plays a validated WAV playlist instead of the microphone. The real clip still goes to Muse Voice Transcribe. |
| `HOTH_CAPTURE_LOG_DIR` | Where capture mode writes `hoth_app_log.jsonl`: tool calls, redaction and request audit. No image bytes or keys. |

UI tests pass values through `TEST_RUNNER_*` variables, for example `TEST_RUNNER_META_API_KEY`, `TEST_RUNNER_DEMO_CAPTURE=1` and `TEST_RUNNER_CAPTURE_LANG=en|ar`.

UI tests find elements by accessibility identifiers. Examples: `caseConfirmButton`, `commentField`, `commentSendButton`, `quickReply_<n>`, `chatBubble_assistant`, `chatBubble_resident`, `routedToTeam`.

## Conventions

**Code:**

- **Pure logic goes in HoTHCore.** Anything without UIKit, SwiftData or device APIs (rules, schemas, client) lives in `ios/Packages/HoTHCore` and is tested with `swift test`.
- **Prompts are data.** Prompts, schemas, tool definitions, SAM concepts and model ids live in `ios/HoTH/Resources/prompts.json`. Do not hard-code them in Swift. The `chat_turn` schema is the exception: it lives in `ChatIntakeModel.swift`.
- **The model proposes, rules decide.** Priority, plausibility, dedup radius and rewards are deterministic Swift. Model output is untrusted, so tool arguments are clamped or refused.
- **Fail closed on privacy.** No photo goes to Meta unless it came out of `FaceAndPlateBlur.redactForUpload`.
- **Bilingual.** User-facing strings are in `ios/HoTH/Resources/Localizable.xcstrings` (en and ar). Layout follows the language's direction, right to left for Arabic.
- **Seams are protocols** (`HazardOutlining`, `CommentModerator`, `FixVerifying`, `SpeechTranscribing`…), so tests inject fakes and make no network calls.

**Git:**

- Conventional Commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:` and so on.
- Work on branches, never on `main` directly.
- Record notable changes in [CHANGELOG.md](../CHANGELOG.md) under `[Unreleased]`.
