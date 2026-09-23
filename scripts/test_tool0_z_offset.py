#!/usr/bin/env python3
"""Assert T0 applies its own z0offset, like T1-T3 apply z1/z2/z3offset.

T0 is the Z reference: CARTOGRAPHER_TOUCH_HOME sets Z0 with T0's nozzle and
z1/z2/z3offset only bring the OTHER tools onto that plane. That left T0 as the
one tool with no trim of its own, so squishing T0's first layer meant moving
the reference and dragging every tool with it. z0offset is T0's trim: it shifts
T0 alone, because T1-T3 set their own absolute offsets at activation.

    ~/klippy-env/bin/python scripts/test_tool0_z_offset.py
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from klipper_macro_harness import Checker, Dotted, lines, render  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OVERRIDES = os.path.join(HERE, "..", "config", "01__User_Custom__CFG", "overrides.cfg")
IQEX = os.path.join(HERE, "..", "config", "Macros", "iqex-modes.cfg")

check = Checker()

OFFSETS = dict(x1offset=0.25, y1offset=0.11, z1offset=0.16,
               x2offset=0.2, y2offset=0.111, z2offset=-0.0575,
               x3offset=0.3, y3offset=0.2119, z3offset=-0.0875)


def printer(z0=-0.05, pmode=0, g1_mode="INACTIVE"):
    variables = dict(OFFSETS, pmode=pmode, park_safe_dist=80,
                     idexsquish=-0.08, tc_retract=0.5)
    if z0 is not None:
        variables["z0offset"] = z0
    return Dotted(
        save_variables=Dotted(variables=Dotted(variables)),
        toolhead=Dotted(extruder="extruder1", position=Dotted(x=200.0, y=171.0, z=2.0)),
        dual_carriage=Dotted(carriages={"dual_carriage gantry1": g1_mode,
                                        "dual_carriage t1": "INACTIVE"}),
        skew_correction=Dotted(current_profile_name="gantry0"),
        print_stats=Dotted(state="standby"),
        configfile=Dotted(settings={
            "dual_carriage gantry1": Dotted(position_min=-1.0, position_max=392.0),
        }),
        **{"gcode_macro _XPLORER_VARIABLES": Dotted(
            park_min_y=130.321, park_max_y=392.0, sp_tch=18000, sp_pmode=9000)},
    )


def final_z(cfg, macro, **kw):
    """The Z the tool activation leaves live: its LAST SET_GCODE_OFFSET Z=."""
    seq = lines(render(cfg, macro, {}, printer(**kw)))
    zs = [m.group(1) for m in
          (re.search(r"SET_GCODE_OFFSET.*\bZ=(-?[\d.]+)", l) for l in seq) if m]
    return float(zs[-1]) if zs else None


print("T0 z0offset")

# --- single-tool path ----------------------------------------------------
z = final_z(OVERRIDES, "Tool0")
check("Tool0 applies z0offset", z is not None and abs(z - -0.05) < 1e-9, z)

z = final_z(OVERRIDES, "Tool0", z0=None)
check("Tool0 falls back to 0 when z0offset is unset",
      z is not None and abs(z) < 1e-9, z)

z = final_z(OVERRIDES, "Tool0", z0=0.0)
check("z0offset=0 reproduces the old behaviour", z is not None and abs(z) < 1e-9, z)

# --- multicolor T0 phase -------------------------------------------------
z = final_z(IQEX, "_MC_TOOL0", pmode=5)
check("_MC_TOOL0 applies z0offset", z is not None and abs(z - -0.05) < 1e-9, z)

z = final_z(IQEX, "_MC_TOOL0", pmode=5, z0=None)
check("_MC_TOOL0 falls back to 0 when z0offset is unset",
      z is not None and abs(z) < 1e-9, z)

# --- the other tools must not move ---------------------------------------
for macro, want in [("Tool1", 0.16), ("Tool2", -0.0575), ("Tool3", -0.0875)]:
    z = final_z(OVERRIDES, macro)
    check("%s still applies its own offset (%s)" % (macro, want),
          z is not None and abs(z - want) < 1e-9, z)

z = final_z(IQEX, "_MC_TOOL1", pmode=5)
check("_MC_TOOL1 still applies z1offset", z is not None and abs(z - 0.16) < 1e-9, z)

sys.exit(check.report())
