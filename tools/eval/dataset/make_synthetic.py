"""Generate the synthetic (`syn_`) part of the eval dataset with the gpt-image skill, then merge labels.

Run (key read inline from the macOS Keychain, never written to disk):
    OPENAI_API_KEY=$(KEYCHAIN_MANAGER_AGENT_MODE=1 bash /Users/macbook/.claude/skills/claude-keychain-skill/scripts/keychain_manager.sh retrieve openai default) \
        python3 -I tools/eval/dataset/make_synthetic.py

Stage 1 generates all non-"after" images, stage 2 makes each "after" as an image EDIT of its "before".
Existing files are skipped, so the script is safe to re-run. Labels for every syn_ file that exists are
merged into labels.json (replacing older entries for the same file).
"""
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

SKILL = "/Users/macbook/.claude/skills/gpt-image/scripts"
PHONE = (" Photorealistic handheld smartphone photo taken by a resident reporting the issue, natural daylight,"
         " slightly imperfect framing, mild sensor noise and JPEG compression, not a professional photo."
         " No people, no faces, no text, no watermark.")
ABU = "Set in a residential neighbourhood of Abu Dhabi, UAE (sand-coloured villa walls, date palms, interlocking paving bricks). "

GEN = {
    "syn_playground_springrider": (
        "1024x1536",
        ABU + "A small neighbourhood park playground with rubber safety flooring and a shade sail. Mid close-up of a"
        " children's spring rider: a small plastic horse mounted on a large steel coil spring. The horse's plastic seat"
        " is snapped and broken off, with cracked plastic shards, exposing a sharp, jagged, rusty metal bracket edge"
        " sticking up exactly where a child would sit. Taken at child height, slightly tilted, harsh afternoon sun." + PHONE),
    "syn_fitness_equipment_1": (
        "1024x1024",
        ABU + "An outdoor public fitness station in a park. A green-and-yellow air-walker exercise machine has one footplate"
        " snapped off and lying on the ground, the pedal arm bent, a bare bolt and sharp broken metal stub exposed." + PHONE),
    "syn_open_manhole_1": (
        "1024x1024",
        ABU + "A pedestrian sidewalk next to a quiet residential road. A round manhole in the middle of the sidewalk has its"
        " cover completely missing, leaving a dark open hole about 60 cm wide with no barrier or cone around it." + PHONE),
    "syn_fake_screen_pothole": (
        "1024x1024",
        "A smartphone photo taken of a laptop screen. The laptop screen displays a photo of a pothole in a road. Strong"
        " moire interference pattern, visible pixel grid, the black plastic screen bezel and part of the keyboard are visible,"
        " slight glare reflection of a ceiling light on the screen, indoor office lighting. No watermark."),
    "syn_fake_printed_photo": (
        "1024x1024",
        "A smartphone photo of a hand holding a glossy printed 4x6 inch photograph of an overflowing street trash bin."
        " The print is held over a wooden desk indoors, light glare on the glossy paper, fingers visible at the edge,"
        " the print edges and white border clearly visible. No face, no watermark."),
    "syn_fake_stock_watermark": (
        "1024x1024",
        "A glossy, over-lit, perfectly composed commercial stock photograph of a broken children's swing in a park, shallow"
        " depth of field, studio-like colour grading. Overlaid with a large semi-transparent diagonal repeating watermark"
        " text \"SAMPLE PREVIEW\" across the whole image and a small \"preview only\" banner in the corner."),
    "syn_fake_cartoon_pothole": (
        "1024x1024",
        "A flat vector cartoon illustration of a pothole in a road with a cartoon car bouncing over it, bold outlines,"
        " bright flat colours, simple sky with a smiling sun, children's-book style. Clearly a drawing, not a photo."),
    "syn_fake_meme": (
        "1024x1024",
        "An internet meme image: a photo of a rubber duck floating in a large water-filled pothole on a road, with bold"
        " white Impact-font meme text with black outline, top text \"WHEN THE ROAD\" and bottom text \"BECOMES A POOL\"."),
    "syn_fake_unrelated": (
        "1024x1024",
        "A smartphone photo of a plate of chicken machboos with rice and a glass of laban on a restaurant table, warm"
        " indoor light. An ordinary food photo with nothing broken or hazardous. No people, no text, no watermark."),
    "syn_pair1_before": (
        "1024x1024",
        ABU + "A communal waste collection point beside a villa wall: three large green municipal wheelie bins overflowing,"
        " lids forced open, many black and white garbage bags piled on the ground around them, cardboard and litter scattered." + PHONE),
    "syn_pair2_before": (
        "1024x1024",
        ABU + "An asphalt residential street seen from standing height, a large deep pothole about 80 cm wide with broken"
        " crumbling edges and loose gravel inside, near the kerb." + PHONE),
    "syn_pair3_before": (
        "1024x1024",
        ABU + "A neighbourhood park playground swing set with a shade sail. One swing has a snapped chain on one side, so"
        " the rubber seat hangs vertically from a single chain, the broken chain end dangling." + PHONE),
    "syn_pair4_before": (
        "1024x1024",
        ABU + "A public park bench along a footpath. Two of the wooden seat slats are snapped and missing, splintered wood"
        " ends visible, one slat lying on the ground beside it." + PHONE),
    "syn_pair5_before": (
        "1024x1024",
        ABU + "A grey metal electrical distribution cabinet on a sidewalk with its door hanging open and broken off one"
        " hinge, exposing a tangle of electrical cables, bare copper wire ends and terminal blocks at child height." + PHONE),
}

