# HoTH eval results

- Model: `muse-spark-1.3` (from `prompts.json` `models.vision`). Prompts, JSON schemas and image preprocessing (<=1024 px, JPEG q0.82, reasoning effort as in the app) are **exactly those shipped in the iOS app** (`ios/HoTH/Resources/prompts.json`).
- Run: 2026-11-01 10:53 UTC, 62 API calls.
- Final priority = Python port of the app's deterministic `PriorityAgent` floors (no interview answers, no map POI).

## Per-case results

| Image | Source | Expected | Predicted | Severity (model → final) | Expected min | Plausibility flag | Latency |
|---|---|---|---|---|---|---|---|
| `real_playground_equipment_1.jpg` | Commons | playground_equipment | not_an_issue | low → **low** | medium | yes | 10.5 s |
| `real_playground_equipment_2.jpg` | Commons | playground_equipment | playground_equipment | high → **critical** (CRITICAL — child safety) | medium | no | 11.6 s |
| `real_playground_equipment_3.jpg` | Commons | playground_equipment | playground_equipment | medium → **medium** | low | no | 10.9 s |
| `real_playground_equipment_4.jpg` | Commons | playground_equipment | playground_equipment | high → **critical** (CRITICAL — child safety) | high | no | 6.6 s |
| `real_pothole_pavement_1.jpg` | Commons | pothole_pavement | pothole_pavement | critical → **critical** | high | no | 6.3 s |
| `real_pothole_pavement_2.jpg` | Commons | pothole_pavement | pothole_pavement | high → **high** | medium | no | 5.7 s |
| `real_pothole_pavement_3.jpg` | Commons | pothole_pavement | pothole_pavement | high → **high** | low | no | 7.4 s |
| `real_electrical_hazard_1.jpg` | Commons | electrical_hazard | electrical_hazard | critical → **critical** | high | no | 5.4 s |
| `real_electrical_hazard_2.jpg` | Commons | electrical_hazard | electrical_hazard | high → **critical** | high | no | 10.3 s |
| `real_electrical_hazard_3.jpg` | Commons | electrical_hazard | electrical_hazard | high → **critical** | high | no | 6.0 s |
| `real_open_manhole_1.jpg` | Commons | open_manhole | open_manhole | critical → **critical** (CRITICAL — open manhole) | high | no | 7.7 s |
| `real_open_manhole_2.jpg` | Commons | open_manhole | open_manhole | critical → **critical** (CRITICAL — open manhole) | critical | no | 12.1 s |
| `real_open_manhole_3.jpg` | Commons | open_manhole | open_manhole | high → **critical** (CRITICAL — open manhole) | medium | no | 6.6 s |
| `real_open_manhole_4.jpg` | Commons | open_manhole | open_manhole | critical → **critical** (CRITICAL — open manhole) | high | no | 9.4 s |
| `real_waste_overflow_dumping_1.jpg` | Commons | waste_overflow_dumping | waste_overflow_dumping | medium → **medium** | medium | no | 10.4 s |
| `real_waste_overflow_dumping_2.jpg` | Commons | waste_overflow_dumping | waste_overflow_dumping | medium → **medium** | medium | no | 5.8 s |
| `real_waste_overflow_dumping_3.jpg` | Commons | waste_overflow_dumping | waste_overflow_dumping | medium → **medium** | medium | no | 11.0 s |
| `real_waste_overflow_dumping_4.jpg` | Commons | waste_overflow_dumping | waste_overflow_dumping | medium → **medium** | low | no | 4.8 s |
| `real_blocked_accessibility_1.jpg` | Commons | blocked_accessibility | blocked_accessibility | medium → **medium** | medium | no | 7.2 s |
| `real_blocked_accessibility_2.jpg` | Commons | blocked_accessibility | blocked_accessibility | medium → **medium** | medium | no | 5.9 s |
| `real_blocked_accessibility_3.jpg` | Commons | blocked_accessibility | blocked_accessibility | medium → **medium** | medium | no | 9.5 s |
| `real_blocked_accessibility_4.jpg` | Commons | blocked_accessibility | blocked_accessibility | medium → **medium** | low | no | 11.6 s |
| `real_water_leak_1.jpg` | Commons | water_leak | water_leak | medium → **medium** | low | no | 4.9 s |
| `real_water_leak_2.jpg` | Commons | water_leak | water_leak | high → **high** | medium | no | 6.4 s |
| `real_water_leak_3.jpg` | Commons | water_leak | not_an_issue | low → **low** | low | yes | 9.6 s |
| `real_not_an_issue_1.jpg` | Commons | not_an_issue | not_an_issue | low → **low** | low | yes | 6.7 s |
| `real_other_1.jpg` | Commons | other | other | medium → **medium** | low | no | 5.5 s |
| `real_not_an_issue_3.jpg` | Commons | not_an_issue | not_an_issue | low → **low** | low | yes | 5.8 s |
| `real_not_an_issue_2.jpg` | Commons | not_an_issue | not_an_issue | low → **low** | low | yes | 9.9 s |
| `syn_playground_springrider.jpg` | AI-generated | playground_equipment | playground_equipment | critical → **critical** (CRITICAL — child safety) | high | no | 6.3 s |
| `syn_fitness_equipment_1.jpg` | AI-generated | fitness_equipment | fitness_equipment | high → **high** | medium | no | 12.2 s |
| `syn_open_manhole_1.jpg` | AI-generated | open_manhole | open_manhole | critical → **critical** (CRITICAL — open manhole) | critical | no | 6.5 s |
| `syn_fake_screen_pothole.jpg` | AI-generated | pothole_pavement | pothole_pavement | medium → **medium** | low | yes | 11.4 s |
| `syn_fake_printed_photo.jpg` | AI-generated | waste_overflow_dumping | waste_overflow_dumping | low → **low** | low | yes | 11.1 s |
| `syn_fake_stock_watermark.jpg` | AI-generated | playground_equipment | playground_equipment | high → **critical** (CRITICAL — child safety) | low | yes | 9.2 s |
| `syn_fake_cartoon_pothole.jpg` | AI-generated | pothole_pavement | not_an_issue | low → **low** | low | yes | 5.0 s |
| `syn_fake_meme.jpg` | AI-generated | pothole_pavement | pothole_pavement | high → **high** | low | yes | 10.6 s |
| `syn_fake_unrelated.jpg` | AI-generated | not_an_issue | not_an_issue | low → **low** | low | yes | 4.3 s |
| `syn_pair1_before.jpg` | AI-generated | waste_overflow_dumping | waste_overflow_dumping | medium → **medium** | medium | no | 4.8 s |
| `syn_pair1_after.jpg` | AI-generated | waste_overflow_dumping | waste_overflow_dumping | low → **low** | low | no | 7.8 s |
| `syn_pair2_before.jpg` | AI-generated | pothole_pavement | pothole_pavement | high → **high** | medium | no | 9.1 s |
| `syn_pair2_after.jpg` | AI-generated | pothole_pavement | pothole_pavement | high → **high** | medium | no | 8.1 s |
| `syn_pair3_before.jpg` | AI-generated | playground_equipment | not_an_issue | low → **low** | high | yes | 7.7 s |
| `syn_pair3_after.jpg` | AI-generated | playground_equipment | not_an_issue | low → **low** | low | yes | 7.2 s |
| `syn_pair4_before.jpg` | AI-generated | other | other | high → **high** | low | no | 8.1 s |
| `syn_pair4_after.jpg` | AI-generated | other | not_an_issue | low → **low** | low | yes | 6.8 s |
| `syn_pair5_before.jpg` | AI-generated | electrical_hazard | electrical_hazard | critical → **critical** | critical | no | 7.6 s |
| `syn_pair5_after.jpg` | AI-generated | electrical_hazard | not_an_issue | low → **low** | low | yes | 7.2 s |

