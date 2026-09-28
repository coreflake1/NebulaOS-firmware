#!/bin/sh
# Supply-chain closure artifacts for a configured NebulaOS Buildroot tree.
#
# Mission section 26. Produces, into artifacts/sbom/:
#
#   show-info.json          Buildroot's own package inventory, verbatim
#   sbom.cyclonedx.json     CycloneDX 1.5 SBOM
#   source-manifest.txt     one line per downloaded artifact, with its hash
#   packages.txt            name, version, licence - human-readable
#
# Buildroot 2025.02.18 emits `make show-info` (JSON) and `make legal-info`, but
# has no CycloneDX generator, so the conversion lives here.
#
# `make show-info` needs only a CONFIGURED tree - it does not build or download
# anything, so this is cheap and safe to run at any point after stage 02.
# `make legal-info` is NOT run here: it downloads the full source of every
# package, which is a deliberate, separate, network-heavy step.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
BUILDROOT_DIR=${NEBULAOS_BUILDROOT_DIR:-$REPO_ROOT/vendor/buildroot-x2000}
BR2_EXT=$REPO_ROOT/br2-external
OUT=${1:-$REPO_ROOT/artifacts/sbom}

[ -f "$BUILDROOT_DIR/.config" ] || {
	echo "FATAL: $BUILDROOT_DIR/.config not found - run scripts/build/02-configure-buildroot.sh first" >&2
	exit 1
}
mkdir -p "$OUT"

echo "== collecting Buildroot package inventory =="
( cd "$BUILDROOT_DIR" && make BR2_EXTERNAL="$BR2_EXT" show-info ) > "$OUT/show-info.json"

python3 - "$OUT" "$BUILDROOT_DIR" <<'PY'
import json, os, sys, datetime

out, topdir = sys.argv[1], sys.argv[2]
info = json.load(open(os.path.join(out, "show-info.json")))

# SOURCE_DATE_EPOCH keeps this reproducible; without it the timestamp alone
# would make two otherwise identical SBOMs differ.
epoch = os.environ.get("SOURCE_DATE_EPOCH")
ts = (datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc)
      if epoch else datetime.datetime.now(datetime.timezone.utc)
      ).strftime("%Y-%m-%dT%H:%M:%SZ")

def load_hashes(paths):
    """show-info reports `hashes` as a list of PATHS to .hash files, not as
    hash values. Each line is `<alg>  <value>  <filename>`, # comments allowed.
    Returns {filename: {alg: value}}."""
    table = {}
    for rel in paths or []:
        path = rel if os.path.isabs(rel) else os.path.join(topdir, rel)
        try:
            with open(path) as fh:
                for line in fh:
                    line = line.split("#", 1)[0].strip()
                    if not line:
                        continue
                    parts = line.split()
                    if len(parts) >= 3:
                        table.setdefault(parts[2], {})[parts[0].lower()] = parts[1]
        except OSError:
            continue
    return table

def clean_uri(u):
    """show-info prefixes each URI with its download method, e.g.
    'https+https://...' or 'https|urlencode+https://...'."""
    return u.split("+", 1)[1] if "+" in u.split("://", 1)[0] else u

components, manifest, plain = [], [], []
nohash = 0

for name in sorted(info):
    p = info[name] or {}
    if p.get("virtual"):
        continue
    version = p.get("version") or ""
    licenses = p.get("licenses") or ""
    table = load_hashes(p.get("hashes"))
    downloads = p.get("downloads") or []

    comp = {
        "type": "library",
        "name": name,
        "version": version,
        "scope": "required",
        "purl": "pkg:generic/%s@%s" % (name, version) if version else "pkg:generic/%s" % name,
    }
    if licenses:
        comp["licenses"] = [{"license": {"name": lic.strip()}}
                            for lic in licenses.split(",") if lic.strip()]

    cdx_hashes, seen, refs = [], set(), []
    for d in downloads:
        src = d.get("source") if isinstance(d, dict) else None
        if not src:
            continue
        for u in (d.get("uris") or []):
            refs.append(clean_uri(u))
        got = table.get(src, {})
        if not got:
            nohash += 1
            manifest.append("%-38s %-14s %-8s %s" % (name, version or "-", "NOHASH", src))
            continue
        for alg in sorted(got):
            manifest.append("%-38s %-14s %-8s %s  %s" % (name, version or "-", alg, got[alg], src))
            a = {"sha256": "SHA-256", "sha512": "SHA-512",
                 "sha1": "SHA-1", "md5": "MD5"}.get(alg)
            if a and (a, got[alg]) not in seen:
                seen.add((a, got[alg]))
                cdx_hashes.append({"alg": a, "content": got[alg]})

    if cdx_hashes:
        comp["hashes"] = cdx_hashes
    if refs:
        comp["externalReferences"] = [{"type": "distribution", "url": u}
                                      for u in sorted(set(refs))]

    components.append(comp)
    plain.append("%-38s %-16s %s" % (name, version or "-", licenses or "-"))

bom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "version": 1,
    "metadata": {
        "timestamp": ts,
        "component": {"type": "operating-system", "name": "NebulaOS",
                      "version": "buildroot-2025.02.18"},
        "tools": [{"vendor": "NebulaOS", "name": "generate-sbom.sh", "version": "1"}],
    },
    "components": components,
}

with open(os.path.join(out, "sbom.cyclonedx.json"), "w") as fh:
    json.dump(bom, fh, indent=2, sort_keys=True); fh.write("\n")
with open(os.path.join(out, "source-manifest.txt"), "w") as fh:
    fh.write("\n".join(manifest) + "\n")
with open(os.path.join(out, "packages.txt"), "w") as fh:
    fh.write("\n".join(plain) + "\n")

print("SBOM_COMPONENTS=%d" % len(components))
print("SBOM_HASHED_ARTIFACTS=%d" % (len(manifest) - nohash))
print("SBOM_DOWNLOADS_WITHOUT_HASH=%d" % nohash)
PY

echo "== wrote $OUT/{show-info.json,sbom.cyclonedx.json,source-manifest.txt,packages.txt} =="
