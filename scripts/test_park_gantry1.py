#!/usr/bin/env python3
"""Assert parking gantry1 never drives it within park_safe_dist of gantry0.

park_min_y is derived from the model (front edge - park_safe_dist - 10), which
assumes gantry0 is already over the model. It is not: T4 runs Tool1 ->
PARK_extruder straight after TANGO_TIME, with gantry0 still at the touch-home
point (Y=171). On 2026-09-22 a model whose front edge was Y=220.3 gave
park_min_y=130.3, gantry1 was driven to 40.7mm from gantry0, and AFC's
restore_pos then brought gantry0 back onto it. Klipper's gantry1
safe_distance (27) is deliberately below the real clearance, so it did not stop
either move.

    ~/klippy-env/bin/python scripts/test_park_gantry1.py
"""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from klipper_macro_harness import Checker, Dotted, lines, render  # noqa: E402

CFG = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "config", "01__User_Custom__CFG", "overrides.cfg")

Coord = collections.namedtuple("Coord", "x y z e")
check = Checker()


def printer(g0_y, park_min=130.321, pmode=0):
    return Dotted(
        save_variables=Dotted(variables=Dotted(
            park_safe_dist=80, pmode=pmode,
            shaper_type_xt0="mzv", shaper_freq_xt0=60,
            shaper_type_yt0="mzv", shaper_freq_yt0=40,
            shaper_type_xt1="mzv", shaper_freq_xt1=60,
            shaper_type_yt1="mzv", shaper_freq_yt1=40)),
        toolhead=Dotted(position=Coord(200.0, g0_y, 2.0, 0.0),
                        extruder="extruder"),
        configfile=Dotted(settings={
            "dual_carriage gantry1": Dotted(position_min=-1.0, position_max=392.0),
        }),
        **{"gcode_macro _XPLORER_VARIABLES": Dotted(
            park_min_y=park_min, park_max_y=392.0, sp_tch=18000)},
    )


def park_y(g0_y, **kw):
    seq = lines(render(CFG, "_PARK_GANTRY1", {}, printer(g0_y, **kw)))
    i = seq.index("SET_DUAL_CARRIAGE CARRIAGE=gantry1")
    moves = [l for l in seq[i:] if re.match(r"^G1\s+Y", l)]
    return float(re.match(r"^G1\s+Y(-?[\d.]+)", moves[0]).group(1)) if moves else None


print("gantry1 park clearance")

# The incident: gantry0 at touch-home Y=171, park_min_y 130.321.
y = park_y(171.0)
check("incident: gantry1 held 80mm in front of gantry0 (Y=91)",
      y is not None and abs(y - 91.0) < 1e-6, y)
check("incident: clearance to gantry0 >= park_safe_dist",
      y is not None and 171.0 - y >= 80 - 1e-6, y)

# gantry0 already well behind: the model-derived park spot is honoured.
y = park_y(392.0)
check("gantry0 at Y=392: park_min_y used unchanged",
      y is not None and abs(y - 130.321) < 1e-6, y)

# Never ask for a position past gantry1's own axis minimum.
y = park_y(77.5)
check("gantry0 at its minimum: clamped to gantry1 position_min (-1)",
      y is not None and abs(y - -1.0) < 1e-6, y)

# Parallel/multicolor modes park gantry1 at 0; still safe, still honoured.
y = park_y(171.0, pmode=2)
check("pmode 2: parks at 0", y is not None and abs(y) < 1e-6, y)

# A clamp means the model-derived spot was not reachable -- say so.
out = render(CFG, "_PARK_GANTRY1", {}, printer(171.0))
check("clamp is reported", "M118" in out and "91" in out, lines(out)[:2])
out = render(CFG, "_PARK_GANTRY1", {}, printer(392.0))
check("no report when not clamped", "M118" not in out)

# The wrappers must select gantry0 BEFORE the helper renders, so it reads
# gantry0's Y rather than whichever gantry happened to be active, and must not
# keep their own unclamped gantry1 move.
for macro in ("PARK_extruder", "PARK_extruder1"):
    seq = lines(render(CFG, macro, {}, printer(171.0)))
    i_sel = next((i for i, l in enumerate(seq)
                  if l == "SET_DUAL_CARRIAGE CARRIAGE=gantry0"), None)
    i_park = next((i for i, l in enumerate(seq) if l == "_PARK_GANTRY1"), None)
    check("%s: selects gantry0 before _PARK_GANTRY1" % macro,
          None not in (i_sel, i_park) and i_sel < i_park, seq[:4])
    check("%s: no direct G1 Y move of its own" % macro,
          not any(re.match(r"^G1\s+Y", l) for l in seq),
          [l for l in seq if l.startswith("G1")])

sys.exit(check.report())
