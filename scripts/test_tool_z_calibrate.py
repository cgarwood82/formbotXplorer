#!/usr/bin/env python3
"""Render tool_z_calibrate.cfg the way Klipper will and assert its behaviour.

Klipper builds its template environment as jinja2.Environment('{%','%}','{','}')
(gcode_macro.py:83), so rendering with the same delimiters and a stand-in
`printer` object reproduces the exact gcode the macro would emit.

The property that matters most here is the last test: the carriage
choreography must be byte-identical no matter which TOOL= is requested, so a
single-tool run never takes a clearance path the full run doesn't.

On the printer, run it with klippy-env's interpreter -- system python has no
jinja2:

    ~/klippy-env/bin/python scripts/test_tool_z_calibrate.py
    ~/klippy-env/bin/python scripts/test_tool_z_calibrate.py \
        ~/printer_data/config/Macros/tool_z_calibrate.cfg
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from klipper_macro_harness import Checker, Dotted, RaisedError, lines, render  # noqa: E402

# Defaults to the copy in this repo; override with argv[1] to test a live file:
#   scripts/test_tool_z_calibrate.py ~/printer_data/config/Macros/tool_z_calibrate.cfg
CFG = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "config", "Macros", "tool_z_calibrate.cfg")


def printer_obj(last_result=(0.25, 0.11, 0.04), state="standby"):
    return Dotted(
        save_variables=Dotted(variables=Dotted({
            "tprobe": 170,
            "x1offset": 0.246875, "y1offset": 0.107578, "z1offset": -0.04,
            "x2offset": 1.251016, "y2offset": 0.111,    "z2offset": -0.0575,
            "x3offset": 0.746875, "y3offset": 0.2119,   "z3offset": -0.0875,
        })),
        print_stats=Dotted(state=state),
        tools_calibrate=Dotted(last_result=list(last_result) if last_result else None),
    )


def render_macro(macro, params, printer=None):
    return render(CFG, macro, params, printer if printer is not None else printer_obj())


_check = Checker()


def check(name, cond, detail=""):
    _check(name, cond, detail)


# ---------------------------------------------------------------- _TZC_SAVE
print("_TZC_SAVE")

for tool in (1, 2, 3):
    out = render_macro("_TZC_SAVE", {"TOOL": tool, "DRY_RUN": 0})
    saves = [l for l in lines(out) if l.startswith("SAVE_VARIABLE")]
    check("T%d writes exactly one variable" % tool, len(saves) == 1, saves)
    check("T%d writes z%doffset" % (tool, tool),
          saves and saves[0].startswith("SAVE_VARIABLE VARIABLE=z%doffset" % tool), saves)

for tool in (1, 2, 3):
    out = render_macro("_TZC_SAVE", {"TOOL": tool, "DRY_RUN": 0})
    check("T%d never writes x/y" % tool,
          not re.search(r"SAVE_VARIABLE\s+VARIABLE=[xy]\d?offset", out))

out = render_macro("_TZC_SAVE", {"TOOL": 2, "DRY_RUN": 1})
check("DRY_RUN writes nothing", "SAVE_VARIABLE" not in out)
check("DRY_RUN still reports", "M118" in out)

# sign convention must match _save_offsets_t1: z = last_result[2] * -1
out = render_macro("_TZC_SAVE", {"TOOL": 1, "DRY_RUN": 0},
             printer_obj(last_result=(0.0, 0.0, 0.0875)))
check("sign convention negates dz", "VALUE=-0.0875" in out,
      [l for l in lines(out) if "SAVE_VARIABLE" in l])

try:
    render_macro("_TZC_SAVE", {"TOOL": 1, "DRY_RUN": 0}, printer_obj(last_result=None))
    check("missing probe result raises", False, "no error raised")
except RaisedError:
    check("missing probe result raises", True)

# ------------------------------------------------- CALIBRATE_TOOL_Z_OFFSETS
print("CALIBRATE_TOOL_Z_OFFSETS")

full = render_macro("CALIBRATE_TOOL_Z_OFFSETS", {})
check("main macro never saves directly", "SAVE_VARIABLE" not in full)
for tool in (1, 2, 3):
    check("all-run invokes _TZC_SAVE TOOL=%d" % tool,
          re.search(r"_TZC_SAVE\s+TOOL=%d\b" % tool, full) is not None)

for tool in (1, 2, 3):
    out = render_macro("CALIBRATE_TOOL_Z_OFFSETS", {"TOOL": tool})
    want = re.search(r"_TZC_SAVE\s+TOOL=%d\b" % tool, out) is not None
    others = [t for t in (1, 2, 3) if t != tool]
    none_other = all(re.search(r"_TZC_SAVE\s+TOOL=%d\b" % o, out) is None for o in others)
    check("TOOL=%d probes only T%d" % (tool, tool), want and none_other)

try:
    render_macro("CALIBRATE_TOOL_Z_OFFSETS", {"TOOL": 4})
    check("bad TOOL raises", False, "no error raised")
except RaisedError:
    check("bad TOOL raises", True)

# Tool0 issues G1 moves (and three PARK_extruder*, which do too), so the
# machine must be homed before it is ever invoked. Klipper comes up unhomed
# after any restart, which is precisely when this macro gets run.
seq = lines(full)
first_home = next((i for i, l in enumerate(seq) if l.startswith(("CHECK_HOME", "G28"))), None)
first_tool = next((i for i, l in enumerate(seq) if re.match(r"^Tool\d\b", l)), None)
check("homes before the first Tool0",
      first_home is not None and first_tool is not None and first_home < first_tool,
      "home@%s tool@%s" % (first_home, first_tool))

try:
    render_macro("CALIBRATE_TOOL_Z_OFFSETS", {}, printer_obj(state="printing"))
    check("refuses while printing", False, "no error raised")
except RaisedError:
    check("refuses while printing", True)

# Tool0..3 apply SET_GCODE_OFFSET from variables.cfg. The choreography moves to
# exact axis limits (G1 Y392 vs gantry0 position_max 392), so ANY live offset
# pushes it out of range. Every move must therefore be preceded by a zeroing of
# the live offset since the last tool activation. This is what ZERO_TOOL_OFFSETS
# bought the original macro -- we get it without writing to variables.cfg.
ZERO = re.compile(r"^SET_GCODE_OFFSET\s+X=0\s+Y=0\s+Z=0")
ACTIVATES = re.compile(r"^(Tool\d|ACTIVATE_EXTRUDER)\b")
MOVES = re.compile(r"^(G0|G1)\s+[XYZ]|^CALIBRATE_MOVE_OVER_PROBE")

for tool in (0, 1, 2, 3):
    out = render_macro("CALIBRATE_TOOL_Z_OFFSETS", {} if tool == 0 else {"TOOL": tool})
    dirty, bad = None, []
    for ln in lines(out):
        if ACTIVATES.match(ln):
            dirty = ln
        elif ZERO.match(ln):
            dirty = None
        elif MOVES.match(ln) and dirty:
            bad.append((dirty, ln))
    label = "all" if tool == 0 else "TOOL=%d" % tool
    check("%s: no move under a live tool offset" % label, not bad, bad[:2])

# --- the safety property -------------------------------------------------
# Strip everything TOOL= is allowed to gate (heat, brush, probe, save) and the
# remaining motion must be identical across every invocation.
GATED = re.compile(
    r"^(SET_HEATER_TEMPERATURE|TEMPERATURE_WAIT|Brush_Tool|CALIBRATE_MOVE_OVER_PROBE"
    r"|TOOL_CALIBRATE_TOOL_OFFSET|TOOL_LOCATE_SENSOR|_TZC_SAVE|M118)")


def motion(text):
    return [l for l in lines(text) if not GATED.match(l)]


base = motion(full)
for tool in (1, 2, 3):
    got = motion(render_macro("CALIBRATE_TOOL_Z_OFFSETS", {"TOOL": tool}))
    diff = [(i, a, b) for i, (a, b) in enumerate(zip(base, got)) if a != b]
    check("TOOL=%d motion identical to full run" % tool,
          got == base, diff[:3] or "len %d vs %d" % (len(base), len(got)))

sys.exit(_check.report())
