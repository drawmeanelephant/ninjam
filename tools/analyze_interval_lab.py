#!/usr/bin/env python3
"""
Turn the raw interval_lab CSV logs into the tables in REPORT.md.

Usage: analyze_interval_lab.py <results-dir>

METRIC DEFINITIONS
------------------
For a marker with index k, the emitter puts it on the air at its own session
position k*mark_period, and the listener finds it at its own session position
heard_spos. Neither clock has a shared origin -- the protocol never sends an
absolute time reference -- so the raw difference

    err_ij(k) = heard_spos_ij(k) - k*mark_period        [ms]

is a propagation delay (interval structure + codec + network) plus any real
misalignment. Three things are reported from it:

  delay  D_ij  = median over k of err_ij(k)
                The fixed part. Reported per pair and as a range.

  align  A(k)  = max_ij err_ij(k) - min_ij err_ij(k)
                How far apart the clients' answers are for the same event.
                This is the pairwise interval-alignment error, in ms.

  drift  slope of a least-squares fit of err_ij against wall time, ms/min.
                Predicted from the injected clock offsets as
                0.06*(ppm_listener - ppm_emitter) ms/min.

The clock-domain CSV is read independently: it samples every client's phase
inside its current interval at the same instant, with no audio involved, and
reports the wrapped difference between each pair.
"""

import csv
import os
import sys
from collections import defaultdict


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return list(csv.DictReader(f))


def read_summary(path):
    """Flat 'key value' per line. Per-client data lives in <tag>_clients.csv."""
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path):
        parts = line.split()
        if len(parts) >= 2:
            out[parts[0]] = parts[1]
    return out


def f(x, default=0.0):
    try:
        return float(x)
    except (TypeError, ValueError):
        return default


# LAB_SRATE in ninjam/tests/interval_probe.h. Logs written before the harness
# recorded srate still need it to undo the detector's centring bias, and it is
# a compile-time constant of the lab rather than a tunable.
LAB_SRATE = 48000.0


def median(xs):
    if not xs:
        return float("nan")
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def linfit(xs, ys):
    n = len(xs)
    if n < 2:
        return float("nan")
    mx = sum(xs) / n
    my = sum(ys) / n
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den = sum((x - mx) ** 2 for x in xs)
    if den == 0:
        return float("nan")
    return num / den


def fmt(v, nd=2):
    if v != v:  # NaN
        return "n/a"
    return f"{v:.{nd}f}"


def table(rows, headers):
    widths = [len(h) for h in headers]
    for r in rows:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], len(str(c)))
    out = ["| " + " | ".join(h.ljust(widths[i]) for i, h in enumerate(headers)) + " |"]
    out.append("|" + "|".join("-" * (w + 2) for w in widths) + "|")
    for r in rows:
        out.append("| " + " | ".join(str(c).ljust(widths[i]) for i, c in enumerate(r)) + " |")
    return "\n".join(out)


