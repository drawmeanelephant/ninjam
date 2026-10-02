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
        self.truncs = read_csv(os.path.join(d, f"{name}_trunc.csv"))
        # Session-clock origin per client (issue #25). Optional: logs written
        # before the harness recorded it simply do not have it, and every
        # section that uses it has to cope with its absence.
        sp = os.path.join(d, f"{name}_start.csv")
        self.starts = read_csv(sp) if os.path.exists(sp) else []
        # Interval-rollover events per client (issue #32). Optional in the
        # same way: runs recorded before the harness wrote the file lack it.
        ivp = os.path.join(d, f"{name}_ivevents.csv")
        self.ivevents = read_csv(ivp) if os.path.exists(ivp) else []
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
        self.mark_period_ms = f(self.summary.get("mark_period_s", "nan")) * 1000.0
        # How long the run was configured to last. The slip threshold is a
        # PRODUCT of clock error and time (see section 7), so the accumulated
        # error at the end of a run needs the configured duration, not the
        # span of the markers that happened to decode.
        self.duration_s = f(self.summary.get("duration_s", "nan"))

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
        # interval, it does not wander continuously off the grid. The wrapped
        # residual is continuous, so the reference it is measured from does not
        # have to be exact; it stays the pair's median, which is what the
        # `align mod iv` headline is defined against.
        #
        # The whole-INTERVAL INDEX, below, does have to be exact, and that is
        # what the pair's first heard marker is for. A drifting pair crosses
        # the boundary about half way through its run, so for half the run its
        # median IS the midpoint between the two regimes: every pre-slip marker
        # then sits on an exact +/- 0.5 rounding tie, and int(round(x/L))
        # flips between 0 and -1 over differences of hundredths of a
        # millisecond. That is a coin toss rather than a slip, and it was being
        # reported as a first crossing at 0.23 intervals in drift3000iv2s.
        # Indexing from the first marker makes the pre-slip offset 0 by
        # construction, so the transition found is the real one. The absolute
        # lo/hi figures come from the crossing time and the injected ppm, so
        # they do not depend on this choice at all.
        self.base_err = {}
        for p in self.pairs:
            for k in self.ks:
                v = self.by_pair_k.get((p[0], p[1], k))
                if v:
                    self.base_err[p] = v[0][1]
                    break
        self.resid = {}
        self.slips = {}
        for p in self.pairs:
            L = self.interval_ms
            if L != L or L <= 0 or p not in self.delay or p not in self.base_err:
                continue
            d = {}
            offsets = set()
            for k in self.ks:
                v = self.by_pair_k.get((p[0], p[1], k))
                if not v:
                    continue
                x = v[0][1] - self.delay[p]
                d[k] = (x + L / 2.0) % L - L / 2.0
                offsets.add(int(round((v[0][1] - self.base_err[p]) / L)))
            self.resid[p] = d
            self.slips[p] = (max(offsets) - min(offsets)) if offsets else 0

        # First whole-interval slip, per pair, and when it happened. `slips`
        # above only counts HOW MANY intervals a pair is ever off by; this is
        # WHEN it first got there, which is what turns the threshold into a
        # bracket. A pair carrying a startup offset is still detected
        # correctly, because it is the CHANGE in whole intervals that counts
        # and not their absolute value. The marker grid is mark_period
        # seconds, so this is the first observed marker on the far side of the
        # jump -- an upper bound within one mark period.
        self.slip_t = {}
        self.slip_bracket = {}
        for p in self.pairs:
            L = self.interval_ms
            if L != L or L <= 0 or p not in self.base_err:
                continue
            seq = []
            for k in self.ks:
                v = self.by_pair_k.get((p[0], p[1], k))
                if v:
                    seq.append((v[0][0],
                                int(round((v[0][1] - self.base_err[p]) / L))))
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

    # -- truncation (issue #23) --------------------------------------------
    #
    # A truncation is recorded in <tag>_trunc.csv as the moment a client
    # received a damaged audio message, tagged with where its own playback
    # head was. What that message carries is heard one interval later: audio
    # for interval N is received as N closes and played during N+1, so the
    # damage lands at the playback position the client was at plus one
    # interval. (The TWO-interval figure elsewhere in this report is
    # emission to playback, and reception is the midpoint of the two.)
    def trunc_events(self):
        """(listener, affected_playback_pos_ms, cut, msg) per event."""
        out = []
        for r in self.truncs:
            out.append((
                int(r["listener"]),
                f(r["spos_ms"]) + self.interval_ms,
                f(r["cut_bytes"]),
                f(r["msg_bytes"]),
            ))
        return sorted(out, key=lambda x: (x[0], x[1]))

    def gaps(self):
        """Silent runs on each remote channel, as (listener, col) -> runs.

        With --steady the emitters carry a quiet constant tone, so a channel's
        decoded level says whether its audio is flowing right now. The live
        level is not known in advance -- it comes back through the codec and
        the mixer well below what was transmitted -- so the threshold is
        calibrated per channel from that channel's own median, and a run
        counts as silent below 40% of it.

        Returns {listener: [(col, start_ms, end_ms, peak_inside, live)]}.
        The interval before a channel has ever been heard is dropped: nothing
        has arrived yet, which is the two-interval pipeline filling up and not
        a loss.
        """
        L = self.interval_ms
        by_l = defaultdict(list)
        for r in self.clocks:
            by_l[int(r["idx"])].append(r)
        out = {}
        for li, rows in by_l.items():
            rows.sort(key=lambda r: f(r["spos_ms"]))
            ncol = 0
            for k in rows[0]:
                if k.startswith("upk"):
                    ncol = max(ncol, int(k[3:]) + 1)
            runs = []
            for col in range(ncol):
                key = f"upk{col}"
                vals = [f(r.get(key)) for r in rows]
                if not vals:
                    continue
                med = median(vals)
                if med <= 0:
                    continue  # channel never carried anything
                th = med * 0.4
                first_live = next((i for i, v in enumerate(vals) if v >= th), None)
                if first_live is None:
                    continue
                cur = None
                for i, r in enumerate(rows):
                    p = f(r["spos_ms"])
                    if i < first_live:
                        continue
                    if f(r.get(key)) < th:
                        cur = [p, p, 0.0] if cur is None else [cur[0], p, cur[2]]
                        if f(r.get(key)) > cur[2]:
                            cur[2] = f(r.get(key))
                    elif cur:
                        runs.append((col, cur[0], cur[1], cur[2], med))
                        cur = None
                if cur:
                    runs.append((col, cur[0], cur[1], cur[2], med))
            out[li] = runs
        return out


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
            # ms, like the data rows below. This branch used to divide by
            # 1000 and print seconds while the data branch printed
            # milliseconds, so the same column meant two different things
            # depending on the row.
            rows.append([n, fmt(iv, 2), fmt(bias, 2), "no data", "", "", ""])
            continue
        ds = [d - bias for d in s.delay.values()]
        ivs = [d / iv for d in ds] if iv == iv and iv > 0 else [float("nan")]
        rows.append([
            n, fmt(iv, 2), fmt(bias, 2),
            fmt(min(ds)), fmt(median(ds)), fmt(max(ds)),
            fmt(median([v for v in ivs if v == v]), 4),
        ])
    print(table(rows, ["scenario", "interval ms", "centre bias ms", "min delay",
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
            # 10 columns, so 8 blanks after the scenario name. This row used
            # to carry 9, which only showed up as an IndexError once a
            # scenario decoded no markers at all (the desync runs, where the
            # session dies before any marker is measurable).
            rows.append([n, "no data"] + [""] * 8)
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
    print("therefore a PRODUCT of clock error and time, not a rate: what matters")
    print("is the clock error a pair has accumulated by the time it slips, not")
    print("how fast it is running. `lo iv` and `hi iv` are that accumulated error")
    print("at the last marker before and the first marker after the jump, divided")
    print("by the interval. If the slips all land near one interval, the interval")
    print("model is what breaks them, and the threshold is predictable from a")
    print("spec sheet. Section 7b varies the interval to find out whether the")
    print("result is really in intervals or really in ppm.\n")
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
            # The protocol's structural delay is exactly two intervals, so a
            # pair that starts one interval out is one interval off the
            # baseline. This baseline used to be the literal 8020 ms, which is
            # 2 x 4000 plus the 20 ms detector bias: right for a 4 s run and a
            # whole interval adrift at every other tempo, which made `start iv`
            # unusable for the 2 s and 8 s runs the interval comparison needs.
            base = 2.0 * iv
            if iv <= 0 or not s.ks:
                first = base
            else:
                v0 = s.by_pair_k.get((p[0], p[1], s.ks[0]))
                first = v0[0][1] if v0 else base
            start_iv = int(round((first - base) / iv)) if iv > 0 else 0
            end_iv = (abs(rel) * s.duration_s / 1000.0 / iv
                      if iv > 0 and s.duration_s == s.duration_s else float("nan"))
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
                fmt(end_iv, 2),
                fmt(iv, 0),
            ])
    print(table(rows, ["scenario", "pair", "ppm rel", "delay ms", "slips",
                       "start iv", "last aligned s", "first slipped s",
                       "lo iv", "hi iv", "aligned pair", "end iv",
                       "interval ms"]))
    print()
    print("`end iv` is the relative clock error a pair has accumulated by the")
    print("end of its run, in intervals: |ppm rel| * duration / interval. A row")
    print("whose `lo iv` is n/a never slipped, so its `end iv` is the evidence")
    print("that the threshold is above that value. `interval ms` is repeated per")
    print("row because these runs span three tempos and the threshold has to be")
    print("compared both in intervals and in ppm.\n")

    # --- 7b. does the threshold scale with the interval? -------------------
    #
    # Issue #20 asks whether the threshold is one whole interval of
    # accumulated error -- in which case the ppm at which it happens scales
    # with the interval, L/T -- or an absolute drift rate, in which case it
    # does not move when the tempo does. Both hypotheses predict the same
    # thing at a 4 s interval, so only a change of tempo can separate them.
    #
    # In ppm the bracket needs no conversion: the largest relative offset that
    # finished a run without slipping is a lower bound on the threshold, and
    # the smallest slipped pair's offset, scaled by its lower-bound interval
    # fraction, is an upper bound. Pairs carrying a startup offset are
    # excluded, for the same reason as in the table above.
    per_iv = {}
    for n in names:
        s = sc[n]
        if not s.ppm or not any(abs(v) > 0 for v in s.ppm.values()):
            continue
        d = per_iv.setdefault(s.interval_ms,
                              {"names": set(), "dur": s.duration_s,
                               "no_slip": [], "slip": []})
        d["names"].add(n)
        for p in s.pairs:
            iv = s.interval_ms
            if iv <= 0 or not s.ks:
                continue
            rel = abs(s.ppm.get(p[0], 0.0) - s.ppm.get(p[1], 0.0))
            v = s.by_pair_k.get((p[0], p[1], s.ks[0]))
            first = v[0][1] if v else 2.0 * iv
            if int(round((first - 2.0 * iv) / iv)) != 0:
                continue
            br = s.slip_bracket.get(p)
            if br:
                d["slip"].append((rel, rel * br[0] / 1000.0 / iv,
                                  rel * br[1] / 1000.0 / iv))
            else:
                d["no_slip"].append((rel, rel * s.duration_s / 1000.0 / iv))

    print("## 7b. Does the threshold scale with the interval, or is it a fixed")
    print("drift rate?\n")
    print("The same ladder at three tempos, all 660 s. If the threshold is one")
    print("whole interval of accumulated error then the ppm it happens at must")
    print("scale with the interval, `L / T`, halving at 2 s and doubling at 8 s.")
    print("If it were an absolute drift rate the ppm would not move at all --")
    print("which is what makes this the only way to tell the two apart.\n")
    rows = []
    for iv in sorted(per_iv):
        d = per_iv[iv]
        ns, sl = d["no_slip"], d["slip"]
        lo_ppm = max([r for r, _ in ns], default=float("nan"))
        hi_ppm = min([r * lo for r, lo, _ in sl], default=float("nan"))
        pred = (iv / d["dur"] * 1000.0) if d["dur"] == d["dur"] else float("nan")
        rows.append([
            fmt(iv, 0), len(d["names"]), len(ns), len(sl),
            fmt(max([e for _, e in ns], default=float("nan")), 2),
            fmt(min([lo for _, lo, _ in sl], default=float("nan")), 2),
            fmt(max([hi for _, _, hi in sl], default=float("nan")), 2),
            fmt(lo_ppm, 0),
            "[%s, %s]" % (fmt(lo_ppm, 0), fmt(hi_ppm, 0))
            if lo_ppm == lo_ppm and hi_ppm == hi_ppm else "n/a",
            fmt(pred, 0),
        ])
    print(table(rows, ["interval ms", "runs", "no-slip pairs", "slipped pairs",
                       "no-slip max iv", "slip lo iv", "slip hi iv",
                       "no-slip max ppm", "threshold ppm", "predicted L/T ppm"]))
    print()
    print("`no-slip max ppm` is the largest relative offset that finished a run")
    print("still aligned, so the threshold lies above it; `threshold ppm` adds the")
    print("smallest slipped pair's lower bound. `predicted L/T ppm` is what a")
    print("one-whole-interval threshold predicts at this tempo. Agreement between")
    print("the last two columns means the threshold scales with the interval;")
    print("a `threshold ppm` that stays put across tempos would mean a fixed rate.")
    print()

    # --- 7c. the join-time whole-interval offset (issue #25) ----------------
    #
    # Some pairs measure one whole interval less than the two-interval
    # pipeline, from their very first marker, before any drift has had time to
    # accumulate. The competing explanations were a startup transient, the
    # interval grid being unable to express a fractional position, and an
    # artefact of the harness pacing samples at (1+ppm). They are separated
    # here by one quantity.
    #
    # Each client's interval grid is anchored at its own session position 0,
    # which is the instant its audio began. A grid boundary at session
    # position S therefore falls at wall time origin_i + S/rate_i, with
    # rate_i = 1 + ppm_i. Comparing the EMITTER's boundary with the
    # LISTENER's at the same session position gives
    #
    #     lead = (origin_E - origin_L) + S*(1/rate_E - 1/rate_L)
    #
    # A negative lead means the emitter's interval closes before the
    # listener's next boundary, so the download is already queued when the
    # listener's boundary arrives and is played one interval after emission.
    # A positive lead means it misses, and waits a second interval. That is
    # the whole of the effect: the sign of `lead`, nothing else. S is the
    # first marker's interval CLOSE, mark_period + interval, because that is
    # the boundary which has to catch that download.
    start_names = [n for n in names if sc[n].starts]
    if start_names:
        print("## 7c. The join-time whole-interval offset (issue #25)\n")
        print("A pair reads one whole interval low when the emitter's interval closes")
        print("before the listener's next boundary. `lead` is that margin in")
        print("milliseconds, evaluated at the first marker's interval close; `start")
        print("iv` is the measured offset in whole intervals and `pred` is what the")
        print("sign of `lead` predicts. A disagreement is a row to explain, not noise.\n")
        rows = []
        for n in start_names:
            s = sc[n]
            iv = s.interval_ms
            if iv <= 0 or not s.ks:
                continue
            org = {}
            rate = {}
            ramp_s = f(s.summary.get("ppm_ramp_s", "0"), 0.0)
            for c in s.starts:
                try:
                    i = int(c["idx"])
                except (KeyError, ValueError):
                    continue
                org[i] = f(c["t_audio_start_s"], float("nan")) * 1000.0
                # The offset in force at the FIRST marker, not the nominal one.
                # --ppm-ramp exists precisely to make those differ, and reading
                # the nominal value here would have the analyzer predicting a
                # flip for a run that deliberately never reaches that offset.
                ppm_i = f(c["ppm"])
                if ramp_s > 0.0:
                    frac = min(max((s.mark_period_ms / 1000.0) / ramp_s, 0.0), 1.0)
                    ppm_i *= frac
                rate[i] = 1.0 + ppm_i * 1e-6
            if not org:
                continue
            # origins are written as absolute wall seconds; difference them so
            # the number means "how much later than a peer this clock starts"
            base = min(v for v in org.values() if v == v)
            S = s.mark_period_ms + iv
            for p in s.pairs:
                l, e = p
                if l not in org or e not in org:
                    continue
                lead = ((org[e] - base) - (org[l] - base)
                        + S * (1.0 / rate[e] - 1.0 / rate[l]))
                v0 = s.by_pair_k.get((l, e, s.ks[0]))
                if not v0:
                    continue
                first = v0[0][1]
                start_iv = int(round((first - 2.0 * iv) / iv)) if iv > 0 else 0
                rows.append([
                    n, "%d<-%d" % (l, e),
                    "%+.0f" % lead,
                    "%+d" % start_iv,
                    "yes" if start_iv < 0 else "no",
                ])
        print(table(rows, ["scenario", "pair", "lead ms", "start iv",
                           "reads low"]))
        print()
        print("`reads low` is measured from the audio; `lead` is computed from the")
        print("injected clock error and the recorded session origins alone, so the")
        print("two are independent. The bracket is read straight off the table: the")
        print("most negative lead that still read two intervals, against the least")
        print("negative one that read a single interval. Everything with a lead of")
        print("0 or more reads two intervals, and every negative lead beyond the")
        print("bracket reads one, so the offset is the interval grid rounding a")
        print("sub-interval phase -- not a transient, and not the pacing in the")
        print("harness. Rows sitting inside the bracket are genuinely marginal and")
        print("are the reason the bracket is quoted as a range; section 7d")
        print("measures both sides of their margin directly.\n")

        print("Per-client startup record for those runs:\n")
        rows = []
        for n in start_names:
            s = sc[n]
            base = min((f(c["t_audio_start_s"], float("nan")) for c in s.starts),
                       default=float("nan"))
            for c in s.starts:
                rows.append([
                    n, c.get("name", "?"), "%+g" % f(c["ppm"]),
                    "%+.3f" % (f(c["t_audio_start_s"], float("nan")) - base),
                    fmt(f(c["first_iv_spos_ms"], float("nan")), 1),
                    fmt(f(c["first_iv_spos_ms"], 0.0) / s.interval_ms, 3)
                    if s.interval_ms else "n/a",
                ])
        print(table(rows, ["scenario", "client", "ppm", "audio start rel s",
                           "first iv spos ms", "first iv / interval"]))
        print()
        print("`audio start rel s` is how much later than the first client this one")
        print("began consuming audio, i.e. where its session position 0 sits. When")
        print("it is the same for every client -- which it is in every drift run --")
        print("no client started its clock early or late. `first iv / interval` is")
        print("the session position of the first interval boundary as a fraction of")
        print("an interval, and it is near zero everywhere: m_interval_pos starts at")
        print("-1, so the first AudioProc chunk opens interval 1 immediately and")
        print("there is nothing before it to have been consumed. A client cannot")
        print("cross an extra boundary while starting up, because its boundaries")
        print("are a pure function of the samples it has been handed.\n")

    # --- 7d. the margin at the boundary, measured not derived (issue #32) ---
    #
    # §7c predicts the flip from a formula. The formula ASSUMES the emitter's
    # interval actually closes at origin_E + S/rate_E and the listener's next
    # boundary actually falls at origin_L + S/rate_L. Issue #32 asks whether
    # that holds in both directions: at the same nominal lead, a pair with a
    # slow listener and a pair with a fast emitter disagree about flipping,
    # and one pair is non-monotonic in lead. The harness now records every
    # client's interval rollover with a sample-interpolated wall time, so both
    # sides of the margin can be measured rather than derived:
    #
    #     empirical lead = wall(emitter rollover at session position S)
    #                    - wall(listener rollover at session position S)
    #
    # with S the first marker's interval close, exactly as in §7c. The
    # pipeline's own close-to-decode latency is NOT part of this gap: it is
    # the second term of the flip condition (empirical lead < -latency), so a
    # directional difference that survives here lives in the latency, and one
    # that shows up as empirical != formula lives in the grid model itself.
    iv_names = [n for n in names if sc[n].ivevents and sc[n].starts]
    if iv_names:
        print("## 7d. The margin at the boundary, measured not derived (issue #32)\n")
        ev_by_dir = {}
        rows = []
        for n in iv_names:
            s = sc[n]
            iv = s.interval_ms
            if iv <= 0:
                continue
            ramp_s = f(s.summary.get("ppm_ramp_s", "0"), 0.0)
            org, rate, ppmc = {}, {}, {}
            for c in s.starts:
                try:
                    i = int(c["idx"])
                except (KeyError, ValueError):
                    continue
                org[i] = f(c["t_audio_start_s"], float("nan"))
                ppm_i = f(c["ppm"])
                if ramp_s > 0.0:
                    frac = min(max((s.mark_period_ms / 1000.0) / ramp_s, 0.0), 1.0)
                    ppm_i *= frac
                ppmc[i] = ppm_i
                rate[i] = 1.0 + ppm_i * 1e-6
            if not org:
                continue
            # rollover events per client, session position -> wall time
            ev = {}
            for r in s.ivevents:
                try:
                    ev.setdefault(int(r["idx"]), []).append(
                        (f(r["spos_ms"]), f(r["t_wall_s"]), int(r["loop"]))
                    )
                except (KeyError, ValueError):
                    continue
            if not ev:
                continue
            S = s.mark_period_ms + iv
            base = min(org.values())
            for p in s.pairs:
                l, e = p
                if l not in org or e not in org:
                    continue
                def wall_at(i):
                    cand = ev.get(i)
                    if not cand:
                        return None
                    spos, tw, _ = min(cand, key=lambda x: abs(x[0] - S))
                    # the closest event is within half an interval of S, or it
                    # is not the boundary the formula talks about
                    if abs(spos - S) > iv / 2.0:
                        return None
                    return tw
                tw_e, tw_l = wall_at(e), wall_at(l)
                if tw_e is None or tw_l is None:
                    continue
                # org stays in seconds here (it feeds the empirical wall-time
                # diff directly); convert the origin term to ms for the formula
                lead = (((org[e] - base) - (org[l] - base)) * 1000.0
                        + S * (1.0 / rate[e] - 1.0 / rate[l]))
                emp = (tw_e - tw_l) * 1000.0
                v0 = s.by_pair_k.get((l, e, s.ks[0]))
                if not v0:
                    continue
                first = v0[0][1]
                start_iv = int(round((first - 2.0 * iv) / iv)) if iv > 0 else 0
                if ppmc[l] == 0.0 and ppmc[e] == 0.0:
                    direction = "aligned"
                elif ppmc[l] != 0.0 and ppmc[e] != 0.0:
                    direction = "both deviate"
                elif ppmc[e] != 0.0:
                    direction = "fast emitter" if ppmc[e] > 0 else "slow emitter"
                else:
                    direction = "fast listener" if ppmc[l] > 0 else "slow listener"
                rows.append([
                    n, "%d<-%d" % (l, e), direction,
                    "%+.1f" % lead, "%+.1f" % emp, "%+.1f" % (emp - lead),
                    "%+d" % start_iv, "yes" if start_iv < 0 else "no",
                ])
                ev_by_dir.setdefault(direction, []).append((emp - lead, start_iv < 0))
        rows.sort(key=lambda r: (r[0], r[1]))
        print(table(rows, ["scenario", "pair", "deviation carried by",
                           "formula lead ms", "empirical lead ms", "diff ms",
                           "start iv", "reads low"]))
        print()
        print("`formula lead ms` is §7c's quantity, computed from the recorded")
        print("origins and the injected rates. `empirical lead ms` is the wall")
        print("time between the emitter's rollover at session position S and the")
        print("listener's rollover at the same session position, both measured by")
        print("the harness to a sample. If the grid model is right the diff column")
        print("is zero in both directions; if the diff itself depends on which")
        print("clock deviates, the formula is missing something structural.\n")
        agg = []
        for dname, vs in sorted(ev_by_dir.items()):
            ds = sorted(v[0] for v in vs)
            flips = sum(1 for v in vs if v[1])
            agg.append([
                dname, len(vs),
                "%+.1f" % ds[0], "%+.1f" % ds[len(ds) // 2], "%+.1f" % ds[-1],
                "%d/%d" % (flips, len(vs)),
            ])
        if agg:
            print(table(agg, ["deviation carried by", "pairs", "min diff ms",
                              "median diff ms", "max diff ms", "reads low"]))
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

    # --- 9. truncation (issue #23) -----------------------------------------
    # A whole audio message going missing is only one way a write can fail to
    # arrive intact. The other is that it arrives SHORT -- intact as a
    # message, with the tail of its payload gone -- and a third is that the
    # byte stream is cut in the middle of a message, which the length-prefixed
    # framing cannot survive at all. They are not variants of one fault.
    # The control is selected by the steady tone: every scenario that carries
    # one is a truncation run, including the deliberately uninjected control.
    tr_names = [n for n in names
                if f(sc[n].summary.get("steady", 0)) > 0
                or sc[n].truncs
                or f(sc[n].summary.get("down_trunc_pct", 0)) > 0
                or f(sc[n].summary.get("down_drop_pct", 0)) > 0
                or f(sc[n].summary.get("srv_trunc_pct", 0)) > 0
                or f(sc[n].summary.get("srv_drop_pct", 0)) > 0]
    if tr_names:
        print("## 9. Truncated messages and truncated byte streams\n")
        print("Loss of a whole audio message is one way a write fails to arrive intact.")
        print("The other is that it arrives SHORT -- intact as a message, with the tail")
        print("of its payload gone -- which nothing detects, because a message's payload")
        print("length is whatever the message says it is")
        print("(`mpb_server_download_interval_write::parse` takes `audio_data_len` from")
        print("the message size and has nothing to check it against). A third case is")
        print("the byte stream itself being cut mid-message. `--steady` puts a quiet")
        print("constant tone on every channel so a remote channel's decoded level is a")
        print("continuous measure of whether its audio is flowing; the runs below are")
        print("measured gaps in that level, at the clock probe's 10 Hz.\n")

        # 9a: what happened to the session
        rows = []
        for n in tr_names:
            s = sc[n]
            for c in s.clients:
                rows.append([
                    n, c["idx"],
                    c.get("final_status", "?"),
                    f"{c.get('markers_decoded', '?')}/{c.get('markers_emitted', '?')}",
                    c.get("rx_msgs_truncated", "0"),
                    c.get("trunc_bytes", "0"),
                    c.get("rx_msgs_dropped", "0"),
                    c.get("drop_bytes", "0"),
                ])
        print(table(rows, ["scenario", "client", "final status", "markers heard",
                           "msgs truncated", "bytes cut", "msgs byte-dropped",
                           "bytes dropped"]))
        print()
        print("`final status` is the NJClient status at teardown: 0 is still healthy.")
        print("A negative value killed the session instead of degrading it.")
        print("`markers heard` is decodes over markers emitted by the other clients.\n")

        # 9b: extent of the damage
        #
        # Measured from the gaps, not from the events. When the injector is on
        # the receive side of a client the two should line up one to one, but
        # when it is on the server's receive thread the client has no record of
        # the event at all -- the gap is the only evidence, and attributing it
        # the other way round would quietly drop those runs.
        rows = []
        for n in tr_names:
            s = sc[n]
            L = s.interval_ms
            if L <= 0:
                continue
            gps = s.gaps()
            starts, durs, nspan, inpk, lvs = [], [], [], [], []
            ends_at_edge = 0
            ngaps = 0
            for li, runs in gps.items():
                evs = [e for e in s.trunc_events() if e[0] == li]
                for (col, a, b, pk, live) in runs:
                    ngaps += 1
                    starts.append(a - (a // L) * L)
                    durs.append(b - a)
                    nspan.append((b - a) / L)
                    inpk.append(pk)
                    lvs.append(live)
                    rem = b % L
                    if min(rem, L - rem) <= 150:
                        ends_at_edge += 1
            # an event explains a gap when the gap begins at or after the
            # event and inside the interval the event damaged: the audio
            # already decoded when the damage happened still plays out, so the
            # gap starts a little AFTER the event rather than at it
            n_matched = 0
            for (li, pos, cut, msg) in s.trunc_events():
                if any(g[1] >= pos - 150 and g[1] < pos + L
                       for g in gps.get(li, [])):
                    n_matched += 1
            rows.append([
                n, ngaps, len(s.trunc_events()), n_matched,
                fmt(median(starts)) if starts else "n/a",
                fmt(min(durs)) if durs else "n/a",
                fmt(median(durs)) if durs else "n/a",
                fmt(max(durs)) if durs else "n/a",
                fmt(median(nspan), 2) if nspan else "n/a",
                fmt(max(nspan), 2) if nspan else "n/a",
                f"{ends_at_edge}/{ngaps}" if ngaps else "n/a",
                fmt(median(inpk), 5) if inpk else "n/a",
                fmt(median(lvs), 5) if lvs else "n/a",
            ])
        print(table(rows, ["scenario", "gaps", "events recorded",
                           "events matched to a gap",
                           "median start in interval ms", "min gap ms",
                           "median gap ms", "max gap ms",
                           "median gap / interval", "max gap / interval",
                           "gaps ending on an interval edge",
                           "median level in gap", "median live level"]))
        print()
        print("`start in interval` is how far into its interval a channel's audio")
        print("stopped. Damage to a write is heard one interval after the message")
        print("arrives, since audio for interval N is received as N closes and")
        print("played during N+1; audio already decoded when the message was cut")
        print("still plays out, so the gap starts slightly after the event.\n")
        print("`max gap / interval` is the bleed test. A gap reaching two or more")
        print("intervals would mean a damaged stream carried into the next one, or")
        print("that the session died. The column is the longest gap anywhere in the")
        print("run, so a value below 1.0 means no gap ever crossed an interval")
        print("boundary, and a large one is a killed session rather than a gap.\n")
        print("`median level in gap` against `median live level` is what the decoder")
        print("produced while the stream was damaged, next to what the same channel")
        print("carries when it is healthy. A decoder that emitted noise, or that")
        print("resynchronised onto garbage, would put the damaged level near the live")
        print("one. The control row is the check on this: with no damage injected, no")
        print("sample of any channel ever falls below the threshold at all, so the")
        print("two states really are distinct rather than a threshold artefact.\n")
        print("`events recorded` is 0 for the server-side rows on purpose: the")
        print("injector is on the server's receive thread and the client keeps no")
        print("record of it, so only the gap shows that anything happened.\n")

        # 9c: fan-out -- who else loses audio at the same interval
        rows = []
        for n in tr_names:
            s = sc[n]
            L = s.interval_ms
            if L <= 0:
                continue
            gps = s.gaps()
            per_iv = defaultdict(lambda: defaultdict(set))
            for li, runs in gps.items():
                for (col, a, b, pk, live) in runs:
                    per_iv[int(a // L)][li].add(col)
            cnt = defaultdict(int)
            same_emitter = 0
            for iv, byl in per_iv.items():
                cnt[len(byl)] += 1
                # two clients losing a gap in the same interval, on the same
                # channel index, is the signature of one damaged upload being
                # forwarded rather than two independent rolls
                if len(byl) >= 2:
                    cols = [set(v) for v in byl.values()]
                    common = set.intersection(*cols) if cols else set()
                    if common:
                        same_emitter += 1
            rows.append([n, len(per_iv)] + [cnt[i] for i in (1, 2, 3)]
                        + [same_emitter])
        print(table(rows, ["scenario", "intervals with a gap",
                           "only 1 client affected", "2 clients affected",
                           "3 clients affected",
                           "2+ clients, same emitter index"]))
        print()
        print("Truncating what a client RECEIVES damages that client alone. Truncating")
        print("on the server's receive thread damages an UPLOAD, which the server then")
        print("forwards, so one damaged write costs every other participant the same")
        print("interval at the same moment. The last column is the check: in the")
        print("server-side row the clients that lost audio in the same interval lost")
        print("it on the SAME emitter index, which two independent rolls would not")
        print("reproduce. A downlink truncation is confined to one client by")
        print("construction, so any interval with two clients affected there is two")
        print("rolls landing together by chance.\n")
        print("`truncloss` is the comparison for scale: the same number of messages")
        print("lost whole rather than shortened.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
