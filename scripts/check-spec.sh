#!/bin/bash

# Checks the hand-written response model against the pinned OpenAPI spec.
#
# Nothing generates this client, so the model is kept in step by hand and this is
# what catches a spec that moved: a property added, one removed, or one whose
# optionality changed. Run it after scripts/download-spec.sh, and edit
# src/database.zig until it passes.
#
# Every v2 response schema is checked, because on this API they ARE the surface:
# there is no lookup endpoint whose answer matters more than the rest. v1 is
# legacy and customer-specific and this client does not speak it, so its schemas
# are deliberately absent below.
#
# Optionality is read the way the model spells it: a Zig field with a default is
# optional, one without is required. A spec property counts as required only when
# it is in `required` AND is not `nullable`, since a nullable property still has
# to parse when it arrives as null.

set -euo pipefail

cd "$(dirname "$0")/.."

SPEC="${SPEC:-spec/openapi.yaml}"
MODEL="${MODEL:-src/database.zig}"

# The comparison is indentation-driven rather than a YAML parse, so it needs no
# dependency beyond the python already on any box that runs the integration
# suite. Schema names sit at four spaces, their keys at six, property names at
# eight, and a property's own keys at ten.
python3 - "$SPEC" "$MODEL" <<'PY'
import re
import sys

spec_path, model_path = sys.argv[1], sys.argv[2]

# <spec schema>: <zig struct>. They differ in one place only: `Database` would
# collide with the client method that returns it.
PAIRS = {
    "Database": "DatabaseFamily",
    "DatabaseVersion": "DatabaseVersion",
    "DatabaseMetadata": "DatabaseMetadata",
    "DatabaseMetadataColumn": "DatabaseMetadataColumn",
    "DbChecksums": "Checksums",
    "Download": "DownloadAttempt",
}


def spec_members(lines, schema):
    members, required, nullable = set(), set(), set()
    inside, mode, current = False, None, None
    for line in lines:
        if line.rstrip() == f"    {schema}:":
            inside = True
            continue
        if not inside:
            continue
        if re.match(r"^    [A-Za-z]", line):
            break
        if line.startswith("      required:"):
            mode = "required"
            continue
        if line.startswith("      properties:"):
            mode = "properties"
            continue
        if re.match(r"^      [a-z]", line):
            mode = None
        if mode == "required" and line.startswith("        - "):
            required.add(line.split()[1])
        elif mode == "properties":
            name = re.match(r"^        ([a-z0-9_]+):", line)
            if name:
                current = name.group(1)
                members.add(current)
            elif line.startswith("          nullable: true") and current:
                nullable.add(current)
    # A nullable property has to parse when it arrives as null, so it is optional
    # in the model however the spec lists it.
    return {(name, name in required and name not in nullable) for name in members}


def model_members(lines, struct):
    members = set()
    inside = False
    for line in lines:
        if line.rstrip() == f"pub const {struct} = struct {{":
            inside = True
            continue
        if not inside:
            continue
        if line.startswith("};"):
            break
        field = re.match(r'^    ([a-z0-9_@"]+):', line)
        if field:
            members.add((field.group(1).strip('@"'), " = " not in line))
    return members


def render(members):
    return sorted(f"{name}{' required' if req else ''}" for name, req in members)


spec = open(spec_path).readlines()
model = open(model_path).readlines()
failed = False
for schema, struct in PAIRS.items():
    want, got = spec_members(spec, schema), model_members(model, struct)
    if not want:
        print(f"  FAIL {schema} -> {struct}: no such schema in {spec_path}", file=sys.stderr)
        failed = True
        continue
    if want == got:
        print(f"  ok   {schema} -> {struct} ({len(want)} members)")
        continue
    failed = True
    print(f"  FAIL {schema} -> {struct}", file=sys.stderr)
    print("       'required' means the model field has no default", file=sys.stderr)
    for member in sorted(set(render(want)) - set(render(got))):
        print(f"       spec only:  {member}", file=sys.stderr)
    for member in sorted(set(render(got)) - set(render(want))):
        print(f"       model only: {member}", file=sys.stderr)

if failed:
    print(f"==> DRIFT between {spec_path} and {model_path}", file=sys.stderr)
    sys.exit(1)
print(f"==> {model_path} matches {spec_path} across {len(PAIRS)} schemas")
PY
