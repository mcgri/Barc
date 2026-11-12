#!/usr/bin/env python3
"""Reads the local RAM history log and says where each day's memory went.

The log only exists in a build made with `make bundle RAM_LOG=1`. Release builds
do not contain it. See Sources/Barc/Diagnostics/RAMHistoryLog.swift.

  Tools/ram-report.py                one line for each of the last 14 days
  Tools/ram-report.py --days 30      the same for 30 days
  Tools/ram-report.py 2026-11-06     one day in detail
  Tools/ram-report.py today          today in detail
"""
import argparse
import datetime
import json
import pathlib
import statistics
import sys
from collections import Counter, defaultdict

DEFAULT = pathlib.Path.home() / "Library/Application Support/io.github.mcgri.Barc/ram-history"


def read_day(path):
    """Rows from one day. A crash can leave half a last line, so bad lines are skipped."""
    samples, others = [], []
    for line in path.read_text(encoding="utf8").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        (samples if row.get("event") == "sample" else others).append(row)
    return samples, others


def size(mb):
    return f"{mb / 1024:.2f} GB" if mb >= 1024 else f"{mb:.0f} MB"


def clock(row):
    return row["time"][11:16]


def table(rows, headers):
    widths = [max(len(str(r[i])) for r in [headers] + rows) for i in range(len(headers))]
    for row in [headers] + rows:
        print("  ".join(str(cell).ljust(width) for cell, width in zip(row, widths)).rstrip())


def overview(directory, days):
    files = sorted(directory.glob("????-??-??.jsonl"))[-days:]
    rows = []
    for path in files:
        samples, others = read_day(path)
        if not samples:
            continue
        totals = [s["totalMB"] for s in samples]
        peak = max(samples, key=lambda s: s["totalMB"])
        rows.append([
            path.stem, f"{len(samples) / 60:.1f}h", size(statistics.mean(totals)), size(peak["totalMB"]), clock(peak),
            size(min(totals)), f"{statistics.mean(s['awakeTabs'] for s in samples):.1f}",
            max((s.get("pressure") or 1) for s in samples), sum(1 for o in others if o.get("event") == "launch"),
        ])
    if not rows:
        print(f"No samples in {directory}")
        return
    table(rows, ["day", "logged", "average", "peak", "at", "lowest", "awake tabs", "pressure", "launches"])


def detail(path):
    samples, others = read_day(path)
    if not samples:
        print(f"No samples in {path}")
        return
    totals = [s["totalMB"] for s in samples]
    peak = max(samples, key=lambda s: s["totalMB"])
    print(f"{path.stem}: {len(samples)} samples, {len(samples) / 60:.1f} hours logged")
    print(f"Total   average {size(statistics.mean(totals))}, peak {size(peak['totalMB'])} at {clock(peak)}, lowest {size(min(totals))}")
    if any(s.get("incomplete") for s in samples):
        share = sum(1 for s in samples if s.get("incomplete")) / len(samples)
        print(f"        {share:.0%} of samples could not read every process, so those totals are a floor")
    launches = [o for o in others if o.get("event") == "launch"]
    if launches:
        versions = sorted({o.get("version", "?") for o in launches})
        print(f"Runs    {len(launches)} launch(es) of {', '.join(versions)}")
    print(f"Tabs    {statistics.mean(s['awakeTabs'] for s in samples):.1f} awake on average, "
          f"{max(s['awakeTabs'] for s in samples)} at most, {samples[-1]['sleepingTabs']} asleep at the end")
    swap = [s["swapUsedMB"] for s in samples if s.get("swapUsedMB") is not None]
    pressure = Counter(s.get("pressure") for s in samples if s.get("pressure"))
    if swap:
        print(f"System  swap up to {size(max(swap))}, pressure "
              + ", ".join(f"{ {1: 'normal', 2: 'warning', 4: 'critical'}.get(k, k)} {v}" for k, v in sorted(pressure.items())))
    cost = [s["sampleMS"] for s in samples]
    print(f"Logger  {statistics.mean(cost):.0f} ms per sample on average, {max(cost):.0f} ms at most")

    print("\nWhere it went, on average")
    parts = [("Pages", "pagesMB"), ("Barc UI", "uiMB"), ("GPU", "gpuMB"), ("Network", "networkMB"), ("Panels and other", "auxiliaryMB")]
    table([[name, size(statistics.mean(s[key] for s in samples)), size(max(s[key] for s in samples))] for name, key in parts],
          ["part", "average", "peak"])

    # A shared process has one reading for all its pages, so each gets an equal
    # share. Whatever WebKit really spends per page is not available.
    sites = defaultdict(lambda: {"sum": 0.0, "minutes": 0, "peak": 0.0, "high": 0.0})
    reasons = Counter()
    for sample in samples:
        for process in sample.get("processes", []):
            pages = process.get("pages", [])
            for page in pages:
                site = sites[page["host"]]
                site["sum"] += process["memoryMB"] / len(pages)
                site["minutes"] += 1
                site["peak"] = max(site["peak"], process["memoryMB"])
                site["high"] = max(site["high"], process.get("peakMB") or 0)
                if page.get("state"):
                    reasons[page["state"]] += 1
    ranked = sorted(sites.items(), key=lambda item: item[1]["sum"], reverse=True)[:15]
    print("\nSites, by memory over the day (MB-hours; shared processes split evenly)")
    table([[host, f"{v['sum'] / 60:.0f}", f"{v['minutes'] / 60:.1f}h", size(v["peak"]), size(v["high"])] for host, v in ranked],
          ["site", "MB-hours", "awake", "peak seen", "process high-water"])
    print("\nWhat kept pages awake (page-hours)")
    table([[reason, f"{count / 60:.1f}"] for reason, count in reasons.most_common(10)], ["state", "hours"])

    print(f"\nAt the peak, {clock(peak)}: {size(peak['totalMB'])}")
    table([[process["kind"], size(process["memoryMB"]), ", ".join(sorted({p["host"] for p in process.get("pages", [])}))[:70]]
           for process in peak.get("processes", [])[:10]], ["process", "memory", "pages"])


def main():
    parser = argparse.ArgumentParser(description="Where Barc's memory went, day by day.")
    parser.add_argument("day", nargs="?", help="YYYY-MM-DD or 'today' for one day in detail")
    parser.add_argument("--days", type=int, default=14)
    parser.add_argument("--dir", type=pathlib.Path, default=DEFAULT)
    options = parser.parse_args()
    if not options.dir.is_dir():
        sys.exit(f"No log at {options.dir}. It needs a build made with `make bundle RAM_LOG=1`.")
    if options.day:
        day = datetime.date.today().isoformat() if options.day == "today" else options.day
        path = options.dir / f"{day}.jsonl"
        if not path.exists():
            sys.exit(f"Nothing logged for {day}.")
        detail(path)
    else:
        overview(options.dir, options.days)


if __name__ == "__main__":
    main()
