"""HoTH eval harness: runs the app's exact prompts (ios/HoTH/Resources/prompts.json) against the labelled dataset.

Usage (key read inline from the macOS Keychain; never printed or written):
    OPENAI_API_KEY=$(...keychain retrieve openai default) uv run --project tools/eval tools/eval/run_eval.py --subset smoke

--subset smoke : 3 vision cases + 1 bad-fix pair (cheap sanity check, the default)
--subset full  : all 48 images, 5 fix pairs, 6 same-issue pairs

Raw API responses are cached in tools/eval/cache/ (gitignored), so reruns cost nothing. Outputs contain no key
and no image bytes.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import io
import json
import os
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import httpx
from PIL import Image

import metrics as m
from priority import PriorityInput, decide

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
PROMPTS_PATH = REPO / "ios" / "HoTH" / "Resources" / "prompts.json"
DATASET = ROOT / "dataset"
CACHE = ROOT / "cache"
API_URL = "https://api.openai.com/v1/responses"
APP_TIMEOUT_S = 30.0  # OpenAIClient default timeout in the iOS app
MAX_EDGE = 1024  # CaptureService.maxPixelEdge
JPEG_QUALITY = 82  # CaptureService compressionQuality 0.82
CONCURRENCY = 6
RETRIES = 3

SMOKE_VISION = (
    "generated/syn_playground_springrider.jpg",
    "real/real_pothole_pavement_1.jpg",
    "real/real_electrical_hazard_1.jpg",
)
SMOKE_PAIRS = ("pair2",)

# (new, existing, expected_same). "variant:" = Pillow re-crop/rotate of the same photo.
SAME_ISSUE_PAIRS = (
    ("variant:generated/syn_pair2_before.jpg", "generated/syn_pair2_before.jpg", True),
    ("variant:real/real_open_manhole_4.jpg", "real/real_open_manhole_4.jpg", True),
    ("variant:real/real_playground_equipment_2.jpg", "real/real_playground_equipment_2.jpg", True),
    ("real/real_pothole_pavement_2.jpg", "real/real_pothole_pavement_1.jpg", False),
    ("real/real_open_manhole_1.jpg", "real/real_open_manhole_4.jpg", False),
    ("real/real_waste_overflow_dumping_2.jpg", "generated/syn_pair1_before.jpg", False),
)


@dataclass(frozen=True)
class CallResult:
    output: dict[str, Any]
    latency_ms: float
    usage: dict[str, Any]
    cached: bool


def fill(template: str, values: dict[str, str]) -> str:
    for key, value in values.items():
        template = template.replace("{{" + key + "}}", value)
    return template


def prepare_jpeg(img: Image.Image) -> bytes:
    """Same preprocessing as the app: <=1024 px long edge, JPEG q0.82."""
    img = img.convert("RGB")
    img.thumbnail((MAX_EDGE, MAX_EDGE), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=JPEG_QUALITY)
    return buf.getvalue()


def load_image(ref: str) -> bytes:
    if ref.startswith("variant:"):
        return make_variant(ref.removeprefix("variant:"))
    with Image.open(DATASET / ref) as img:
        return prepare_jpeg(img)


def make_variant(ref: str) -> bytes:
    """Deterministic 'different angle' copy: crop 8% margins, rotate 6 degrees, slight brightness shift."""
    out = CACHE / "variants" / (Path(ref).stem + "_variant.jpg")
    if out.exists():
        return out.read_bytes()
    with Image.open(DATASET / ref) as src:
        img = src.convert("RGB")
    w, h = img.size
    img = img.crop((int(w * 0.08), int(h * 0.05), int(w * 0.95), int(h * 0.92))).rotate(6, expand=False)
    img = img.point(lambda v: min(255, int(v * 1.06)))
    data = prepare_jpeg(img)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    return data


def build_body(model: str, system: str, user: str, images: list[bytes], detail: str, schema: dict[str, Any]) -> dict:
    content: list[dict[str, Any]] = [{"type": "input_text", "text": user}]
    for data in images:
        url = "data:image/jpeg;base64," + base64.b64encode(data).decode()
        content.append({"type": "input_image", "image_url": url, "detail": detail})
    return {
        "model": model,
        "input": [
            {"role": "system", "content": [{"type": "input_text", "text": system}]},
            {"role": "user", "content": content},
        ],
        "text": {"format": {"type": "json_schema", "name": schema["name"], "strict": schema["strict"],
                            "schema": schema["schema"]}},
    }


def extract_output(raw: dict[str, Any]) -> dict[str, Any]:
    if raw.get("status") == "incomplete":
        raise RuntimeError(f"incomplete: {raw.get('incomplete_details')}")
    for item in raw.get("output", []):
        if item.get("type") != "message":
            continue
        for part in item.get("content", []):
            if part.get("type") == "output_text":
                return json.loads(part["text"])
            if part.get("type") == "refusal":
                raise RuntimeError(f"refusal: {part.get('refusal')}")
    raise RuntimeError("no output_text in response")


class Caller:
    def __init__(self, client: httpx.AsyncClient, key: str) -> None:
        self.client = client
        self.key = key
        self.sem = asyncio.Semaphore(CONCURRENCY)

    async def call(self, task: str, model: str, system: str, user: str, images: list[bytes], detail: str,
                   schema: dict[str, Any]) -> CallResult:
        digest = hashlib.sha256()
        for part in (task, model, system, user, detail, json.dumps(schema, sort_keys=True)):
            digest.update(part.encode())
        for data in images:
            digest.update(hashlib.sha256(data).digest())
        path = CACHE / f"{task}_{digest.hexdigest()[:24]}.json"
        if path.exists():
            entry = json.loads(path.read_text())
            return CallResult(extract_output(entry["raw"]), entry["latency_ms"], entry["usage"], True)

        body = build_body(model, system, user, images, detail, schema)
        last_error = "unknown"
        async with self.sem:
            for attempt in range(RETRIES):
                start = time.perf_counter()
                try:
                    resp = await self.client.post(API_URL, json=body,
                                                  headers={"Authorization": f"Bearer {self.key}"})
                except httpx.HTTPError as exc:
                    last_error = type(exc).__name__
                    await asyncio.sleep(2 ** attempt)
                    continue
                latency = (time.perf_counter() - start) * 1000
                if resp.status_code in (429, 500, 502, 503, 504):
                    last_error = f"HTTP {resp.status_code}"
                    await asyncio.sleep(2 ** (attempt + 1))
                    continue
                if resp.status_code != 200:
                    # Error bodies from the API contain no secrets; truncate to keep logs short.
                    raise RuntimeError(f"{task}: HTTP {resp.status_code}: {resp.text[:400]}")
                raw = resp.json()
                output = extract_output(raw)  # raises before caching on a bad response
                usage = raw.get("usage") or {}
                path.write_text(json.dumps({"raw": raw, "latency_ms": latency, "usage": usage}))
                return CallResult(output, latency, usage, False)
        raise RuntimeError(f"{task}: failed after {RETRIES} attempts ({last_error})")


async def run(subset: str) -> dict[str, Any]:
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        sys.exit("OPENAI_API_KEY is not set (export it inline from the Keychain).")
    prompts = json.loads(PROMPTS_PATH.read_text())
    labels = json.loads((DATASET / "labels.json").read_text())
    by_file = {lab["file"]: lab for lab in labels}
    model = prompts["models"]["vision"]
    CACHE.mkdir(exist_ok=True)

    if subset == "smoke":
        vision_files = list(SMOKE_VISION)
        pair_ids = list(SMOKE_PAIRS)
        same_pairs: tuple = ()
    else:
        vision_files = [lab["file"] for lab in labels]
        pair_ids = sorted({lab["pair_id"] for lab in labels if lab["pair_id"]})
        same_pairs = SAME_ISSUE_PAIRS
    befores = {lab["pair_id"]: lab for lab in labels if lab["pair_role"] == "before"}
    afters = {lab["pair_id"]: lab for lab in labels if lab["pair_role"] == "after"}
    # fix_verify and same_issue need a vision summary of their inputs (as in the app).
    needed = list(dict.fromkeys(vision_files + [befores[p]["file"] for p in pair_ids]
                                + [ref for pair in same_pairs for ref in pair[:2]]))

    va = prompts["vision_analyze"]
    captured = datetime(2026, 10, 7, 9, 0, tzinfo=timezone.utc)
    values = {"user_language": "en", "captured_at": captured.isoformat().replace("+00:00", "Z"),
              "place_hint": "unknown", "user_note": ""}

    async with httpx.AsyncClient(timeout=120) as client:
        caller = Caller(client, key)

        async def vision(ref: str) -> tuple[str, CallResult]:
            res = await caller.call("vision_analyze", model, fill(va["system"], values), fill(va["user_template"], values),
                                    [load_image(ref)], "original", va["json_schema"])
            return ref, res

        vision_results = dict(await asyncio.gather(*(vision(r) for r in needed)))

        fv = prompts["fix_verify"]

        async def fix(pid: str) -> dict[str, Any]:
            before, after = befores[pid], afters[pid]
            vals = {"report_title": vision_results[before["file"]].output["title_en"], "category": before["category"],
                    "before_captured_at": "2026-10-01T09:00:00Z", "after_captured_at": "2026-10-06T15:00:00Z"}
            res = await caller.call("fix_verify", model, fill(fv["system"], vals), fill(fv["user_template"], vals),
                                    [load_image(before["file"]), load_image(after["file"])], "auto", fv["json_schema"])
            return {"pair_id": pid, "before": before["file"], "after": after["file"], "expected_resolved": after["fixed"],
                    "pred": res.output, "latency_ms": res.latency_ms, "usage": res.usage, "cached": res.cached}

        fix_results = await asyncio.gather(*(fix(p) for p in pair_ids))

        si = prompts["same_issue"]

        async def same(new: str, existing: str, expected: bool) -> dict[str, Any]:
            nv, ev = vision_results[new].output, vision_results[existing].output
            vals = {"new_summary": nv["description_en"], "new_category": nv["category"],
                    "new_captured_at": "2026-10-07T09:00:00Z", "existing_summary": ev["description_en"],
                    "existing_category": nv["category"], "existing_captured_at": "2026-10-05T09:00:00Z",
                    "distance_m": "15"}
            res = await caller.call("same_issue", model, fill(si["system"], vals), fill(si["user_template"], vals),
                                    [load_image(new), load_image(existing)], "auto", si["json_schema"])
            return {"new": new, "existing": existing, "expected_same": expected, "pred": res.output,
                    "latency_ms": res.latency_ms, "usage": res.usage, "cached": res.cached}

        same_results = await asyncio.gather(*(same(*p) for p in same_pairs))

    items = []
    for ref in vision_files:
        res = vision_results[ref]
        decision = decide(PriorityInput(vision=res.output))
        items.append({"file": ref, "label": by_file[ref], "pred": res.output, "final_priority": decision.level,
                      "floor_applied": decision.floor_applied, "signals": list(decision.signals),
                      "latency_ms": res.latency_ms, "usage": res.usage, "cached": res.cached})
    return {"subset": subset, "model": model, "items": items, "fix_pairs": list(fix_results),
            "same_issue_pairs": list(same_results),
            "aux_vision_calls": [{"file": r, "usage": vision_results[r].usage, "latency_ms": vision_results[r].latency_ms}
                                 for r in needed if r not in vision_files]}


def compute_metrics(res: dict[str, Any]) -> dict[str, Any]:
    items = res["items"]
    real = [i for i in items if i["label"]["plausible"]]
    calls = items + res["fix_pairs"] + res["same_issue_pairs"] + res["aux_vision_calls"]
    latencies = [c["latency_ms"] for c in calls]
    tin = sum(c["usage"].get("input_tokens", 0) for c in calls)
    tcached = sum((c["usage"].get("input_tokens_details") or {}).get("cached_tokens", 0) for c in calls)
    tout = sum(c["usage"].get("output_tokens", 0) for c in calls)
    treason = sum((c["usage"].get("output_tokens_details") or {}).get("reasoning_tokens", 0) for c in calls)
    flags = m.flag_rates(items)
    out = {
        "category_accuracy": m.category_accuracy(real),
        "per_category": m.per_category(real),
        "severity_raw": m.severity_rate(real, use_floors=False),
        "severity_final": m.severity_rate(real, use_floors=True),
        "urgent_recall_raw": m.urgent_recall(real, use_floors=False),
        "urgent_recall_final": m.urgent_recall(real, use_floors=True),
        "child_risk_recall": m.child_risk_recall(real),
        **flags,
        "fix_accuracy": m.boolean_accuracy([(p["pred"]["resolved"], p["expected_resolved"]) for p in res["fix_pairs"]]),
        "same_issue_accuracy": m.boolean_accuracy(
            [(p["pred"]["same_issue"], p["expected_same"]) for p in res["same_issue_pairs"]]),
    }
    serial = {k: ({kk: vv.__dict__ for kk, vv in v.items()} if isinstance(v, dict) else v.__dict__)
              for k, v in out.items()}
    serial.update({
        "calls": len(calls), "latency_mean_ms": sum(latencies) / len(latencies) if latencies else None,
        "latency_p95_ms": m.percentile(latencies, 95), "calls_over_app_timeout": sum(l > APP_TIMEOUT_S * 1000 for l in latencies),
        "input_tokens": tin, "cached_input_tokens": tcached, "output_tokens": tout, "reasoning_tokens": treason,
        "est_cost_usd": round(m.cost_usd(tin, tcached, tout), 4),
    })
    return {"rates": out, "json": serial}


def pct(rate: m.Rate) -> str:
    return rate.fmt()


def render_md(res: dict[str, Any], met: dict[str, Any]) -> str:
    r, j = met["rates"], met["json"]
    smoke = res["subset"] == "smoke"
    lines = ["# HoTH eval results", ""]
    if smoke:
        lines += ["> **Smoke check on 3 cases + 1 fix pair, not a full benchmark.** Run with `--subset full` for all "
                  "48 images (29 CC-licensed Wikimedia Commons photos + 19 clearly-labelled AI-generated images), "
                  "5 fix pairs and 6 same-issue pairs.", ""]
    lines += [f"- Model: `{res['model']}` (from `prompts.json` `models.vision`). Prompts, JSON schemas and image "
              "preprocessing (<=1024 px, JPEG q0.82, `detail` as in the app) are **exactly those shipped in the iOS app** "
              "(`ios/HoTH/Resources/prompts.json`).",
              f"- Run: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}, {j['calls']} API calls.",
              "- Final priority = Python port of the app's deterministic `PriorityAgent` floors (no interview answers, no map POI).",
              ""]
    lines += ["## Per-case results", "", "| Image | Source | Expected | Predicted | Severity (model → final) | Expected min | Plausibility flag | Latency |",
              "|---|---|---|---|---|---|---|---|"]
    for i in res["items"]:
        lab, p = i["label"], i["pred"]
        src = "AI-generated" if lab["source"] != "commons" else "Commons"
        lines.append(f"| `{Path(i['file']).name}` | {src} | {lab['category']} | {p['category']} | "
                     f"{p['severity_proposal']} → **{i['final_priority']}**"
                     f"{' (' + i['floor_applied'] + ')' if i['floor_applied'] else ''} | {lab['expected_severity_min']} | "
                     f"{'yes' if m.is_plausibility_flagged(p) else 'no'} | {i['latency_ms'] / 1000:.1f} s |")
    lines += ["", "## Metrics", "", "| Metric | Result |", "|---|---|",
              f"| Category accuracy (plausible items) | {pct(r['category_accuracy'])} |",
              f"| Severity >= expected min, model proposal | {pct(r['severity_raw'])} |",
              f"| Severity >= expected min, final priority (with floors) | {pct(r['severity_final'])} |",
              f"| Urgent-hazard recall (>= high), model / final | {pct(r['urgent_recall_raw'])} / {pct(r['urgent_recall_final'])} |",
              f"| Child-risk recall (final >= high OR child_use_equipment OR child_present) | {pct(r['child_risk_recall'])} |"]
    if not smoke:
        lines += [f"| Implausible images flagged | {pct(r['implausible_flagged'])} |",
                  f"| False-flag rate, plausible real issues | {pct(r['false_flag_real_issues'])} |",
                  f"| False-flag rate, all plausible (incl. not_an_issue, which *should* be flagged) | {pct(r['false_flag_all_plausible'])} |",
                  f"| Same-issue accuracy | {pct(r['same_issue_accuracy'])} |"]
    lines += [f"| Fix-verification accuracy | {pct(r['fix_accuracy'])} |",
              f"| Latency mean / p95 per call | {j['latency_mean_ms'] / 1000:.1f} s / {j['latency_p95_ms'] / 1000:.1f} s |",
              f"| Calls slower than the app's 30 s timeout | {j['calls_over_app_timeout']} |",
              f"| Tokens in / out (of which reasoning) | {j['input_tokens']:,} / {j['output_tokens']:,} ({j['reasoning_tokens']:,}) |",
              f"| Estimated cost | ${j['est_cost_usd']:.3f} (at $2.00 / 1M input, $10.00 / 1M output) |", ""]
    if not smoke:
        lines += ["### Per category", "", "| Category | Accuracy |", "|---|---|"]
        lines += [f"| {c} | {pct(v)} |" for c, v in r["per_category"].items()] + [""]
    lines += ["## Fix verification", "", "| Pair | Expected resolved | Predicted | Same location | Model reason |", "|---|---|---|---|---|"]
    for p in res["fix_pairs"]:
        lines.append(f"| {p['pair_id']} | {p['expected_resolved']} | {p['pred']['resolved']} | "
                     f"{p['pred']['same_location_likely']} | {p['pred']['reason_en']} |")
    if res["same_issue_pairs"]:
        lines += ["", "## Same-issue pairs", "", "| New | Existing | Expected | Predicted |", "|---|---|---|---|"]
        for p in res["same_issue_pairs"]:
            lines.append(f"| `{p['new']}` | `{p['existing']}` | {p['expected_same']} | {p['pred']['same_issue']} |")
    lines += ["", "## Where it fails", ""]
    misses = failures(res)
    lines += [f"- {x}" for x in misses] if misses else ["- No misses on the cases in this run (small sample; see note above)."]
    lines += ["", "## Not evaluated", "", "- `chat_intake` slot filling (no scripted transcripts yet)."]
    if smoke:
        lines.append("- Plausibility/rejection sweep and same-issue pairs (skipped to keep spend minimal).")
    lines.append("")
    return "\n".join(lines)


def failures(res: dict[str, Any]) -> list[str]:
    out = []
    for i in res["items"]:
        lab, p, name = i["label"], i["pred"], f"`{Path(i['file']).name}`"
        if lab["plausible"]:
            if p["category"] != lab["category"]:
                out.append(f"{name}: category {p['category']} instead of {lab['category']} ({lab['notes']})")
            if not m.meets_min(i["final_priority"], lab["expected_severity_min"]):
                out.append(f"{name}: final priority {i['final_priority']} below expected {lab['expected_severity_min']} "
                           f"(model said: {p['severity_reason_en']})")
            if lab["category"] != "not_an_issue" and m.is_plausibility_flagged(p):
                out.append(f"{name}: real photo falsely flagged as implausible ({p['plausibility']['notes']})")
            if lab["category"] == "not_an_issue" and not m.is_plausibility_flagged(p):
                out.append(f"{name}: non-issue not flagged")
        elif not m.is_plausibility_flagged(p):
            out.append(f"{name}: fake/irrelevant image not flagged ({lab['notes']})")
    for f in res["fix_pairs"]:
        if f["pred"]["resolved"] != f["expected_resolved"]:
            out.append(f"fix {f['pair_id']}: predicted resolved={f['pred']['resolved']}, expected {f['expected_resolved']} "
                       f"({f['pred']['reason_en']})")
    for s in res["same_issue_pairs"]:
        if s["pred"]["same_issue"] != s["expected_same"]:
            out.append(f"same-issue `{s['new']}` vs `{s['existing']}`: predicted {s['pred']['same_issue']} ({s['pred']['reason']})")
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--subset", choices=("smoke", "full"), default="smoke")
    args = parser.parse_args()
    res = asyncio.run(run(args.subset))
    met = compute_metrics(res)
    res["metrics"] = met["json"]
    (ROOT / "results.json").write_text(json.dumps(res, ensure_ascii=False, indent=2))
    (ROOT / "results.md").write_text(render_md(res, met))
    j = met["json"]
    print(f"done: {j['calls']} calls, est ${j['est_cost_usd']:.3f}, p95 {j['latency_p95_ms'] / 1000:.1f}s -> results.md")


if __name__ == "__main__":
    main()
