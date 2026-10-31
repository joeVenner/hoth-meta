# Image credits

Bundled photos in `Assets.xcassets` come from the HoTH eval dataset (`tools/eval/dataset`).

## AI-generated

- Onboarding illustrations, empty states, level badges and the app icon: generated with OpenAI gpt-image-2 for HoTH.
- `seed_1/2/4/5/8/9/12`, `seed_fix_9` and all `demo_*` assets except `demo_pothole`, `demo_open_manhole`, `demo_waste`, `demo_water_leak` and `demo_blocked_path`: synthetic `syn_*` images (OpenAI gpt-image-2), not real photos.

## Wikimedia Commons photos

Resized to 1000 px (the 2026-10 `demo_*` additions to 1200 px) and re-encoded as JPEG; otherwise unmodified. CC BY-SA images remain under their original licence.

| Asset | Commons page | Author | License |
|---|---|---|---|
| seed_3 | https://commons.wikimedia.org/wiki/File:Damaged_street_light_pole,_300_block_of_E._26th_Street_(north_side),_Baltimore,_MD_21218_(47243240531).jpg | Baltimore Heritage from Baltimore, MD, USA | CC0 (http://creativecommons.org/publicdomain/zero/1.0/deed.en) |
| seed_6 | https://commons.wikimedia.org/wiki/File:Poste_bloqueando_a_cal%C3%A7ada_na_Avenida_Olindo_de_Miranda,_Almenara.jpg | OAlmenarense | CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0) |
| seed_7 | https://commons.wikimedia.org/wiki/File:Water_leak_in_Fortis_Green_Road,_Muswell_Hill_01.jpg | Philafrenzy | CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0) |
| seed_10 | https://commons.wikimedia.org/wiki/File:Pothole_in_Villeray,_Montr%C3%A9al.jpg | Miguel Tremblay | Public domain |
| seed_11 | https://commons.wikimedia.org/wiki/File:Fly_tipping_near_High_Beech,_Essex.jpg | The wub | CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0) |
| seed_13 | https://commons.wikimedia.org/wiki/File:BCA_pipe_burst_01_wetness.jpg | Sarang | Public domain |
| seed_14 | https://commons.wikimedia.org/wiki/File:A_pothole_in_Dilova_Street_in_Kyiv.jpg | Роман Рябенко | CC0 (http://creativecommons.org/publicdomain/zero/1.0/deed.en) |
| demo_pothole | https://commons.wikimedia.org/wiki/File:Potholes_in_Bengaluru_road.jpg | Mallikarjunasj | CC0 (http://creativecommons.org/publicdomain/zero/1.0/deed.en) |
| demo_open_manhole | https://commons.wikimedia.org/wiki/File:Open_Manhole_-_New_Orleans_September_2020.jpg | Bart Everson | CC BY 2.0 (https://creativecommons.org/licenses/by/2.0) |
| demo_waste | https://commons.wikimedia.org/wiki/File:Litter_bin_rubbish_Tottenham,_London,_England_1.jpg | Acabashi | CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0) |
| demo_water_leak | https://commons.wikimedia.org/wiki/File:Peacock_Street_water_main_break_984.jpg | Schwede66 | CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0) |
| demo_blocked_path | https://commons.wikimedia.org/wiki/File:A_car_blocking_the_sidewalk._(6147249829).jpg | Nathan Johnson | CC BY-SA 2.0 (https://creativecommons.org/licenses/by-sa/2.0) |

- `demo_fix_after_good_pothole`: derived locally from `demo_fix_after_bad` (the patched half mirrored over the unfilled half) so the crew demo has a matching full-repair photo; `demo_fix_after_good` is a swing from a different scene.
