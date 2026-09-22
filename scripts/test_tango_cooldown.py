#!/usr/bin/env python3
"""Assert TANGO_TIME turns head 0 off after probing, whatever lane is loaded.

TANGO_TIME heats `extruder` to 150C for the brush and touch-home. Prints whose
first tool is not on head 0 must not leave it holding 150C for the whole job.
AFC intercepts M104 and resolves T<n> through its lane map, then refuses with
"Not setting temperature for T0 since another lane is loaded" whenever head 0
holds any lane other than the one mapped to T0 -- so `M104 S0 T0` silently does
nothing. The cooldown has to address the heater by name.

    ~/klippy-env/bin/python scripts/test_tango_cooldown.py
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from klipper_macro_harness import Checker, Dotted, lines, render  # noqa: E402

CFG = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "config", "Macros", "bed_leveling.cfg")

check = Checker()

printer = Dotted(toolhead=Dotted(extruder="extruder"))

print("TANGO_TIME head 0 cooldown")

for params, label in [
    (dict(EXTRUDER=0, EXTRUDER1=265), "T4-only print"),
    (dict(EXTRUDER=1), "AFC-only print"),
    (dict(EXTRUDER=1, EXTRUDER2=250), "AFC + T5 print"),
]:
    seq = lines(render(CFG, "TANGO_TIME", params, printer))
    i_touch = next((i for i, l in enumerate(seq)
                    if l.startswith("CARTOGRAPHER_TOUCH_HOME")), None)
    after = seq[i_touch + 1:] if i_touch is not None else []

    check("%s: head 0 set to 0 by name after touch-home" % label,
          "SET_HEATER_TEMPERATURE HEATER=extruder TARGET=0" in after, after)
    check("%s: no T-addressed M104 (AFC lane map would swallow it)" % label,
          not any(re.match(r"^M104\b.*\bT\d", l) for l in seq),
          [l for l in seq if l.startswith("M104")])

sys.exit(check.report())
