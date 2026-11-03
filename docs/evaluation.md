# Evaluation

`tools/eval/` is an offline harness that runs the app's own prompts against a labelled image set and scores the answers. These numbers come from **one live run on 2026-11-01** (10:53 UTC). They are committed as `tools/eval/results.md` and `tools/eval/results.json`.

## What it measures

The harness covers three of the app's Muse Spark calls:

| Prompt | What is scored |
|---|---|
| `vision_analyze` | Category, severity, plausibility flag |
| `fix_verify` | Resolved or not, on before/after pairs |
| `same_issue` | Same physical issue or not, on photo pairs |

**Not covered here:**

- the intake agent (no scripted transcripts yet)
- SAM 3.1
- Muse Voice Transcribe
- comment moderation

Those are only exercised by the 10 opt-in live tests in `ios/Packages/HoTHCore/Tests/HoTHCoreTests/LiveMetaTests.swift` (see [meta-models.md](meta-models.md#live-checks)).

## How it matches the app

- Prompts, schemas and the model id are read verbatim from `ios/HoTH/Resources/prompts.json`.
- Requests match the app's: same endpoint (`POST https://api.meta.ai/v1/responses`), reasoning effort `low`, 60 s timeout.
- Images get the same preprocessing as the app: ≤ 1024 px, JPEG quality 0.82.
- Final priority comes from `tools/eval/priority.py`, a Python port of `PriorityAgent`'s floors. It runs without interview answers or a map place.
- One difference: the harness sends **unblurred** dataset images. Apple Vision is not available to the Python harness, while the app always blurs first.

## Dataset

Labels: `tools/eval/dataset/labels.json`. Attribution: [tools/eval/dataset/ATTRIBUTION.md](../tools/eval/dataset/ATTRIBUTION.md).

| Set | Count | Source |
|---|---|---|
| `real/` | 29 | Wikimedia Commons photos (CC0, public domain, CC BY, CC BY-SA), listed per file with author and licence |
| `generated/` | 19 | AI-generated (`syn_*`, OpenAI gpt-image-2, made by `make_synthetic.py`): hard cases, fake or implausible images, 5 before/after fix pairs |

The full run covers:

- 48 vision cases
- 5 fix pairs
- 6 same-issue pairs: 3 pairs of a photo and a cropped, rotated and brightened variant of it (same issue), and 3 different issues

The scoring code is `tools/eval/metrics.py`, tested in `tools/eval/tests/test_metrics.py`.

## How to run

You need [uv](https://docs.astral.sh/uv/) and a Meta Model API key. Pass the key through the environment; never write it to a file.

```bash
# cheap sanity check: 3 vision cases + 1 fix pair
META_API_KEY=... uv run --project tools/eval tools/eval/run_eval.py --subset smoke

# everything: 48 images, 5 fix pairs, 6 same-issue pairs
META_API_KEY=... uv run --project tools/eval tools/eval/run_eval.py --subset full

# metric unit tests (no network)
cd tools/eval && uv run pytest
```

Raw responses are cached in `tools/eval/cache/` (gitignored), so reruns are free. Outputs contain no key and no image bytes.

## Results (full run, 2026-11-01)

| Metric | Result |
|---|---|
| API calls | 62 |
| Estimated cost | $0.416 (Muse Spark 1.3 rates: $1.25 / 1M input, $0.15 / 1M cached input, $4.25 / 1M output) |
| Tokens in / out (reasoning) | 143,158 / 68,136 (35,744) |
| Category accuracy (plausible items) | 36/42 (86%) |
| Severity ≥ expected minimum, model proposal | 40/42 (95%) |
| Severity ≥ expected minimum, final (with floors) | 40/42 (95%) |
| Urgent-hazard recall (≥ high), model / final | 11/12 (92%) / 11/12 (92%) |
| Child-risk recall | 12/15 (80%) |
| Implausible images flagged | 6/6 (100%) |
| False-flag rate, plausible real issues | 6/39 (15%) |
| Same-issue accuracy | 6/6 (100%) |
| Fix-verification accuracy | 5/5 (100%) |
| Latency mean / p95 per call | 7.2 s / 11.6 s |
| Calls slower than the app's 60 s timeout | 0 |

### Per category

| Category | Accuracy |
|---|---|
| blocked_accessibility | 4/4 (100%) |
| electrical_hazard | 4/5 (80%) |
| fitness_equipment | 1/1 (100%) |
| not_an_issue | 3/3 (100%) |
| open_manhole | 5/5 (100%) |
| other | 2/3 (67%) |
| playground_equipment | 4/7 (57%) |
| pothole_pavement | 5/5 (100%) |
| waste_overflow_dumping | 6/6 (100%) |
| water_leak | 2/3 (67%) |

## Reading the results honestly

- **Playground equipment is the weakest category (57%).** A wide shot with a small broken swing, and a synthetic swing with one snapped chain, were both called `not_an_issue`. When that happens the report stays LOW, the safety floors never fire, and the photo is flagged as implausible. This is the most important failure mode for a child-safety app.
- **False flags.** 6 of 39 plausible real-issue photos (15%) were flagged as implausible, so those residents would be asked to retake. Some of them are "after" photos of fixed issues, where `not_an_issue` is arguably correct.
- **Floors did not change the severity score here.** Severity ≥ expected minimum is 40/42 both with and without the floors. They raised several items to CRITICAL (open manholes, child equipment), but every item that missed was a category miss.
- **Small and partly synthetic.** It is 48 images, 19 of them AI-generated, from a single run. Treat the percentages as a smoke-level signal, not a benchmark.
- **Unblurred input.** The harness does not blur. The app sends blurred photos, and the eval does not measure the blur's effect on accuracy.

Per-case results and the full failure list are in `tools/eval/results.md`.
