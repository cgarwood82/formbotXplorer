#!/usr/bin/env python3
"""Render Klipper gcode_macro templates the way Klipper itself will.

Klipper builds its template environment as jinja2.Environment('{%','%}','{','}')
(gcode_macro.py:83), so rendering with those delimiters and a stand-in `printer`
object reproduces the exact gcode a macro would emit -- which makes macros
testable without a printer.

On the printer, run tests with klippy-env's interpreter; system python has no
jinja2:

    ~/klippy-env/bin/python scripts/test_<name>.py
"""
import configparser

import jinja2


class Dotted(dict):
    """dict that also allows attribute access, like Klipper's printer object."""

    def __getattr__(self, k):
        try:
            return self[k]
        except KeyError:
            raise AttributeError(k)


class RaisedError(Exception):
    """Raised in place of Klipper's action_raise_error."""


def klipper_config(path):
    """Parse a .cfg exactly as Klipper's configfile.py does."""
    cp = configparser.RawConfigParser(strict=False,
                                      inline_comment_prefixes=(';', '#'))
    cp.read(path)
    return cp


def render(path, macro, params, printer):
    """Render one [gcode_macro <macro>] from `path` and return the emitted gcode."""
    src = klipper_config(path).get("gcode_macro " + macro, "gcode")

    def raise_error(msg):
        raise RaisedError(str(msg))

    ctx = {
        # Klipper passes every macro parameter through as a string.
        "params": {k: str(v) for k, v in params.items()},
        "printer": printer,
        "action_raise_error": raise_error,
        "action_respond_info": lambda m: "",
        "action_emergency_stop": lambda *a: "",
    }
    return jinja2.Environment('{%', '%}', '{', '}').from_string(src).render(**ctx)


def lines(text):
    """Emitted gcode as a list of non-blank, stripped lines."""
    return [ln.strip() for ln in text.splitlines() if ln.strip()]


class Checker:
    """Minimal pass/fail reporter; exit_code() is 1 if anything failed."""

    def __init__(self):
        self.failures = []

    def __call__(self, name, cond, detail=""):
        if cond:
            print("  ok   %s" % name)
        else:
            print("  FAIL %s %s" % (name, detail))
            self.failures.append(name)

    def raises(self, name, fn):
        try:
            fn()
        except RaisedError:
            self(name, True)
            return
        self(name, False, "no error raised")

    def report(self):
        print()
        if self.failures:
            print("FAILED: %d" % len(self.failures))
            return 1
        print("PASS")
        return 0