KEEP = " Keep exactly the same camera position, framing, lighting, surroundings and photo style; change nothing else."
EDIT = {
    "syn_pair1_after": ("syn_pair1_before",
        "Show this same location after a partial clean-up: the three bins are emptied with lids closed and most of the"
        " ground is swept, BUT two black garbage bags and some cardboard are still lying on the ground at the far left"
        " edge of the frame." + KEEP),
    "syn_pair2_after": ("syn_pair2_before",
        "Show this same pothole after a poor repair: only the right half of the pothole is filled with fresh black asphalt"
        " patch, while the left half is still an open hole with crumbling edges and gravel." + KEEP),
    "syn_pair3_after": ("syn_pair3_before",
        "Show this same swing after it has been properly repaired: the broken swing now hangs level from two new intact"
        " chains with a new rubber seat, matching the other swings." + KEEP),
    "syn_pair4_after": ("syn_pair4_before",
        "Show this same bench after it has been properly repaired: all wooden seat slats are present and intact, newly"
        " replaced slats are slightly lighter in colour, no wood on the ground." + KEEP),
    "syn_pair5_after": ("syn_pair5_before",
        "Show this same electrical cabinet after it has been properly repaired: the door is closed, re-hung on its hinges"
        " and locked, no cables or wires visible." + KEEP),
}


