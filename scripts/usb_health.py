#!/usr/bin/env python3
# Per-MCU serial retransmits and comm faults from every klippy.log on the printer.
# Run on the printer: python3 scripts/usb_health.py. Baseline and history: docs/usb-health.md
import re, sys, glob, os, datetime, collections
logs = sorted(glob.glob(os.path.expanduser('~/printer_data/logs/klippy.log.2*'))) + [os.path.expanduser('~/printer_data/logs/klippy.log')]
start_re = re.compile(r'^Start printer at .*\((\d+\.\d+) (\d+\.\d+)\)')
def wall(unix0, mono0, t):
    return datetime.datetime.fromtimestamp(unix0 + (t - mono0)).strftime('%m-%d %H:%M:%S')
episodes = []                       # (wall, mcu, delta_retx_bytes, delta_invalid, printing, srtt, rto)
totals = collections.defaultdict(lambda: [0, 0, 0])   # mcu -> [retx bytes, invalid bytes, write bytes]
timeouts = collections.Counter(); shutdowns = []
for fn in logs:
    unix0 = mono0 = None; prev = {}
    with open(fn, errors='replace') as f:
        for line in f:
            if 'Log rollover at' in line:
                # rotated continuation: anchor wall time on the rollover stamp
                ts = line.split('Log rollover at', 1)[1].strip(' =\n')
                unix0 = datetime.datetime.strptime(ts, '%a %b %d %H:%M:%S %Y').timestamp()
                mono0 = None
                continue
            if line.startswith('Start printer at'):
                m = start_re.match(line)
                if m: unix0, mono0 = float(m.group(1)), float(m.group(2))
                prev = {}
                continue
            if line.startswith(('Timeout with MCU', 'Lost communication')):
                shutdowns.append((os.path.basename(fn), line.strip()[:90]))
            if 'Timeout on connect' in line:
                timeouts[line.split("'")[1]] += 1
            if not line.startswith('Stats ') or unix0 is None:
                continue
            t = float(line.split()[1].rstrip(':'))
            if mono0 is None:
                mono0 = t
            printing = 'sd_pos=' in line
            sec = None; vals = collections.defaultdict(dict)
            for tok in line.split()[2:]:
                if tok.endswith(':') and '=' not in tok:
                    sec = tok[:-1]; continue
                if '=' in tok and sec:
                    k, _, v = tok.partition('=')
                    vals[sec][k] = v
            for mcu, d in vals.items():
                if 'bytes_retransmit' not in d: continue
                r, inv, w = int(d['bytes_retransmit']), int(d.get('bytes_invalid', 0)), int(d['bytes_write'])
                if mcu in prev:
                    pr, pinv, pw = prev[mcu]
                    dr, dinv, dw = r - pr, inv - pinv, w - pw
                    if dr < 0 or dw < 0:      # counters reset (reconnect)
                        dr, dinv, dw = r, inv, w
                    totals[mcu][0] += dr; totals[mcu][1] += dinv; totals[mcu][2] += dw
                    if dr > 0 or dinv > 0:
                        episodes.append((wall(unix0, mono0, t), mcu, dr, dinv, printing, d.get('srtt'), d.get('rto')))
                prev[mcu] = (r, inv, w)
print("=== totals since", os.path.basename(logs[0]))
for mcu, (r, inv, w) in sorted(totals.items(), key=lambda x: -x[1][0]):
    print(f"  {mcu:14s} retransmit {r:>9d} B  invalid {inv:>6d} B  written {w/1e6:9.1f} MB  ratio {r/max(w,1)*1e6:8.1f} ppm")
print("=== connect timeouts:", dict(timeouts))
print("=== MCU timeout/lost-comm events:", len(shutdowns))
for s in shutdowns[:12]: print("  ", s)
# group episodes per day/hour/mcu
by = collections.defaultdict(lambda: [0, 0, 0, 0])
for w_, mcu, dr, dinv, pr, srtt, rto in episodes:
    k = (w_[:8], mcu)          # 'MM-DD HH' bucket
    by[k][0] += 1; by[k][1] += dr; by[k][2] += dinv; by[k][3] += pr
print("=== retransmit activity by hour (intervals with retx, bytes, invalid, intervals-while-printing)")
for k in sorted(by):
    n, dr, dinv, pr = by[k]
    print(f"  {k[0]}h {k[1]:14s} n={n:4d} retx={dr:7d}B invalid={dinv:5d}B printing={pr}")
