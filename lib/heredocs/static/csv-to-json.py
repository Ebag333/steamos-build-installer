import csv
import json
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8", newline="") as f:
    rows = list(csv.DictReader(f, delimiter="\t"))

for row in rows:
    reqby = row.get("REQBY", "-")
    row["REQBY"] = int(reqby) if reqby.isdigit() else None

    arch_base = row.get("ARCH_BASE")
    if arch_base == "YES":
        row["ARCH_BASE"] = True
    elif arch_base == "NO":
        row["ARCH_BASE"] = False
    else:
        row["ARCH_BASE"] = None

    flags = row.get("FLAGS", "-")
    row["FLAGS"] = [] if flags in ("", "-") else flags.split(",")

json.dump(rows, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
