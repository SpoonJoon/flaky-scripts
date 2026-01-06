#!/usr/bin/env python3
import sys, os, glob, csv, re

# Usage: python3 make_violations_long.py <dir-with-run-*>
# Input:  <dir>/run-*/violation-counts
# Output: <dir>/violations_long.csv
# Columns: run,spec,file,line,count

if len(sys.argv) != 2:
    print("Usage: python3 make_violations_long.py <dir-with-run-*>", file=sys.stderr)
    sys.exit(2)

root = os.path.abspath(sys.argv[1])
if not os.path.isdir(root):
    print(f"Not a directory: {root}", file=sys.stderr)
    sys.exit(2)

out_path = os.path.join(root, "violations_long.csv")

# Example line:
# 3 Specification Closeable_MultipleClose has been violated on line org.apache...ThresholdingOutputStream.close(ThresholdingOutputStream.java:164). Documentation ...
line_re = re.compile(r"^(\d+)\s+Specification\s+(.*?)\s+has been violated on line\s+(.*)$")
fileline_re = re.compile(r".*\(([^()]+\.java):(\d+)\)\s*$")  # grabs "...(Foo.java:123)"

def parse(line: str):
    line = line.strip()
    if not line:
        return None
    m = line_re.match(line)
    if not m:
        return None

    count = int(m.group(1))
    spec = m.group(2).strip()
    loc = m.group(3).split(". Documentation", 1)[0].strip()

    fm = fileline_re.match(loc)
    if fm:
        file_ = os.path.basename(fm.group(1))  # Foo.java
        line_no = int(fm.group(2))             # 123
        return spec, file_, line_no, count

    # Fallback: find last occurrence of "Foo.java:123" anywhere
    hits = re.findall(r"([^()\s]+\.java):(\d+)", loc)
    if hits:
        file_, line_no = hits[-1]
        return spec, os.path.basename(file_), int(line_no), count

    return spec, "", "", count  # unknown parse

def run_num(path: str) -> int:
    m = re.search(r"run-(\d+)", os.path.basename(path))
    return int(m.group(1)) if m else 10**18

runs = sorted(glob.glob(os.path.join(root, "run-*")), key=run_num)

with open(out_path, "w", newline="", encoding="utf-8") as out:
    w = csv.writer(out)
    w.writerow(["run", "spec", "file", "line", "count"])
    for run_dir in runs:
        vc = os.path.join(run_dir, "violation-counts")
        if not os.path.isfile(vc):
            continue
        run_name = os.path.basename(run_dir)
        with open(vc, "r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                parsed = parse(raw)
                if not parsed:
                    continue
                spec, file_, line_no, count = parsed
                w.writerow([run_name, spec, file_, line_no, count])

print(f"Wrote {out_path}")

