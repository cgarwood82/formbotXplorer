#!/usr/bin/env python3
"""Assert PRINT_START's bed heat-soak behaviour.

The AC bed reaches its setpoint long before the plate is thermally saturated,
so probing immediately after M190 measures a bed that is still moving. The soak
holds at temperature before TANGO_TIME runs z-tilt, mesh and touch-home.

    ~/klippy-env/bin/python scripts/test_print_start_soak.py
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from klipper_macro_harness import Checker, Dotted, lines, render  # noqa: E402

CFG = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "config", "Macros", "print_control.cfg")

check = Checker()


def printer(soak_var=15):
    variables = {
        "tprobe": 170, "park_safe_dist": 80, "idexsquish": -0.08,
        "x1offset": 0.25, "y1offset": 0.11, "z1offset": -0.04,
    }
    if soak_var is not None:
        variables["bed_soak_min"] = soak_var
    return Dotted(
        save_variables=Dotted(variables=Dotted(variables)),
        toolhead=Dotted(homed_axes="xyz", extruder="extruder",
                        position=[0.0, 0.0, 10.0, 0.0]),
        configfile=Dotted(settings={
            "carriage gantry0": Dotted(position_max=392.0, position_min=77.5),
            "dual_carriage gantry1": Dotted(position_max=392.0, position_min=-1.0),
        }),
        exclude_object=Dotted(objects=[]),
        print_stats=Dotted(state="printing"),
        skew_correction=Dotted(current_profile_name="gantry0"),
    )


def go(params, soak_var=15):
    p = dict(BED=105, EXTRUDER=260, INITIAL_TOOL=0, MIN_Y=185.0, MAX_Y=329.0)
    p.update(params)
    return render(CFG, "PRINT_START", p, printer(soak_var))


DWELL = re.compile(r"^G4\s+P(\d+)")


def before_tango(text):
    """Lines up to TANGO_TIME. PRINT_START already ends with an unrelated
    G4 P10000 nozzle dwell after probing; the soak is by definition the
    dwelling that happens BEFORE probing, so scope the measurement there."""
    seq = lines(text)
    i = next((i for i, l in enumerate(seq) if l.startswith("TANGO_TIME")), len(seq))
    return seq[:i]


def dwell_ms(text):
    return sum(int(m.group(1))
               for m in (DWELL.match(l) for l in before_tango(text)) if m)


print("PRINT_START bed soak")

# --- duration ------------------------------------------------------------
out = go({})
check("default soak uses bed_soak_min (15 min)", dwell_ms(out) == 15 * 60000,
      "%d ms" % dwell_ms(out))

out = go({}, soak_var=None)
check("falls back to 15 min when bed_soak_min absent",
      dwell_ms(out) == 15 * 60000, "%d ms" % dwell_ms(out))

out = go({}, soak_var=25)
check("bed_soak_min=25 honoured", dwell_ms(out) == 25 * 60000, "%d ms" % dwell_ms(out))

out = go({"SOAK": 5})
check("SOAK=5 overrides the variable", dwell_ms(out) == 5 * 60000, "%d ms" % dwell_ms(out))

# --- skip conditions -----------------------------------------------------
check("SOAK=0 emits no dwell", dwell_ms(go({"SOAK": 0})) == 0)
check("BED=0 emits no dwell", dwell_ms(go({"BED": 0})) == 0)

# --- placement -----------------------------------------------------------
seq = lines(go({}))
i_m190 = next((i for i, l in enumerate(seq) if l.startswith("M190")), None)
i_tango = next((i for i, l in enumerate(seq) if l.startswith("TANGO_TIME")), None)
pre = before_tango(go({}))
i_dwell = next((i for i, l in enumerate(pre) if DWELL.match(l)), None)
i_last = max((i for i, l in enumerate(pre) if DWELL.match(l)), default=None)

check("soak starts after the bed reaches target (M190)",
      None not in (i_m190, i_dwell) and i_m190 < i_dwell,
      "M190@%s dwell@%s" % (i_m190, i_dwell))
check("soak finishes before TANGO_TIME probes",
      None not in (i_last, i_tango) and i_last < i_tango,
      "lastdwell@%s tango@%s" % (i_last, i_tango))

# Nozzle must not sit fractions of a mm above a 105C plate for 15 minutes.
i_z = next((i for i, l in enumerate(pre)
            if re.match(r"^G1\s+Z\d", l) and i < (i_dwell or 0)), None)
check("Z raised before the first dwell", i_z is not None, "no G1 Z before dwell")

# --- feedback ------------------------------------------------------------
msgs = [l for l in pre if l.startswith("SET_DISPLAY_TEXT") and "min left" in l]
check("one countdown message per minute", len(msgs) == 15, "%d messages" % len(msgs))
check("countdown runs 15 down to 1",
      "15 min left" in msgs[0] and "1 min left" in msgs[-1] if msgs else False,
      msgs[:1] + msgs[-1:])
check("soak is announced and closed",
      any("15 min at" in l for l in pre) and any("soak complete" in l.lower() for l in pre))

# A dwell must never be emitted without its countdown message, or the UI goes
# quiet mid-soak and it looks hung again.
pre_soak = [l for l in pre if DWELL.match(l) or "min left" in l]
check("every dwell is preceded by a countdown message",
      all("min left" in pre_soak[i - 1]
          for i, l in enumerate(pre_soak) if DWELL.match(l) and i > 0)
      and len(pre_soak) == 30, pre_soak[:4])

sys.exit(check.report())
