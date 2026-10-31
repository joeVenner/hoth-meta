"""Offline tests for the metric functions and the PriorityAgent port (no network)."""
import metrics as m
from priority import PriorityInput, decide


def vision(**overrides):
    base = {
        "category": "pothole_pavement", "severity_proposal": "medium", "scene_type": "street", "hazards": [],
        "child_use_equipment": False, "child_present": False,
        "plausibility": {"shows_reported_issue": True, "looks_like_screen_or_print": False,
                         "looks_like_stock_or_watermarked": False, "notes": ""},
    }
    base.update(overrides)
    return base


def item(pred, **label):
    lab = {"category": "pothole_pavement", "expected_severity_min": "medium", "urgent": False, "child_risk": False,
           "plausible": True}
    lab.update(label)
    return {"pred": pred, "label": lab}


def test_no_floor_keeps_proposal():
    assert decide(PriorityInput(vision=vision())).level == "medium"


def test_open_manhole_always_critical():
    d = decide(PriorityInput(vision=vision(category="open_manhole", severity_proposal="low")))
    assert d.level == "critical" and d.floor_applied == "CRITICAL — open manhole"


def test_child_equipment_in_playground_is_critical():
    v = vision(category="playground_equipment", scene_type="playground", child_use_equipment=True,
               hazards=[{"label": "sharp", "kind": "sharp_edge", "box": {}}])
    assert decide(PriorityInput(vision=v)).level == "critical"


def test_score_alone_can_escalate_without_child_context():
    # high (65) + child_equipment_hazard (15) = 80 -> critical by score even though the floor is only HIGH.
    v = vision(category="playground_equipment", scene_type="street", severity_proposal="high",
               child_use_equipment=True, hazards=[{"label": "fall", "kind": "fall", "box": {}}])
    d = decide(PriorityInput(vision=v))
    assert d.level == "critical" and d.floor_applied is None


def test_electrical_floor_high_without_child_context():
    assert decide(PriorityInput(vision=vision(category="electrical_hazard", severity_proposal="low"))).level == "high"


def test_not_an_issue_is_low_and_flagged():
    d = decide(PriorityInput(vision=vision(category="not_an_issue", severity_proposal="high")))
    assert d.level == "low" and d.is_flagged


def test_plausibility_flag():
    assert not m.is_plausibility_flagged(vision())
    p = dict(vision()["plausibility"], looks_like_screen_or_print=True)
    assert m.is_plausibility_flagged(vision(plausibility=p))


def test_category_and_severity_rates():
    items = [item(vision()), item(vision(category="other", severity_proposal="low"))]
    assert m.category_accuracy(items).fmt() == "1/2 (50%)"
    assert m.severity_rate(items, use_floors=False).hits == 1


def test_urgent_recall_uses_floors():
    it = item(vision(category="open_manhole", severity_proposal="medium"), category="open_manhole", urgent=True)
    assert m.urgent_recall([it], use_floors=False).hits == 0
    assert m.urgent_recall([it], use_floors=True).hits == 1


def test_empty_rate_and_percentile():
    assert m.Rate(0, 0).fmt() == "n/a" and m.Rate(0, 0).value is None
    assert m.percentile([], 95) is None
    assert m.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 95) == 10


def test_cost():
    assert round(m.cost_usd(1_000_000, 0, 100_000), 2) == 3.00
