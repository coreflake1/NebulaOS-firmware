#!/usr/bin/env python3
"""Every installed distribution's hard requirements are installed too.

Usage: check-python-dist-closure.py <site-packages-dir> <target-python-x.y>

Reads each *.dist-info/METADATA under <site-packages-dir> (a copy extracted from
the built image - only the METADATA files are needed) and checks every
Requires-Dist that applies on the target. Requirements behind an `extra` are
optional and are not checked.

Why this exists: Buildroot packages a Python distribution without installing
its declared dependencies, so nothing in the build notices a missing one. The
Buildroot 2025.02.18 image shipped streaming-form-data 1.19.1, which declares
`smart-open>=7.0.5` and imports it at module load, without smart_open. Moonraker
died at import on the printer. The ELF and ABI-tag gates passed, because the
missing piece was a pure-Python module that was simply not there. Importing on
the build host is not possible (the image is MIPS), but the metadata says
exactly what each distribution needs.

Output: one OK/UNMET line per finding, then UNMET_REQUIREMENTS=<n>.
Exit status: 0 when n == 0, 1 otherwise, 2 on a usage or environment error.
"""

import email.parser
import os
import re
import sys


def normalize(name):
    """PEP 503 name normalisation."""
    return re.sub(r"[-_.]+", "-", name).lower()


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    site, pyver = argv[1], argv[2]
    # The build container (build-env/Dockerfile) installs python3-pip but not
    # python3-packaging; pip vendors its own copy, which is the same library.
    try:
        from packaging.requirements import Requirement
    except ImportError:
        try:
            from pip._vendor.packaging.requirements import Requirement
        except ImportError:
            print("UNMET the host python3 has neither 'packaging' nor pip's vendored copy "
                  "- closure gate NOT RUN")
            print("UNMET_REQUIREMENTS=1")
            return 1

    env = {
        "python_version": pyver,
        "python_full_version": pyver + ".0",
        "implementation_name": "cpython",
        "platform_python_implementation": "CPython",
        "sys_platform": "linux",
        "os_name": "posix",
        "platform_system": "Linux",
        "platform_machine": "mips",
        "extra": "",
    }

    installed = {}
    metadata = {}
    for entry in sorted(os.listdir(site)):
        if not entry.endswith(".dist-info"):
            continue
        path = os.path.join(site, entry, "METADATA")
        if not os.path.isfile(path):
            print("UNMET %s has no METADATA" % entry)
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            msg = email.parser.Parser().parse(fh, headersonly=True)
        name = msg.get("Name")
        if not name:
            print("UNMET %s has no Name" % entry)
            continue
        installed[normalize(name)] = msg.get("Version", "")
        metadata[name] = msg.get_all("Requires-Dist") or []

    if not installed:
        print("UNMET no *.dist-info found under %s - closure gate NOT RUN" % site)
        print("UNMET_REQUIREMENTS=1")
        return 1

    unmet = 0
    checked = 0
    for name in sorted(metadata, key=str.lower):
        for raw in metadata[name]:
            try:
                req = Requirement(raw)
            except Exception as exc:            # noqa: BLE001 - reported, not fatal
                print("UNMET %s: unparseable Requires-Dist %r (%s)" % (name, raw, exc))
                unmet += 1
                continue
            if req.marker is not None and not req.marker.evaluate(env):
                continue                        # optional (extra) or not for this target
            checked += 1
            have = installed.get(normalize(req.name))
            if have is None:
                print("UNMET %s requires %s - not installed" % (name, raw))
                unmet += 1
            elif req.specifier and not req.specifier.contains(have, prereleases=True):
                print("UNMET %s requires %s - installed %s" % (name, raw, have))
                unmet += 1
    print("OK   %d distributions, %d applicable requirements checked" % (len(installed), checked))
    print("UNMET_REQUIREMENTS=%d" % unmet)
    return 0 if unmet == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
