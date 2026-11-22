#!/bin/bash

# Checks the hand-written response model against the pinned OpenAPI spec.
#
# Nothing generates this client, so the model is kept in step by hand and this is
# what catches a spec that moved: a property added, one removed, or one whose
# optionality changed. Run it after scripts/download-spec.sh, and edit
# src/database.zig, src/lookup.zig or src/entitlement.zig until it passes.
#
# Every v2 database schema, every lookup schema and the entitlement are
# checked: a lookup member that is optional in the spec reads as null when a
# plan leaves it out, so a drift there is a wrong ANSWER rather than a missing
# convenience. v1 is legacy and customer-specific and this client does not speak
# it, so its schemas are deliberately absent below.
#
# Optionality is read the way the model spells it: a Zig field with a default is
# optional, one without is required, and a nullable property has to be an
# optional type, with a default or without, since it still has to parse when it
# arrives as null. The one exception is a member the spec made required after a
# caller could already write the struct out: it keeps its default, so that
# caller's struct literal still builds until a major, and counts as required
# here only while a `.required = true` row in src/strict.zig makes the decoder
# refuse an answer without it.

set -euo pipefail

cd "$(dirname "$0")/.."

SPEC="${SPEC:-spec/openapi.yaml}"

# The comparison is indentation-driven rather than a YAML parse, so it needs no
# dependency beyond the python already on any box that runs the integration
# suite. Schema names sit at four spaces, their keys at six, property names at
# eight, and a property's own keys at ten.
python3 - "$SPEC" <<'PY'
import re
import sys

spec_path = sys.argv[1]

# <spec schema>: (<zig struct>, <file>). `DbChecksums`, `Download` and the three
# lookup answers are spelled differently in the model; the rest carry the spec's
# own name, and the entitlement's live in src/entitlement.zig.
PAIRS = {
    "Database": ("Database", "src/database.zig"),
    "DatabaseVersion": ("DatabaseVersion", "src/database.zig"),
    "DatabaseMetadata": ("DatabaseMetadata", "src/database.zig"),
    "DatabaseMetadataColumn": ("DatabaseMetadataColumn", "src/database.zig"),
    "DbChecksums": ("Checksums", "src/database.zig"),
    "Download": ("DownloadAttempt", "src/database.zig"),
    "LookupResponse": ("Answer", "src/lookup.zig"),
    "AsnLookupResponse": ("AsnAnswer", "src/lookup.zig"),
    "DomainLookupResponse": ("DomainAnswer", "src/lookup.zig"),
}
for schema in (
    "ClassDetail", "ProxyDetail", "PubproxyDetail", "CarrierDetail", "SatelliteDetail", "SshDetail",
    "SmtpDetail", "WebDetail", "DnsResolverDetail", "BitTorrentDetail", "Location", "Asn", "Company",
    "AbuseContact", "Whois", "Rwhois", "HostedDomains", "AsnPrefix", "DomainDns", "DnsAddressRecord",
    "DnsMxRecord", "DnsNsRecord", "DnsCnameRecord", "DomainHost", "CohostedDomains", "DomainIpRanges",
    "DomainIpRange", "DisposableDetail", "DomainWeb", "DomainWebLinks", "DomainRedirects", "DomainBacklinks",
    "BotDetail", "UserAgentVerdict",
):
    PAIRS[schema] = (schema, "src/lookup.zig")
for schema in ("Entitlement", "EntitlementApikey", "EntitlementPlan", "EntitlementUsage"):
    PAIRS[schema] = (schema, "src/entitlement.zig")


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
    return {
        (name, "nullable" if name in nullable else "required" if name in required else "optional")
        for name in members
    }


# (<file>, <struct>, <member>) for every member src/strict.zig's table requires
# on the wire though its struct gives it a default.
def wire_required():
    rows = set()
    for line in open("src/strict.zig"):
        row = re.match(r'^\s*\.\{ \.T = ([a-z_]+)\.([A-Za-z]+), \.name = "([a-z0-9_]+)",(.*)\},', line)
        if row and ".required = true" in row.group(4):
            rows.add((f"src/{row.group(1)}.zig", row.group(2), row.group(3)))
    return rows


def model_members(lines, struct, schema, model_path):
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
        field = re.match(r'^    ([a-z0-9_@"]+): (\??)', line)
        if field:
            name, optional_type, defaulted = field.group(1).strip('@"'), field.group(2) == "?", " = " in line
            if defaulted and (model_path, struct, name) in required_on_wire:
                defaulted = False
            members.add((name, model_kind(schema, name, optional_type, defaulted)))
    return members


# The model's side in the spec's words, so the two sets compare directly. A
# nullable member needs an optional type and no particular default.
def model_kind(schema, name, optional_type, defaulted):
    if optional_type and spec_kinds.get((schema, name)) == "nullable":
        return "nullable"
    return "optional" if defaulted else "required"


def render(members):
    return sorted(f"{name}{'' if kind == 'optional' else ' ' + kind}" for name, kind in members)


spec = open(spec_path).readlines()
required_on_wire = wire_required()
models = {}
spec_kinds = {}
for schema in PAIRS:
    for name, kind in spec_members(spec, schema):
        spec_kinds[(schema, name)] = kind
failed = False
for schema, (struct, model_path) in PAIRS.items():
    if model_path not in models:
        models[model_path] = open(model_path).readlines()
    want, got = spec_members(spec, schema), model_members(models[model_path], struct, schema, model_path)
    if not want:
        print(f"  FAIL {schema} -> {struct}: no such schema in {spec_path}", file=sys.stderr)
        failed = True
        continue
    if want == got:
        print(f"  ok   {schema} -> {struct} ({len(want)} members)")
        continue
    failed = True
    print(f"  FAIL {schema} -> {struct}", file=sys.stderr)
    print("       'required' means the model field has no default, 'nullable' an optional type", file=sys.stderr)
    for member in sorted(set(render(want)) - set(render(got))):
        print(f"       spec only:  {member}", file=sys.stderr)
    for member in sorted(set(render(got)) - set(render(want))):
        print(f"       model only: {member}", file=sys.stderr)

if failed:
    print(f"==> DRIFT between {spec_path} and the model", file=sys.stderr)
    sys.exit(1)
print(f"==> the model matches {spec_path} across {len(PAIRS)} schemas")
PY
