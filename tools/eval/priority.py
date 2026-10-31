"""Python port of HoTHCore PriorityAgent.decide (ios/Packages/HoTHCore/Sources/HoTHCore/PriorityAgent.swift).

Pure functions only. The eval has no interview answers, POI, confirmations or duration, so those inputs
default to "absent", exactly as a fresh report right after the photo step would look in the app.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping, Sequence

SEVERITIES: tuple[str, ...] = ("low", "medium", "high", "critical")
CONFIRMATION_POINTS = 6
CONFIRMATION_CAP = 30
LONG_DURATION_DAYS = 7
LONG_DURATION_POINTS = 5

_AFFIRMATIVE = {"yes", "yeah", "yep", "y", "true", "نعم", "ايه", "إيه", "اي", "إي", "أيوه", "ايوه", "اكيد", "أكيد"}


def rank(level: str) -> int:
    """Ordinal of a severity level (low=0 .. critical=3)."""
    return SEVERITIES.index(level)


def _max_level(*levels: str) -> str:
    return max(levels, key=rank)


def minimum_score(level: str) -> int:
    return {"low": 0, "medium": 40, "high": 60, "critical": 80}[level]


def base_score(level: str) -> int:
    return {"low": 20, "medium": 45, "high": 65, "critical": 85}[level]


def level_for_score(score: int) -> str:
    for level in ("critical", "high", "medium"):
        if score >= minimum_score(level):
            return level
    return "low"


def location_from_scene(scene_type: str, poi: str | None = None) -> str:
    """Mirror of LocationType(scene:poi:)."""
    if poi and poi != "unknown":
        return poi
    return {
        "playground": "playground",
        "school_area": "school",
        "park": "park",
        "street": "street",
        "sidewalk": "street",
        "parking": "street",
        "residential": "residential",
    }.get(scene_type, "unknown")


def is_affirmative(answer: str | None) -> bool:
    if not answer or not answer.strip():
        return False
    text = answer.strip().lower()
    for sep in (",", ".", "،"):
        text = text.replace(sep, " ")
    first = text.split()[0] if text.split() else text
    return first in _AFFIRMATIVE


@dataclass(frozen=True)
class Decision:
    level: str
    score: int
    signals: tuple[str, ...]
    floor_applied: str | None
    is_flagged: bool


@dataclass(frozen=True)
class _Signal:
    id: str
    weight: int


@dataclass(frozen=True)
class PriorityInput:
    vision: Mapping[str, object]
    answers: Mapping[str, str] = field(default_factory=dict)
    child_using_now: bool | None = None
    duration_days: int | None = None
    poi: str | None = None
    confirmations: int = 0


def _hazard_kinds(vision: Mapping[str, object]) -> set[str]:
    hazards = vision.get("hazards") or []
    assert isinstance(hazards, Sequence)
    return {str(h.get("kind")) for h in hazards if isinstance(h, Mapping)}


def decide(inp: PriorityInput) -> Decision:
    """Deterministic floors can only raise the model's proposal (port of PriorityAgent.decide)."""
    vision = inp.vision
    proposal = str(vision["severity_proposal"])
    category = str(vision["category"])
    if category == "not_an_issue":
        return Decision("low", 0, ("not_an_issue",), None, True)

    location = location_from_scene(str(vision.get("scene_type", "other")), inp.poi)
    child_present = bool(vision.get("child_present"))
    child_using_now = inp.child_using_now if inp.child_using_now is not None else is_affirmative(
        inp.answers.get("children_using_now"))
    child_context = child_present or child_using_now or location in ("playground", "school")

    context_signals: list[_Signal] = []
    if location == "playground":
        context_signals.append(_Signal("location_playground", 15))
    elif location == "school":
        context_signals.append(_Signal("location_school", 15))
    if child_using_now:
        context_signals.append(_Signal("children_using_now", 15))
    elif child_present:
        context_signals.append(_Signal("child_present", 15))

    kinds = _hazard_kinds(vision)
    signals: list[_Signal] = []
    floors: list[tuple[str, str]] = []

    if vision.get("child_use_equipment") and ("sharp_edge" in kinds or "fall" in kinds):
        signals.append(_Signal("child_equipment_hazard", 15))
        floors.append(("high", "HIGH — child equipment"))
        if child_context:
            signals.extend(context_signals)
            floors.append(("critical", "CRITICAL — child safety"))

    if category == "open_manhole":
        signals.append(_Signal("open_manhole", 30))
        floors.append(("critical", "CRITICAL — open manhole"))

    if "electrical" in kinds or category == "electrical_hazard":
        signals.append(_Signal("electrical", 15))
        floors.append(("high", "HIGH — electrical"))
        sparking = is_affirmative(inp.answers.get("sparking"))
        near_water = is_affirmative(inp.answers.get("near_water"))
        if sparking:
            signals.append(_Signal("sparking", 15))
        if near_water:
            signals.append(_Signal("near_water", 15))
        if child_context or sparking or near_water:
            for sig in context_signals:
                if sig not in signals:
                    signals.append(sig)
            floors.append(("critical", "CRITICAL — electrical danger"))

    if inp.confirmations > 0:
        signals.append(_Signal("confirmations", min(inp.confirmations * CONFIRMATION_POINTS, CONFIRMATION_CAP)))
    if inp.duration_days is not None and inp.duration_days > LONG_DURATION_DAYS:
        signals.append(_Signal("long_duration", LONG_DURATION_POINTS))

    raw = base_score(proposal) + sum(s.weight for s in signals)
    strongest = max(floors, key=lambda f: rank(f[0])) if floors else None
    floor_level = strongest[0] if strongest else "low"
    level = _max_level(proposal, floor_level, level_for_score(min(raw, 100)))
    upper = {"low": 39, "medium": 59, "high": 79, "critical": 100}[level]
    score = min(max(raw, minimum_score(level)), upper)
    floor_applied = strongest[1] if strongest and strongest[0] == level else None
    return Decision(level, score, tuple(s.id for s in signals), floor_applied, False)
