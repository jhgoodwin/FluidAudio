#!/usr/bin/env python3
"""Compare parakeet-bench pass files: totals, transcript differences vs the first file, per-clip latency."""
import json
import statistics
import sys


def load(path):
    with open(path) as f:
        return {clip["name"]: clip for clip in json.load(f)["clips"]}


def latency(clips, keep):
    values = sorted(c["processingSeconds"] * 1000 for c in clips.values() if keep(c))
    if not values:
        return "-"
    return f"{statistics.median(values):.0f}/{values[int(0.9 * len(values))]:.0f}"


paths = sys.argv[1:]
if len(paths) < 2:
    sys.exit("usage: compare.py <baseline.json> <other.json> [...]")
passes = [(path, load(path)) for path in paths]
baseline = passes[0][1]
print("file\ttotal s\tRTFx\tdiffs\tmedian/p90 ms all\t<=15s\t>15s")
for path, clips in passes:
    total = sum(c["processingSeconds"] for c in clips.values())
    audio = sum(c["audioSeconds"] for c in clips.values())
    diffs = sum(baseline[n]["text"] != clips.get(n, {}).get("text") for n in baseline)
    print(
        f"{path}\t{total:.2f}\t{audio / total:.1f}\t{diffs}\t{latency(clips, lambda c: True)}\t"
        f"{latency(clips, lambda c: c['audioSeconds'] <= 15)}\t{latency(clips, lambda c: c['audioSeconds'] > 15)}"
    )
