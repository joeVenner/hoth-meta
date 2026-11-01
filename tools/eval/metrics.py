"""Pure metric functions for the HoTH eval (no I/O, no network)."""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Mapping, Sequence

from priority import PriorityInput, decide, rank

# USD per 1M tokens, muse-spark-1.3 Standard mode
# (dev.meta.ai/docs/pricing-rate-limits, fetched 2026-11-01).
PRICE_INPUT = 1.25
PRICE_CACHED_INPUT = 0.15
PRICE_OUTPUT = 4.25


@dataclass(frozen=True)
class Rate:
    hits: int
    total: int

    @property
    def value(self) -> float | None:
        return self.hits / self.total if self.total else None

    def fmt(self) -> str:
        if not self.total:
            return "n/a"
        return f"{self.hits}/{self.total} ({100 * self.hits / self.total:.0f}%)"


def is_plausibility_flagged(vision: Mapping[str, object]) -> bool:
    """True when the model raises any plausibility signal (mirrors the vision part of Plausibility.evaluate)."""
    p = vision["plausibility"]
    assert isinstance(p, Mapping)
    return (not p["shows_reported_issue"]) or bool(p["looks_like_screen_or_print"]) or bool(
        p["looks_like_stock_or_watermarked"])


def final_level(vision: Mapping[str, object]) -> str:
    """App's final priority right after the photo step (no answers, no POI, no confirmations)."""
    return decide(PriorityInput(vision=vision)).level


def meets_min(level: str, expected_min: str) -> bool:
    return rank(level) >= rank(expected_min)


def category_accuracy(items: Sequence[Mapping[str, object]]) -> Rate:
    return Rate(sum(1 for i in items if i["pred"]["category"] == i["label"]["category"]), len(items))


def per_category(items: Sequence[Mapping[str, object]]) -> dict[str, Rate]:
    out: dict[str, Rate] = {}
    for cat in sorted({str(i["label"]["category"]) for i in items}):
        group = [i for i in items if i["label"]["category"] == cat]
        out[cat] = category_accuracy(group)
    return out


def severity_rate(items: Sequence[Mapping[str, object]], use_floors: bool) -> Rate:
    hits = 0
    for i in items:
        level = final_level(i["pred"]) if use_floors else str(i["pred"]["severity_proposal"])
        hits += meets_min(level, str(i["label"]["expected_severity_min"]))
    return Rate(hits, len(items))


def urgent_recall(items: Sequence[Mapping[str, object]], use_floors: bool) -> Rate:
    urgent = [i for i in items if i["label"]["urgent"]]
    return severity_like(urgent, use_floors, "high")


def severity_like(items: Sequence[Mapping[str, object]], use_floors: bool, minimum: str) -> Rate:
    hits = 0
    for i in items:
        level = final_level(i["pred"]) if use_floors else str(i["pred"]["severity_proposal"])
        hits += meets_min(level, minimum)
    return Rate(hits, len(items))


def child_risk_recall(items: Sequence[Mapping[str, object]]) -> Rate:
    """child_risk item counts as caught if final priority >= high OR child_use_equipment OR child_present."""
    risky = [i for i in items if i["label"]["child_risk"]]
    hits = sum(
        1 for i in risky
        if meets_min(final_level(i["pred"]), "high") or i["pred"]["child_use_equipment"] or i["pred"]["child_present"]
    )
    return Rate(hits, len(risky))


def flag_rates(items: Sequence[Mapping[str, object]]) -> dict[str, Rate]:
    implausible = [i for i in items if not i["label"]["plausible"]]
    plausible = [i for i in items if i["label"]["plausible"]]
    plausible_issues = [i for i in plausible if i["label"]["category"] != "not_an_issue"]
    return {
        "implausible_flagged": Rate(sum(is_plausibility_flagged(i["pred"]) for i in implausible), len(implausible)),
        "false_flag_all_plausible": Rate(sum(is_plausibility_flagged(i["pred"]) for i in plausible), len(plausible)),
        "false_flag_real_issues": Rate(
            sum(is_plausibility_flagged(i["pred"]) for i in plausible_issues), len(plausible_issues)),
    }


def boolean_accuracy(pairs: Sequence[tuple[bool, bool]]) -> Rate:
    """pairs = (predicted, expected)."""
    return Rate(sum(1 for p, e in pairs if p == e), len(pairs))


def percentile(values: Sequence[float], q: float) -> float | None:
    """Nearest-rank percentile, q in [0, 100]."""
    if not values:
        return None
    ordered = sorted(values)
    idx = max(0, math.ceil(q / 100 * len(ordered)) - 1)
    return ordered[idx]


def cost_usd(input_tokens: int, cached_tokens: int, output_tokens: int) -> float:
    uncached = max(0, input_tokens - cached_tokens)
    return (uncached * PRICE_INPUT + cached_tokens * PRICE_CACHED_INPUT + output_tokens * PRICE_OUTPUT) / 1_000_000
