"""Auto-append newly published kernel sub-levels to the per-version
build matrices in kernel-a<android>-<kernel>.yml.

Reads data/<android>/<kernel>.json (kept fresh by update_data.py) and:

1. Appends newly published ASB quarters (dates newer than anything
   already listed) to the `matrix.include` list of each
   kernel-aXX-*.yml, right before the trailing X/lts entry. Existing
   entries are never touched or removed.
2. Keeps the trailing X/lts entry's `display_sub` field (and the job
   name lines that render it) in sync with the JSON "lts" value, so
   run/job names show a real sub-level number instead of the X
   placeholder.

Idempotent: exits 0 and writes nothing when everything is already
up-to-date. Exits 1 on structural errors (missing file / section).
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

MATRIX_FILES = {
    "android12/5.10": "kernel-a12-5-10.yml",
}

# 每个矩阵允许出现的 sub_level 白名单。为空表示不限制（保持原行为）。
# 设置后，sync_matrix_file 只会追加白名单内的子版本，
# 白名单外的老条目也不会被主动删除——需要精简矩阵时请手工改 yml。
ALLOWED_SUBLEVELS = {
    "android12/5.10": {"226", "236", "237"},
}

ITEM_INDENT = "          - "
FIELD_INDENT = "            "
ITEM_PREFIX = "          "  # plain indent used when generating new items


def _split_include_items(block_lines: list[str]) -> list[list[str]]:
    """Split include block lines into items: ['- sub_level..', '  field..']."""
    items: list[list[str]] = []
    for line in block_lines:
        if line.lstrip().startswith("- "):
            items.append([line])
        else:
            items[-1].append(line)
    return items


def sync_matrix_file(data: dict, wf_path: Path,
                     allowed: set[str] | None = None) -> tuple[bool, list[str], list[str]]:
    """Append newly published ASB quarters to matrix.include.

    Existing entries are left untouched; only entries whose date is newer
    than everything already in the matrix are appended, right before the
    trailing X/lts entry (which is preserved together with any extra
    fields attached to it, e.g. revision). Returns (changed, added, removed).

    When `allowed` is provided, only those sub_levels may be appended;
    others are skipped even if newer. This keeps a trimmed-down matrix
    from being re-expanded by the scheduled data update.
    """
    text = wf_path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)

    # locate `include:` under `matrix:`
    inc_idx = None
    for i, line in enumerate(lines):
        if line.strip() == "include:" and i > 0 and lines[i - 1].strip() == "matrix:":
            inc_idx = i
            break
    if inc_idx is None:
        raise ValueError(f"matrix.include block not found in {wf_path.name}")

    # collect existing items until a line that is not part of the list
    start = inc_idx + 1
    end = start
    while end < len(lines):
        s = lines[end]
        if s.startswith(ITEM_INDENT) or (s.strip() and s.startswith(FIELD_INDENT)
                                        and not s.lstrip().startswith("- ")):
            end += 1
            continue
        break
    old_items = _split_include_items(lines[start:end])

    # the trailing X/lts entry (and any extra fields attached to it) stays
    keep = [it for it in old_items
            if any('"lts"' in l or 'sub_level: "X"' in l for l in it)]
    if len(keep) != 1:
        raise ValueError(f"expected exactly one X/lts entry in {wf_path.name}, found {len(keep)}")

    # only quarters newer than everything currently in the matrix get added
    existing_dates = set()
    for it in old_items:
        m = re.search(r'os_patch_level: "([^"]+)"', "".join(it))
        if m and m.group(1) != "lts":
            existing_dates.add(m.group(1))
    max_date = max(existing_dates) if existing_dates else ""

    new_items = []
    for entry in sorted(data.get("entries", []), key=lambda e: e["date"]):
        if entry["date"] <= max_date or entry["date"] in existing_dates:
            continue
        sub = entry["kernel"].rsplit(".", 1)[-1]
        if allowed is not None and sub not in allowed:
            continue
        new_items.append([f"{ITEM_PREFIX}- sub_level: \"{sub}\"\n",
                          f"{FIELD_INDENT}os_patch_level: \"{entry['date']}\"\n"])

    if not new_items:
        return False, [], []

    # insert the new items right before the X/lts entry
    x_start = start + sum(len(it) for it in old_items[: old_items.index(keep[0])])
    lines[x_start:x_start] = [l for it in new_items for l in it]
    wf_path.write_text("".join(lines), encoding="utf-8", newline="")

    def key_of(it):
        joined = "".join(it)
        s = re.search(r'sub_level: "([^"]+)"', joined)
        p = re.search(r'os_patch_level: "([^"]+)"', joined)
        return "%s-%s" % (s.group(1) if s else "?", p.group(1) if p else "?")

    added = [key_of(it) for it in new_items]
    return True, added, []



def sync_lts_display(data: dict, wf_path: Path) -> bool:
    """Keep the X/lts matrix entry's display_sub field and the job name
    lines in sync with data["lts"], so run/job names show a real
    sub-level number instead of the X placeholder. The functional
    sub_level: "X" value is preserved (it still selects the -lts branch).

    Idempotent; returns True when the file was modified.
    """
    lts = data.get("lts") or ""
    m = re.search(r"(\d+)$", str(lts))
    if not m:
        return False
    sub = m.group(1)
    lines = wf_path.read_text(encoding="utf-8").splitlines(keepends=True)
    changed = False

    # 1) job name: render display_sub when the entry carries one
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith("name:") and "${{ matrix.sub_level }}" in line \
                and "display_sub" not in line:
            lines[i] = line.replace("${{ matrix.sub_level }}",
                                    "${{ matrix.display_sub || matrix.sub_level }}")
            changed = True
            break

    # 2) X/lts matrix entry: set/update its display_sub field
    inc_idx = None
    for i, line in enumerate(lines):
        if line.strip() == "include:" and i > 0 and lines[i - 1].strip() == "matrix:":
            inc_idx = i
            break
    if inc_idx is None:
        raise ValueError(f"matrix.include block not found in {wf_path.name}")
    start = inc_idx + 1
    end = start
    while end < len(lines):
        s = lines[end]
        if s.startswith(ITEM_INDENT) or (s.strip() and s.startswith(FIELD_INDENT)
                                        and not s.lstrip().startswith("- ")):
            end += 1
            continue
        break
    items = _split_include_items(lines[start:end])
    x_items = [it for it in items if any('sub_level: "X"' in l for l in it)]
    if len(x_items) != 1:
        raise ValueError(f"expected exactly one X/lts entry in {wf_path.name}, found {len(x_items)}")
    x_item = x_items[0]
    x_start = start + sum(len(it) for it in items[: items.index(x_item)])
    block = lines[x_start : x_start + len(x_item)]
    want = f'{FIELD_INDENT}display_sub: "{sub}"\n'
    disp_idx = next((k for k, l in enumerate(block) if "display_sub:" in l), None)
    if disp_idx is None:
        block.append(want)
        changed = True
    elif block[disp_idx] != want:
        block[disp_idx] = want
        changed = True
    lines[x_start : x_start + len(x_item)] = block

    # 3) uses: pass display_sub through to build.yml
    for i, line in enumerate(lines):
        if re.search(r"^\s*sub_level: \$\{\{ matrix\.sub_level \}\}\s*$", line):
            nxt = lines[i + 1] if i + 1 < len(lines) else ""
            if "display_sub" not in nxt:
                indent = line[: len(line) - len(line.lstrip())]
                lines.insert(i + 1, f"{indent}display_sub: ${{{{ matrix.display_sub || '' }}}}\n")
                changed = True
            break

    if changed:
        wf_path.write_text("".join(lines), encoding="utf-8", newline="")
    return changed


def main() -> int:
    # append new sub-levels to per-version build matrices (kernel-aXX-*.yml)
    for rel, wf_name in MATRIX_FILES.items():
        data_file = ROOT / "data" / f"{rel}.json"
        wf_path = ROOT / ".github" / "workflows" / wf_name
        if not data_file.exists() or not wf_path.exists():
            print(f"::error::matrix sync skipped, missing: {data_file} or {wf_path}",
                  file=sys.stderr)
            return 1
        data = json.loads(data_file.read_text(encoding="utf-8"))
        try:
            changed, added, removed = sync_matrix_file(
                data, wf_path, allowed=ALLOWED_SUBLEVELS.get(rel))
        except ValueError as exc:
            print(f"::error::{exc}", file=sys.stderr)
            return 1
        if changed:
            for a in added:
                print(f"{wf_name}: + {a}")
            print(f"{wf_name}: matrix updated (+{len(added)} new sub-levels)")
        else:
            print(f"{wf_name}: matrix unchanged (no new sub-levels)")

    # keep X/lts display names (job names) in sync with data["lts"]
    for rel, wf_name in MATRIX_FILES.items():
        data_file = ROOT / "data" / f"{rel}.json"
        wf_path = ROOT / ".github" / "workflows" / wf_name
        if not data_file.exists() or not wf_path.exists():
            print(f"::error::lts display sync skipped, missing: {data_file} or {wf_path}",
                  file=sys.stderr)
            return 1
        data = json.loads(data_file.read_text(encoding="utf-8"))
        try:
            if sync_lts_display(data, wf_path):
                print(f"{wf_name}: X/lts display name updated to {data.get('lts')}")
            else:
                print(f"{wf_name}: X/lts display name unchanged")
        except ValueError as exc:
            print(f"::error::{exc}", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