# name: (category, severity_min, child_risk, urgent, plausible, pair_id, pair_role, fixed, notes)
LABELS = {
    "syn_playground_springrider": ("playground_equipment", "high", True, True, True, None, None, None, "HERO demo case. Spring rider with snapped seat exposing a sharp jagged metal edge at child sitting height."),
    "syn_fitness_equipment_1": ("fitness_equipment", "medium", True, False, True, None, None, None, "Air-walker with snapped footplate and exposed broken metal stub."),
    "syn_open_manhole_1": ("open_manhole", "critical", True, True, True, None, None, None, "Missing manhole cover on a sidewalk, no barrier."),
    "syn_fake_screen_pothole": ("pothole_pavement", "low", False, False, False, None, None, None, "Photo of a laptop screen showing a pothole (moire, bezel). Should be rejected as not a first-hand photo."),
    "syn_fake_printed_photo": ("waste_overflow_dumping", "low", False, False, False, None, None, None, "Hand holding a printed photo of an overflowing bin. Should be rejected."),
    "syn_fake_stock_watermark": ("playground_equipment", "low", False, False, False, None, None, None, "Stock-photo look with SAMPLE PREVIEW watermark. Should be rejected."),
    "syn_fake_cartoon_pothole": ("pothole_pavement", "low", False, False, False, None, None, None, "Cartoon illustration of a pothole. Should be rejected."),
    "syn_fake_meme": ("pothole_pavement", "low", False, False, False, None, None, None, "Meme with Impact text over a flooded pothole. Should be rejected."),
    "syn_fake_unrelated": ("not_an_issue", "low", False, False, False, None, None, None, "Food photo, unrelated to any civic issue. Should be rejected."),
    "syn_pair1_before": ("waste_overflow_dumping", "medium", False, False, True, "pair1", "before", None, "Overflowing communal bins with bags piled around."),
    "syn_pair1_after": ("waste_overflow_dumping", "low", False, False, True, "pair1", "after", False, "BAD FIX: bins emptied but bags still visible at the left edge."),
    "syn_pair2_before": ("pothole_pavement", "medium", False, False, True, "pair2", "before", None, "Large pothole near the kerb."),
    "syn_pair2_after": ("pothole_pavement", "medium", False, False, True, "pair2", "after", False, "BAD FIX: pothole only half filled."),
    "syn_pair3_before": ("playground_equipment", "high", True, True, True, "pair3", "before", None, "Swing with snapped chain, seat hanging from one chain."),
    "syn_pair3_after": ("playground_equipment", "low", False, False, True, "pair3", "after", True, "Fixed: swing re-hung on two new chains."),
    "syn_pair4_before": ("other", "low", False, False, True, "pair4", "before", None, "Park bench with snapped/missing seat slats."),
    "syn_pair4_after": ("other", "low", False, False, True, "pair4", "after", True, "Fixed: slats replaced."),
    "syn_pair5_before": ("electrical_hazard", "critical", True, True, True, "pair5", "before", None, "Open electrical cabinet with exposed bare wires at child height."),
    "syn_pair5_after": ("electrical_hazard", "low", False, False, True, "pair5", "after", True, "Fixed: cabinet door re-hung and closed."),
}


def merge_labels(out: str) -> int:
    labels_path = os.path.join(os.path.dirname(out), "labels.json")
    labels = [x for x in json.load(open(labels_path)) if not x["file"].startswith("generated/")]
    for name, (cat, sev, child, urgent, plausible, pid, role, fixed, notes) in LABELS.items():
        if not os.path.exists(f"{out}/{name}.jpg"):
            continue
        labels.append({
            "file": f"generated/{name}.jpg", "source": "synthetic", "category": cat,
            "expected_severity_min": sev, "child_risk": child, "urgent": urgent, "plausible": plausible,
            "pair_id": pid, "pair_role": role, "fixed": fixed, "notes": notes,
        })
    with open(labels_path, "w") as fh:
        json.dump(labels, fh, indent=2, ensure_ascii=False)
    return len(labels)


def run(cmd: list) -> str:
    res = subprocess.run(cmd, capture_output=True, text=True)
    return f"{cmd[cmd.index('--output') + 1].rsplit('/', 1)[-1]}: rc={res.returncode} {res.stderr.strip()[-300:]}"


def main(out: str) -> None:
    os.makedirs(out, exist_ok=True)
    for stage in ("gen", "edit"):
        jobs = []
        if stage == "gen":
            for name, (size, prompt) in GEN.items():
                if not os.path.exists(f"{out}/{name}.jpg"):
                    jobs.append(["uv", "run", "-q", f"{SKILL}/generate.py", "--prompt", prompt, "--size", size,
                                 "--quality", "medium", "--output-format", "jpeg", "--output", f"{out}/{name}.jpg"])
        else:
            for name, (src, prompt) in EDIT.items():
                if not os.path.exists(f"{out}/{name}.jpg") and os.path.exists(f"{out}/{src}.jpg"):
                    jobs.append(["uv", "run", "-q", f"{SKILL}/edit.py", "--prompt", prompt,
                                 "--images", f"{out}/{src}.jpg", "--size", "1024x1024", "--quality", "medium",
                                 "--output-format", "jpeg", "--output", f"{out}/{name}.jpg"])
        with ThreadPoolExecutor(max_workers=5) as pool:
            for line in pool.map(run, jobs):
                print(line, flush=True)
    print("labels.json entries:", merge_labels(out))


if __name__ == "__main__":
    main(os.path.join(os.path.dirname(os.path.abspath(__file__)), "generated"))