## Metrics

| Metric | Result |
|---|---|
| Category accuracy (plausible items) | 36/42 (86%) |
| Severity >= expected min, model proposal | 40/42 (95%) |
| Severity >= expected min, final priority (with floors) | 40/42 (95%) |
| Urgent-hazard recall (>= high), model / final | 11/12 (92%) / 11/12 (92%) |
| Child-risk recall (final >= high OR child_use_equipment OR child_present) | 12/15 (80%) |
| Implausible images flagged | 6/6 (100%) |
| False-flag rate, plausible real issues | 6/39 (15%) |
| False-flag rate, all plausible (incl. not_an_issue, which *should* be flagged) | 9/42 (21%) |
| Same-issue accuracy | 6/6 (100%) |
| Fix-verification accuracy | 5/5 (100%) |
| Latency mean / p95 per call | 7.2 s / 11.6 s |
| Calls slower than the app's 60 s timeout | 0 |
| Tokens in / out (of which reasoning) | 143,158 / 68,136 (35,744) |
| Estimated cost | $0.416 (at $1.25 / 1M input, $0.15 / 1M cached input, $4.25 / 1M output) |

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

## Fix verification

| Pair | Expected resolved | Predicted | Same location | Model reason |
|---|---|---|---|---|
| pair1 | False | False | True | Bins are now closed and the sidewalk is largely cleared, but two black trash bags still remain on the sidewalk left of the bins. |
| pair2 | False | False | True | The pothole is only half-filled with new asphalt; a large open gravel section remains at the same street edge. |
| pair3 | True | True | True | Both swings hang properly in AFTER with intact seats and chains; the twisted right seat seen in BEFORE is now straight, same playground background. |
| pair4 | True | True | True | The broken seat slats seen in BEFORE are replaced and intact in AFTER, with the fallen slat removed from the pavement. |
| pair5 | True | True | True | The electrical cabinet door that was open with exposed wiring in BEFORE is now closed and latched in AFTER, with no wiring visible. |

