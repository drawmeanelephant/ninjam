#!/usr/bin/env python3
"""Cross-check the slip-threshold numbers in REPORT.md against tables.md.

The drift threshold was originally written up with counts ("11 events, four
offsets") that did not match the table beside them. This makes that class of
error impossible to reintroduce: it re-derives every bracket from the analyzer
output and asserts the report quotes it.

Usage:  python3 tools/verify_report_brackets.py [results-dir]
Exit 0 if REPORT.md agrees with the analyzer, 1 otherwise.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPORT = os.path.join(ROOT, "REPORT.md")
ANALYZER = os.path.join(ROOT, "tools", "analyze_interval_lab.py")

ROW = re.compile(
    r"^\| (?P<sc>\w+)\s+\|\s+(?P<l>\d)<-(?P<e>\d)\s+\|"
    r".*?\|\s+(?P<slips>\d+)\s+\|"
    r"\s+(?P<start>[+-]\d+)\s+\|"
    r"\s+(?P<los>[\d.]+|none)\s+\|\s+(?P<his>[\d.]+|none)\s+\|"
    r"\s+(?P<lo>[\d.]+|n/a)\s+\|\s+(?P<hi>[\d.]+|n/a)\s+\|"
    r"\s+(?P<al>\w+)\s+\|"
)


def main():
    results = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "results")
    tables = subprocess.run(
        [sys.executable, ANALYZER, results],
        capture_output=True, text=True, check=True,
    ).stdout

    report = open(REPORT).read()
    report_rows = {}
    for line in report.splitlines():
        # drift< ppm> and drift< ppm>iv<N>s both name a drift scenario: the
        # suffix marks the interval the run was made at, which is what section
        # 2.2 compares. The bracket check has to cover the tempo variants too,
        # or adding a rung at another interval silently escapes verification.
        m = re.match(r"^\| (drift\d+(?:iv\d+s)?|baseline) \| (\d)<-(\d) \|", line)
        if m:
            # A scenario/pair can appear in more than one table (the slip/no-slip
            # ladder and the bracket table). Keep the row that actually carries
            # interval figures, otherwise the ladder row shadows the real one.
            key = (m.group(1), "%s<-%s" % (m.group(2), m.group(3)))
            if key not in report_rows or " iv" in line:
                report_rows[key] = line

    checked = missing = 0
    problems = []
    aligned, offset_pairs = [], []

    for line in tables.splitlines():
        m = ROW.match(line)
        if not m:
            continue
        g = m.groupdict()
        if g["lo"] == "n/a":
            continue
        key = (g["sc"], "%s<-%s" % (g["l"], g["e"]))
        if g["start"] == "+0":
            aligned.append((key, g["lo"], g["hi"]))
        else:
            offset_pairs.append((key, g["lo"], g["hi"]))

        row = report_rows.get(key)
        if row is None:
            missing += 1
            problems.append("no REPORT.md row for %s %s" % key)
            continue
        if ("**%s iv**" % g["lo"]) not in row and (" %s iv" % g["lo"]) not in row:
            problems.append("%s %s: lower bound %s not in report" % (key + (g["lo"],)))
        elif ("%s iv" % g["hi"]) not in row:
            problems.append("%s %s: upper bound %s not in report" % (key + (g["hi"],)))
        else:
            checked += 1

    print("slip brackets: %d verified against REPORT.md, %d missing"
          % (checked, missing))
    print("  pairs starting aligned (+0 iv): %d" % len(aligned))
    if aligned:
        los = [float(lo) for _, lo, _ in aligned]
        his = [float(hi) for _, _, hi in aligned]
        print("    lower bounds %.2f-%.2f iv" % (min(los), max(los)))
        print("    upper bounds %.2f-%.2f iv" % (min(his), max(his)))
    print("  pairs with a whole-interval startup offset: %d" % len(offset_pairs))
    for key, lo, hi in offset_pairs:
        print("    %s %s -> %s-%s iv (excluded from the threshold)" % (key + (lo, hi)))

    # The report must not still claim the old, wrong counts. "1.02-1.07" is
    # only acceptable as a description of the eight non-outlier upper bounds.
    for stale in ("11 slip events", "eleven land"):
        for name, text in (("REPORT.md", report),):
            if stale in text:
                problems.append("%s still contains stale claim %r" % (name, stale))

    if problems:
        print("\nFAIL")
        for p in problems:
            print("  " + p)
        return 1
    print("\nOK: REPORT.md agrees with the analyzer")
    return 0


if __name__ == "__main__":
    sys.exit(main())
