#!/usr/bin/env python3
"""Which firmware files are PRODUCT inputs, and does a change need a rebuild?

PRODUCT_HEAD is the commit whose build produced an image. CONTROL_HEAD is the
host-side tooling used to operate on it. Moving CONTROL_HEAD - the Hardware
Agent, tests, docs, packaging, workspace control - must not invalidate an
already-built product. Only a change to an actual build input does.

The classification is DENY-LIST, on purpose: every path is a product input
unless it is listed below as host-side. An unknown new directory therefore
errs towards "rebuild", never towards silently reusing a stale image.

Usage:
  product-inputs.py classify <path>...           # PRODUCT / HOST per path
  product-inputs.py changed <base> [<head>]      # did product inputs change?
  product-inputs.py current-build [<head>]       # newest build whose product
                                                 # inputs equal <head>'s
"""
import glob
import os
import subprocess
import sys

FW = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD_BASE = os.environ.get("NEBULAOS_BUILD_BASE", "/var/tmp/nebulaos-build")

# Host-side, never read by build.sh into xImage/rootfs. Prefixes end in "/".
HOST_PREFIXES = (
    "tools/",              # Hardware Agent, attestation, workspace control, this file
    "tests/",
    "docs/",
    ".github/",
    "LICENSES/",
    "scripts/qa/",
    "scripts/package/",    # packages an already-built image into .img/.ingenic
    "scripts/parity/",
)
HOST_FILES = (
    "scripts/release.sh",
    "scripts/flash-spare-slot.sh",  # on-device install helper, a CONTROL file
    ".gitignore",
)


def is_product(path):
    if path in HOST_FILES or path.startswith(HOST_PREFIXES):
        return False
    if "/" not in path and path.endswith(".md"):
        return False       # top-level prose
    return True


def git(*args):
    return subprocess.run(["git", "-C", FW] + list(args), capture_output=True,
                          text=True, check=True).stdout


def changed_product_files(base, head):
    names = git("diff", "--name-only", base, head).split("\n")
    return [n for n in names if n and is_product(n)]


def read_record(path):
    rec = {}
    try:
        with open(path) as fh:
            for line in fh:
                k, sep, v = line.rstrip("\n").partition("=")
                if sep:
                    rec[k] = v
    except OSError:
        pass
    return rec


def current_build(head):
    found = []
    for rec_path in glob.glob(os.path.join(BUILD_BASE, "*", "run-*", ".nebulaos-build-verified")):
        rec = read_record(rec_path)
        src = rec.get("SOURCE_HEAD", "")
        if rec.get("BUILD_VERIFIED") != "YES" or len(src) != 40:
            continue
        try:
            if changed_product_files(src, head):
                continue
        except subprocess.CalledProcessError:
            continue       # the built commit is not in this repository
        found.append(rec)
    found.sort(key=lambda r: r.get("ATTESTED_AT", ""), reverse=True)
    return found[0] if found else None


def main(argv):
    if not argv:
        print(__doc__.strip())
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "classify" and args:
        for p in args:
            print("%s %s" % ("PRODUCT" if is_product(p) else "HOST", p))
        return 0
    if cmd == "changed" and 1 <= len(args) <= 2:
        files = changed_product_files(args[0], args[1] if len(args) > 1 else "HEAD")
        print("PRODUCT_INPUTS_CHANGED=%s" % ("YES" if files else "NO"))
        for f in files:
            print("  PRODUCT_INPUT %s" % f)
        return 0
    if cmd == "current-build" and len(args) <= 1:
        head = git("rev-parse", args[0] if args else "HEAD").strip()
        rec = current_build(head)
        print("PRODUCT_HEAD_QUERY=%s" % head)
        if rec is None:
            print("PRODUCT_BUILD_CURRENT=NO")
            return 0
        print("PRODUCT_BUILD_CURRENT=YES")
        for k in ("SOURCE_HEAD", "MODE", "RUN", "XIMAGE_SHA256",
                  "ROOTFS_SQUASHFS_SHA256", "ATTESTED_AT"):
            print("BUILD_%s=%s" % (k, rec.get(k, rec.get("BUILD_" + k, ""))))
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