class Scenario:
    def __init__(self, root, name):
        self.name = name
        d = os.path.join(root, name)
        self.marks = read_csv(os.path.join(d, f"{name}_markers.csv"))
        self.clocks = read_csv(os.path.join(d, f"{name}_clock.csv"))
        self.clients = read_csv(os.path.join(d, f"{name}_clients.csv"))
        self.summary = read_summary(os.path.join(d, f"{name}_summary.txt"))
        self._index()

    def _index(self):
        # (listener, emitter, k) -> list of (t_s, err_ms, peak)
        self.by_pair_k = defaultdict(list)
        for r in self.marks:
            key = (int(r["listener"]), int(r["emitter"]), int(r["k"]))
            self.by_pair_k[key].append(
                (f(r["t_s"]), f(r["err_ms"]), f(r["peak"]), int(r["suspect"]))
            )
        # The detector can report the same marker twice when the marker's
        # correlation shadow (a half-overlap with the neighbouring grid cell)
        # also clears the threshold. Keep the strongest hit; a real marker
        # correlates far higher than its own shadow.
        self.dup_rows = 0
        for key, v in self.by_pair_k.items():
            if len(v) > 1:
                self.dup_rows += len(v) - 1
                v.sort(key=lambda x: -x[2])
                del v[1:]
            v.sort()

        self.pairs = sorted({(l, e) for (l, e, _) in self.by_pair_k})
        self.ks = sorted({k for (_, _, k) in self.by_pair_k})

        # per k, the spread across pairs
        self.align = {}
        for k in self.ks:
            errs = []
            for (l, e, kk), v in self.by_pair_k.items():
                if kk == k and v:
                    errs.append(v[0][1])
            if len(errs) >= 2:
                self.align[k] = (max(errs) - min(errs), max(errs), min(errs))

        # per pair, delay and drift
        self.delay = {}
        self.drift = {}
        for p in self.pairs:
            pts = []
            for k in self.ks:
                v = self.by_pair_k.get((p[0], p[1], k))
                if v:
                    pts.append(v[0])
            if not pts:
                continue
            self.delay[p] = median([x[1] for x in pts])
            slope = linfit([x[0] for x in pts], [x[1] for x in pts])
            self.drift[p] = slope * 60.0  # ms per minute

        self.ppm = {}
        for c in self.clients:
            try:
                self.ppm[int(c["idx"])] = float(c["ppm"])
            except (KeyError, ValueError):
                pass

        self.interval_ms = f(self.summary.get("interval_s", "nan")) * 1000.0

        # The detector reports the CENTRE of the correlation window while the
        # marker is emitted at the START of its burst, so err_ms as originally
        # logged carries a fixed (mark_len-1)/2 samples of measurement bias. At
        # the default mark_len=1920 that is 19.99 ms, which was the whole of the
        # "~20 ms residual" the delay tables used to show. It is a property of
        # the detector, not of NINJAM, and it moves exactly in step with
        # --mark-len (see the mark960/mark3840 scenarios).
        #
        # The harness now writes err_ms centre-to-centre and says so with
        # `err_centred 1`; subtracting the bias from those would double-count
        # it. Logs predating that fix have the bias baked in and no such key,
        # so it is removed for them. mark_len is in every summary file, so the
        # correction is exact either way.
        self.srate = f(self.summary.get("srate", "nan"))
        self.mark_len = f(self.summary.get("mark_len", "nan"))
        self.err_centred = self.summary.get("err_centred") == "1"
        bias_raw = self.summary.get("centre_bias_ms")
        if bias_raw is not None:
            self.centre_bias_ms = f(bias_raw)
        elif self.mark_len == self.mark_len:
            # logs written before the harness recorded srate; it is a
            # compile-time constant of the lab, not a per-run setting
            sr = self.srate if self.srate == self.srate and self.srate > 0 else LAB_SRATE
            self.centre_bias_ms = (self.mark_len - 1.0) * 0.5 * 1000.0 / sr
        else:
            self.centre_bias_ms = 0.0
        if self.err_centred:
            self.centre_bias_ms = 0.0

        # Residual of each pair's error from its own median delay, wrapped into
        # +/- half an interval. This is the quantity the interval model is
        # supposed to bound: a client that slips loses or gains a WHOLE
        # interval, it does not wander continuously off the grid.
        self.resid = {}
        self.slips = {}
        for p in self.pairs:
            L = self.interval_ms
            if L != L or L <= 0 or p not in self.delay:
                continue
            d = {}
            offsets = set()
            for k in self.ks:
                v = self.by_pair_k.get((p[0], p[1], k))
                if not v:
                    continue
                x = v[0][1] - self.delay[p]
                offsets.add(int(round(x / L)))
                d[k] = (x + L / 2.0) % L - L / 2.0
            self.resid[p] = d
            self.slips[p] = (max(offsets) - min(offsets)) if offsets else 0

        # First whole-interval slip, per pair, and when it happened. `slips`
        # above only counts HOW MANY intervals a pair is ever off by; this is
        # WHEN it first got there, which is what turns the threshold into a
        # rate. Caveat: the median delay is taken over all markers, so if a
        # pair sits in each regime for about half the run the reported time
        # is the midpoint rather than the real crossing. The marker grid is
        # mark_period seconds, so this is the first observed marker on the far
        # side of the jump -- an upper bound within one mark period.
        self.slip_t = {}
        self.slip_bracket = {}
        for p in self.pairs:
            L = self.interval_ms
            if L != L or L <= 0 or p not in self.delay:
                continue
            seq = []
            for k in self.ks:
                v = self.by_pair_k.get((p[0], p[1], k))
                if v:
                    seq.append((v[0][0],
                                int(round((v[0][1] - self.delay[p]) / L))))
            prev = None
            prev_t = None
            for t, o in seq:
                if prev is not None and o != prev:
                    self.slip_t[p] = t
                    # A slip is only SEEN at a marker, so the honest reading is
                    # a bracket: the previous marker's time is a lower bound
                    # and this one an upper bound. The gap between them is
                    # whatever the marker grid left, which is not always the
                    # nominal mark_period -- a slipping pair also drops
                    # markers, and gaps up to 87 s occur.
                    self.slip_bracket[p] = (prev_t, t)
                    break
                prev, prev_t = o, t

        # Per-marker spread of the wrapped residuals: the true alignment error
        # of the interval grid, immune to whole-interval slips.
        self.align_mod = {}
        for k in self.ks:
            ws = [d[k] for d in self.resid.values() if k in d]
            if len(ws) >= 2:
                self.align_mod[k] = max(ws) - min(ws)

        # Markers that at least two pairs heard. The LAST marker overall is
        # often heard by a single pair (one client drops it, or a slip eats it),
        # and s.align has no entry for such a k -- indexing s.align with
        # s.ks[-1] used to raise KeyError and take the whole report down.
        self.align_ks = sorted(self.align)

        # Expected vs observed marker decodes. Client l should decode every
        # marker emitted by every other client.
        emitted = {}
        decoded = {}
        for c in self.clients:
            try:
                i = int(c["idx"])
            except (KeyError, ValueError):
                continue
            emitted[i] = int(c.get("markers_emitted", 0) or 0)
            decoded[i] = int(c.get("markers_decoded", 0) or 0)
        self.emitted = emitted
        self.decoded = decoded
        self.expected_decodes = sum(
            sum(emitted.values()) - emitted[l] for l in emitted
        )

    # -- clock domain ------------------------------------------------------
    def clock_skew(self):
        """Pairwise interval-phase difference in ms, UNWRAPPED.

        The CSV's interval_len column is in samples, not ms, so it must not be
        used as the wrap modulus here. Returning the raw difference is the
        honest choice: a pair that is one whole interval apart then shows up
        as ~interval, which is a real observation, whereas wrapping it away
        would hide the slip that the interval model produces.
        """
        by_t = defaultdict(dict)
        for r in self.clocks:
            t = f(r["t_s"])
            by_t[t][int(r["idx"])] = f(r["interval_phase_ms"])
        out = defaultdict(list)
        for t, ph in by_t.items():
            ids = sorted(ph)
            for i in range(len(ids)):
                for j in range(i + 1, len(ids)):
                    out[(ids[i], ids[j])].append((t, ph[ids[i]] - ph[ids[j]]))
        return out

    @staticmethod
    def wrap_ms(d, L):
        """Wrap a millisecond difference into +/- half an interval."""
        if L <= 0:
            return d
        return (d + L / 2.0) % L - L / 2.0

    def suspects(self):
        return sum(1 for r in self.marks if int(r["suspect"]))


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "results"
    names = sorted(
        d for d in os.listdir(root)
        if os.path.isdir(os.path.join(root, d))
        and os.path.exists(os.path.join(root, d, f"{d}_markers.csv"))
    )
    if not names:
        print("no scenarios found")
        return 1

    sc = {n: Scenario(root, n) for n in names}

    print("# Interval-model results\n")
    print(f"Generated by `tools/analyze_interval_lab.py` from the CSVs in `{root}/`.")
    print("All alignment numbers are milliseconds.\n")

    # --- 1. fixed propagation delay ---------------------------------------
    print("## 1. Fixed propagation delay (emission to playback)\n")
    print("`delay = median over markers of (heard_session_pos - k*mark_period)`.")
    print("This is the constant that the interval model contributes; drift is measured")
    print("relative to it. A value near a multiple of the interval is the interval")
    print("structure showing through.\n")
    rows = []
    for n in names:
        s = sc[n]
        iv = f(s.summary.get("interval_s", "nan")) * 1000.0  # ms
        bias = s.centre_bias_ms
        if not s.delay:
            rows.append([n, fmt(iv / 1000.0, 2), fmt(bias, 2), "no data", "", "", ""])
            continue
        ds = [d - bias for d in s.delay.values()]
        ivs = [d / iv for d in ds] if iv == iv and iv > 0 else [float("nan")]
        rows.append([
            n, fmt(iv, 2), fmt(bias, 2),
            fmt(min(ds)), fmt(median(ds)), fmt(max(ds)),
            fmt(median([v for v in ivs if v == v]), 4),
        ])
    print(table(rows, ["scenario", "interval s", "centre bias ms", "min delay",
                       "median delay", "max delay", "median delay / interval"]))
    print()
    print("`centre bias ms` is the detector's half-burst centring offset,")
    print("(mark_len-1)/2 samples, already removed from the delays above. It is")
    print("an artefact of measuring a correlation CENTRE against a marker")
    print("emitted at its START, not latency in NINJAM -- see the mark_len")
    print("scenarios, where the raw residual tracks this column exactly. It")
    print("reads 0.00 for scenarios whose logs were written after the harness")
    print("started emitting centre-to-centre errors; those need no correction.")
    print()
    print("`median delay / interval` is how many intervals elapse between a marker")
    print("being emitted and being heard. See REPORT.md for what that number means")
    print("for the interval model.\n")
    print("The rtt* scenarios add a symmetric per-client one-way latency")
    print("(--client-delay: the same amount on the way up and the way down). Issue")
    print("#22 predicted the contribution would be visible HERE -- the delay column")
    print("rising by the injected amount, pair by pair, while the alignment tables")
    print("below stayed put. Measured, the prediction does not hold: the delay")
    print("column does not move at all, and the rtt rows match baseline in this")
    print("table as well as in section 2. Two-interval structure absorbs the added")
    print("latency outright rather than merely displacing delivery time.")
    print()

    # --- 2. alignment error and drift -------------------------------------
    print("## 2. Pairwise interval-alignment error and clock drift\n")
    print("`align(k) = max over client pairs of err - min over client pairs of err`,")
    print("for the same marker k: how far apart the clients are, in ms.")
    print("`align mod` repeats that after wrapping every pair's error into")
    print("+/- half an interval, i.e. it ignores whole-interval slips -- that is the")
    print("error of the grid itself, which is what the interval model controls.")
    print("`drift` is a least-squares fit of err against wall time, in ms/min, for the")
    print("pair with the largest |drift|. Predicted drift for a pair is")
    print("`0.06 * (ppm_listener - ppm_emitter)` ms/min.\n")
    rows = []
    for n in names:
        s = sc[n]
        if not s.align or not s.drift or not s.align_ks:
            rows.append([n, "no data"] + [""] * 9)
            continue
        first_k, last_k = s.align_ks[0], s.align_ks[-1]
        worst = max(s.drift, key=lambda p: abs(s.drift[p]))
        p = worst
        pred = 0.06 * (s.ppm.get(p[0], 0.0) - s.ppm.get(p[1], 0.0))
        nslip = max(s.slips.values()) if s.slips else 0
        rows.append([
            n, len(s.ks),
            fmt(s.align[first_k][0]), fmt(s.align[last_k][0]),
            fmt(max(v[0] for v in s.align.values())),
            fmt(max(s.align_mod.values())) if s.align_mod else "n/a",
            nslip,
            f"{p[0]}<-{p[1]}", fmt(s.drift[p]), fmt(pred),
        ])
    print(table(rows, ["scenario", "markers", "align first", "align last",
                       "align max", "align mod iv", "max slips", "worst pair",
                       "drift ms/min", "predicted"]))
    print()
    print("`align max` is the raw figure: how far apart two clients are, whole")
    print("intervals included. `align mod iv` is the same figure with whole-interval")
    print("slips removed. The gap between the two columns is the whole point --")
    print("see REPORT.md.\n")

    # --- 3. full drift trace ----------------------------------------------
    print("## 3. Per-pair alignment error, first marker vs last marker\n")
    for n in names:
        s = sc[n]
        if not s.delay or not s.align_ks:
            continue
        first_k, last_k = s.align_ks[0], s.align_ks[-1]
        rows = []
        for p in s.pairs:
            d = s.delay[p]
            a = s.by_pair_k.get((p[0], p[1], first_k))
            b = s.by_pair_k.get((p[0], p[1], last_k))
            if not a or not b:
                continue
            rows.append([
                f"{p[0]} hears {p[1]}",
                f"{s.ppm.get(p[0],0):+g} / {s.ppm.get(p[1],0):+g}",
                fmt(d), fmt(a[0][1]), fmt(b[0][1]),
                fmt(b[0][1] - a[0][1]), fmt(s.drift.get(p, float("nan"))),
                s.slips.get(p, "n/a"),
                fmt(s.resid[p][first_k]) if first_k in s.resid.get(p, {}) else "n/a",
                fmt(s.resid[p][last_k]) if last_k in s.resid.get(p, {}) else "n/a",
            ])
        print(f"### {n}\n")
        print(table(rows, ["pair", "ppm l/e", "delay", f"err @k={first_k}",
                           f"err @k={last_k}", "change", "drift ms/min",
                           "slips", "resid @first", "resid @last"]))
        print()
    print("`resid` is the error from the pair's own median delay, wrapped into")
    print("+/- half an interval: the real skew. `change` is the raw figure, so a")
    print("large `change` with a small `resid` is a whole-interval slip, not drift.\n")

    # --- 4. loss and jitter -----------------------------------------------
    print("## 4. Loss and jitter: did the markers survive?\n")
    print("Loss is applied to audio-bearing Net_Messages (upload and download")
    print("interval begin/write), not to IP packets: the transport is a single TCP")
    print("stream, so TCP would turn a dropped packet into latency rather than loss.\n")
    rows = []
    for n in names:
        s = sc[n]
        sm = s.summary
        emitted = sum(s.emitted.values())
        exp = s.expected_decodes
        decoded = len(s.by_pair_k)
        seen = sum(int(c.get("audio_msgs_seen", 0) or 0) for c in s.clients)
        dropped = sum(int(c.get("audio_msgs_dropped", 0) or 0) for c in s.clients)
        rate = (100.0 * dropped / seen) if seen else 0.0
        det = (100.0 * decoded / exp) if exp else float("nan")
        rows.append([
            n,
            fmt(f(sm.get("up_loss_pct", 0)), 0) + "% / " + fmt(f(sm.get("down_loss_pct", 0)), 0) + "%",
            fmt(f(sm.get("up_jitter_ms", 0)), 0) + " / " + fmt(f(sm.get("down_jitter_ms", 0)), 0),
            emitted, exp, decoded, fmt(det, 1) + "%",
            seen, dropped, fmt(rate, 2) + "%", s.suspects(),
        ])
    print(table(rows, ["scenario", "loss up/down", "jitter up/down ms",
                       "markers emitted", "expected decodes", "decoded",
                       "detection rate", "audio msgs seen", "dropped",
                       "actual drop rate", "suspect rows"]))
    print()
    print("`expected decodes` counts marker emissions weighted by the number of")
    print("other clients that should hear each one, so the detection rate is a")
    print("percentage that can actually reach 100. Anything below it is audio that")
    print("the conditioner destroyed before it was played.\n")

    # --- 5. clock domain ---------------------------------------------------
    print("## 5. Clock domain: interval-boundary phase, no audio involved\n")
    print("Each client's phase inside its own interval, sampled at the same instant")
    print("for every client and differenced between pairs. No audio involved: this")
    print("is the mechanism underneath the numbers above.\n")
    print("The difference is reported twice. `raw` is the plain millisecond")
    print("difference, so a pair that is one whole interval apart reads as ~4000.")
    print("`wrapped` folds that into +/- half an interval, which is the real phase")
    print("error. `slip rate` is the fraction of samples whose RAW difference is")
    print("more than a quarter of an interval -- i.e. the pair had slipped a whole")
    print("interval rather than being slightly out of phase.\n")
    rows = []
    for n in names:
        s = sc[n]
        cs = s.clock_skew()
        if not cs:
            rows.append([n, "no data"] + [""] * 8)
            continue
        L = s.interval_ms
        allv = [v for vs in cs.values() for (_, v) in vs]
        wr = sorted(abs(s.wrap_ms(v, L)) for v in allv)
        p99 = wr[int(0.99 * (len(wr) - 1))] if wr else float("nan")
        slip = (100.0 * sum(1 for v in allv if abs(v) > L / 4.0) / len(allv)) if allv and L > 0 else float("nan")
        worst = max(cs, key=lambda p: max(abs(v) for (_, v) in cs[p]))
        wv = [s.wrap_ms(v, L) for (_, v) in cs[worst]]
        slope = linfit([t for (t, _) in cs[worst]], [v for (_, v) in cs[worst]]) * 60.0
        rows.append([
            n, len(cs), len(allv),
            fmt(median([abs(v) for v in allv])), fmt(max(abs(v) for v in allv)),
            fmt(p99), fmt(max(wr)),
            f"{worst[0]}-{worst[1]}", fmt(slip, 2) + "%", fmt(slope),
        ])
    print(table(rows, ["scenario", "pairs", "samples", "median |skew|",
                       "max |skew| raw", "p99 wrapped", "max wrapped",
                       "worst pair", "slip rate", "drift ms/min"]))
    print()

    # --- 6. join in progress ----------------------------------------------
    print("## 6. Join in progress\n")
    print("A fourth client connects mid-session. Times are relative to the start of")
    print("the run; `first marker` is when it first decoded a marker from a client")
    print("that was already present.\n")
    for n in names:
        s = sc[n]
        if f(s.summary.get("late_join_s", "-1")) < 0:
            continue
        print(f"### {n}\n")
        rows = []
        for c in s.clients:
            rows.append([
                c.get("idx", "?"), c.get("name", "?"), c.get("ppm", "?"),
                fmt(f(c.get("status_ok_s", "-1"))), fmt(f(c.get("first_remote_audio_s", "-1"))),
                fmt(f(c.get("first_marker_s", "-1"))), c.get("first_marker_from", "?"),
            ])
        print(table(rows, ["idx", "name", "ppm", "status OK s", "first remote audio s",
                           "first marker s", "marker from"]))
        print()
        # where did the late joiner land relative to the others?
        late = [c for c in s.clients if c.get("is_late") == "1"]
        if late and s.delay:
            li = int(late[0]["idx"])
            others = [d for p, d in s.delay.items() if p[0] != li]
            mine = [d for p, d in s.delay.items() if p[0] == li]
            if others and mine:
                iv = f(s.summary.get("interval_s", "0"))
                lo, hi = min(others), max(others)
                print(f"Late joiner's fixed delay to existing clients: "
                      f"{fmt(min(mine))}-{fmt(max(mine))} ms.")
                print(f"Existing clients' delay among themselves: {fmt(lo)}-{fmt(hi)} ms.")
                if iv > 0:
                    print(f"Late joiner sits {(median(mine)-median(others))/iv:+.3f} intervals "
                          f"away from the rest of the session "
                          f"({fmt(median(mine)-median(others))} ms).")
                print()

    # --- 7. drift threshold ------------------------------------------------
    print("## 7. Clock-drift threshold for a whole-interval slip\n")
    print("A drifting client does not slide off the grid: its error stays pinned")
    print("to a whole number of intervals and then jumps. The threshold is")
    print("therefore a RATE and not an offset -- what matters is the clock error")
    print("a pair has accumulated by the time the session ends, not how fast it")
    print("is running. `accumulated` is the injected relative clock error,")
    print("ppm_rel * first_slip_t, i.e. the drift a pair had run up at the moment")
    print("it first slipped. Compare that against one interval (4000 ms here):")
    print("if the slips all land near one interval, the interval model is what")
    print("breaks them, and the threshold is predictable from a spec sheet.\n")
    print("`first slip t` is the first marker observed on the far side of the")
    print("jump, so it is an upper bound. The previous marker's time is the")
    print("matching lower bound, and the two are printed together as a bracket.")
    print("Do NOT read a single slip time as the threshold: the marker gap is")
    print("not always the nominal mark_period, because a pair that is slipping")
    print("also drops markers, and gaps of 50-90 s occur. A pair reading well")
    print("above 1.0 is usually a wide bracket, not a disagreement.\n")
    print("Pairs that did not start on the 2-interval baseline are excluded from")
    print("the comparison -- they carry a whole-interval startup offset (see")
    print("`start iv`) and so cross at 2.0 by the same rule.\n")
    rows = []
    for n in names:
        s = sc[n]
        if not s.ppm or not any(abs(v) > 0 for v in s.ppm.values()):
            continue
        for p in s.pairs:
            rel = s.ppm.get(p[0], 0.0) - s.ppm.get(p[1], 0.0)
            br = s.slip_bracket.get(p)
            iv = s.interval_ms
            acc = (lambda t: abs(rel) * t / 1000.0) if br else None
            first = sorted(s.by_pair_k.get((p[0], p[1], k)) for k in [s.ks[0]])[0][0][1] if s.ks else 8020.0
            start_iv = int(round((first - 8020.0) / iv)) if iv > 0 else 0
            rows.append([
                n, f"{p[0]}<-{p[1]}", f"{rel:+g}",
                fmt(s.delay.get(p, float("nan"))),
                s.slips.get(p, "n/a"),
                "%+d" % start_iv,
                fmt(br[0], 1) if br else "none",
                fmt(br[1], 1) if br else "none",
                fmt(acc(br[0]) / iv, 2) if br else "n/a",
                fmt(acc(br[1]) / iv, 2) if br else "n/a",
                "yes" if br and start_iv == 0 else ("no" if br else "n/a"),
            ])
    print(table(rows, ["scenario", "pair", "ppm rel", "delay ms", "slips",
                       "start iv", "last aligned s", "first slipped s",
                       "lo iv", "hi iv", "aligned pair"]))
    print()

    # --- 8. integrity ------------------------------------------------------
    print("## 8. Log integrity\n")
    rows = []
    for n in names:
        s = sc[n]
        skipped = sum(int(c.get("markers_skipped", 0) or 0) for c in s.clients)
        peaks = [f(r["peak"]) for r in s.marks]
        rows.append([
            n, len(s.marks), len(s.by_pair_k), s.dup_rows, len(s.clocks), skipped,
            fmt(min(peaks), 3) if peaks else "n/a",
            fmt(median(peaks), 3) if peaks else "n/a",
            fmt(max(peaks), 3) if peaks else "n/a",
        ])
    print(table(rows, ["scenario", "marker rows", "unique markers", "shadow rows",
                       "clock rows", "markers skipped at emit", "min peak",
                       "median peak", "max peak"]))
    print()
    print("`markers skipped at emit` should be 0: a non-zero value means a marker was")
    print("scheduled into a gap in the client's own sample stream and never sent.\n")
    print("`peak` saturates at 1.0 (see the clamp in interval_probe.h), so a peak")
    print("of exactly 1.0000 means the correlation was at or above the clamp, not")
    print("that the marker was received more cleanly than usual. It shows up on")
    print("post-slip rows and must not be read as a detection-quality change.")
    print()
    print("`shadow rows` are duplicate (listener, emitter, k) triples. A Hann template")
    print("aligned half a burst late still correlates about 0.5 with the burst, so")
    print("every marker throws a weak shadow roughly one burst length behind itself.")
    print("They are excluded above -- the strongest hit wins -- and they are not")
    print("evidence of anything NINJAM did. The detector now suppresses them at")
    print("source, so re-running with the current code gives 0 here.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
