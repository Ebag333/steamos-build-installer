#!/usr/bin/env python3
"""Compare validation JSON outputs side-by-side.

Reads all .json files from the output directory and produces a comparison
table where each file becomes a column and each validation item becomes a row.

Cell values show the detail (version, repo list, etc.) when available,
otherwise the status (PASS/FAIL/SKIP/INFO).

Usage:
    tools/tests/bin/compare-results.py [DIR]        # default: tools/tests/output
    tools/tests/bin/compare-results.py --format tsv # tab-separated (default)
    tools/tests/bin/compare-results.py --format md  # markdown table
    tools/tests/bin/compare-results.py --section kernel  # filter to one section
"""

import json
import sys
import os
import argparse
from pathlib import Path
from collections import OrderedDict


def load_results(directory: str) -> OrderedDict:
    """Load all .json files, return {column_name: {item: cell_value}}."""
    data = OrderedDict()
    directory = Path(directory)

    for jf in sorted(directory.glob("*.json")):
        column = jf.stem  # filename without .json
        with open(jf) as f:
            raw = json.load(f)

        results = raw.get("results", [])
        items = OrderedDict()
        for r in results:
            item = r.get("item", "")
            detail = r.get("detail", "").strip()
            expected = r.get("expected", "").strip()
            found = r.get("found", "").strip()
            status = r.get("status", "")
            section = r.get("section", "")
            # Use found if available, then detail, then status
            cell = found if found else (detail if detail else status)
            items[item] = {
                "value": cell,
                "section": section,
                "status": status,
                "expected": expected,
                "found": found,
                "detail": detail,
            }

        data[column] = items

    return data


def collect_all_items(data: OrderedDict) -> list:
    """Get the union of all item keys across all columns, preserving order."""
    seen = set()
    items = []
    for column_data in data.values():
        for item in column_data:
            if item not in seen:
                seen.add(item)
                items.append(item)
    return items


def get_section(data: OrderedDict, item: str) -> str:
    """Get the section for an item from whichever column has it."""
    for column_data in data.values():
        if item in column_data:
            return column_data[item]["section"]
    return ""


def truncate(s: str, maxlen: int) -> str:
    if len(s) <= maxlen:
        return s
    return s[: maxlen - 1] + "…"


def print_tsv(data, items, columns, max_item_width=60, max_cell_width=40):
    """Print tab-separated output."""
    # Header
    print("item\t" + "\t".join(columns))
    print("-" * max_item_width + "\t" + "\t".join("-" * max_cell_width for _ in columns))

    for item in items:
        row = [truncate(item, max_item_width)]
        for col in columns:
            cell = data[col].get(item, {})
            val = cell.get("value", "—") if cell else "—"
            row.append(truncate(val, max_cell_width))
        print("\t".join(row))


def print_markdown(data, items, columns, max_item_width=60, max_cell_width=40):
    """Print markdown table."""
    # Calculate column widths
    item_header = "item"
    col_headers = [truncate(c, max_cell_width) for c in columns]

    # Header row
    print("| " + item_header + " | " + " | ".join(col_headers) + " |")
    print("| " + "---" + " | " + " | ".join("---" for _ in columns) + " |")

    for item in items:
        row_item = truncate(item, max_item_width)
        cells = []
        for col in columns:
            cell = data[col].get(item, {})
            val = cell.get("value", "—") if cell else "—"
            cells.append(truncate(val, max_cell_width))
        print("| " + row_item + " | " + " | ".join(cells) + " |")


def print_section_grouped(data, items, columns, max_item_width=60, max_cell_width=40):
    """Print with section headers for readability."""
    current_section = None
    for item in items:
        section = get_section(data, item)
        if section != current_section:
            current_section = section
            if section:
                print(f"\n## {section}")

        row = [truncate(item, max_item_width)]
        for col in columns:
            cell = data[col].get(item, {})
            val = cell.get("value", "—") if cell else "—"
            row.append(truncate(val, max_cell_width))
        print("  " + "  ".join(f"{c:<{max_cell_width}}" for c in row))


def print_json(data, items, columns):
    """Print JSON comparison table."""
    import json as _json

    rows = []
    for item in items:
        section = get_section(data, item)
        values = {}
        for col in columns:
            cell = data[col].get(item, {})
            if cell:
                values[col] = {
                    "status": cell.get("status", "—"),
                    "found": cell.get("found", ""),
                    "expected": cell.get("expected", ""),
                    "detail": cell.get("detail", ""),
                }
            else:
                values[col] = {"status": "—", "found": "", "expected": "", "detail": ""}
        rows.append({
            "item": item,
            "section": section,
            "values": values,
        })

    _json.dump({"columns": columns, "items": rows}, sys.stdout, indent=2)
    print()


def main():
    parser = argparse.ArgumentParser(description="Compare validation JSON outputs")
    parser.add_argument("directory", nargs="?",
                        default=str(Path(__file__).resolve().parent.parent / "output"),
                        help="Directory containing .json files (default: tools/tests/output)")
    parser.add_argument("--format", choices=["tsv", "md", "grouped", "json"], default="tsv",
                        help="Output format (default: tsv)")
    parser.add_argument("--section", default=None,
                        help="Filter to a specific section (e.g., kernel, nvidia, system-config)")
    parser.add_argument("--max-item", type=int, default=60,
                        help="Max width for item column (default: 60)")
    parser.add_argument("--max-cell", type=int, default=40,
                        help="Max width for cell values (default: 40)")
    parser.add_argument("--diff-only", action="store_true",
                        help="Only show rows where values differ across columns")
    args = parser.parse_args()

    data = load_results(args.directory)
    if not data:
        print(f"No .json files found in {args.directory}", file=sys.stderr)
        sys.exit(1)

    columns = list(data.keys())
    items = collect_all_items(data)

    # Filter by section if requested
    if args.section:
        items = [i for i in items if get_section(data, i) == args.section]

    # Filter to diff-only if requested
    if args.diff_only:
        filtered = []
        for item in items:
            values = set()
            for col in columns:
                cell = data[col].get(item, {})
                val = cell.get("value", "—") if cell else "—"
                values.add(val)
            if len(values) > 1:
                filtered.append(item)
        items = filtered

    if not items:
        print("No items to display.", file=sys.stderr)
        sys.exit(0)

    # Print
    if args.format == "tsv":
        print_tsv(data, items, columns, args.max_item, args.max_cell)
    elif args.format == "md":
        print_markdown(data, items, columns, args.max_item, args.max_cell)
    elif args.format == "grouped":
        print_section_grouped(data, items, columns, args.max_item, args.max_cell)
    elif args.format == "json":
        print_json(data, items, columns)


if __name__ == "__main__":
    main()