## Same-issue pairs

| New | Existing | Expected | Predicted |
|---|---|---|---|
| `variant:generated/syn_pair2_before.jpg` | `generated/syn_pair2_before.jpg` | True | True |
| `variant:real/real_open_manhole_4.jpg` | `real/real_open_manhole_4.jpg` | True | True |
| `variant:real/real_playground_equipment_2.jpg` | `real/real_playground_equipment_2.jpg` | True | True |
| `real/real_pothole_pavement_2.jpg` | `real/real_pothole_pavement_1.jpg` | False | False |
| `real/real_open_manhole_1.jpg` | `real/real_open_manhole_4.jpg` | False | False |
| `real/real_waste_overflow_dumping_2.jpg` | `generated/syn_pair1_before.jpg` | False | False |

## Where it fails

- `real_playground_equipment_1.jpg`: category not_an_issue instead of playground_equipment (Wide shot of a park playground; the broken swing is small in frame. Low-salience hard case.)
- `real_playground_equipment_1.jpg`: final priority low below expected medium (model said: All play equipment and surfacing appear intact with no visible breakage or immediate danger.)
- `real_playground_equipment_1.jpg`: real photo falsely flagged as implausible (Photo looks like a direct daytime phone capture of a park.)
- `real_water_leak_3.jpg`: category not_an_issue instead of water_leak (Water from a burst pipe running along an unpaved street; subtle.)
- `real_water_leak_3.jpg`: real photo falsely flagged as implausible (Daylight photo of a street with no obvious manipulation.)
- `syn_pair3_before.jpg`: category not_an_issue instead of playground_equipment (Swing with snapped chain, seat hanging from one chain.)
- `syn_pair3_before.jpg`: final priority low below expected high (model said: Both swing seats and chains appear intact with no visible damage or immediate danger.)
- `syn_pair3_before.jpg`: real photo falsely flagged as implausible (Live photo of a playground with no visible issue.)
- `syn_pair3_after.jpg`: category not_an_issue instead of playground_equipment (Fixed: swing re-hung on two new chains.)
- `syn_pair3_after.jpg`: real photo falsely flagged as implausible (Photo appears to be a direct live capture of an outdoor playground.)
- `syn_pair4_after.jpg`: category not_an_issue instead of other (Fixed: slats replaced.)
- `syn_pair4_after.jpg`: real photo falsely flagged as implausible (Photo looks like a direct live capture of an intact bench.)
- `syn_pair5_after.jpg`: category not_an_issue instead of electrical_hazard (Fixed: cabinet door re-hung and closed.)
- `syn_pair5_after.jpg`: real photo falsely flagged as implausible (Live photo of an intact street cabinet with no visible problem.)

## Not evaluated

- `chat_intake` slot filling (no scripted transcripts yet).
