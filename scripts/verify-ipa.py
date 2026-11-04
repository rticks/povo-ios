#!/usr/bin/env python3
"""Validate structure without extracting or executing anything from an IPA."""
import hashlib
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path


def unsigned_arm64(blob):
    assert len(blob) >= 32, "truncated Mach-O"
    magic, cpu, _, _, ncmds, _, _, _ = struct.unpack_from("<8I", blob)
    assert magic == 0xFEEDFACF and cpu == 0x0100000C, "expected thin ARM64 Mach-O"
    offset = 32
    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", blob, offset)
        assert size >= 8 and offset + size <= len(blob), "invalid Mach-O load command"
        assert command != 0x1D, "LC_CODE_SIGNATURE remains"
        offset += size


def main(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        assert all(not name.startswith("/") and ".." not in Path(name).parts for name in names)
        assert not any("_CodeSignature/" in n or n.endswith("embedded.mobileprovision") for n in names)
        app = "Payload/Povo.app/"
        ext = app + "PlugIns/PovoWidgets.appex/"
        info = plistlib.loads(archive.read(app + "Info.plist"))
        widget = plistlib.loads(archive.read(ext + "Info.plist"))
        assert info["CFBundleShortVersionString"] == widget["CFBundleShortVersionString"]
        assert info["CFBundleVersion"] == widget["CFBundleVersion"]
        assert widget["CFBundleIdentifier"].startswith(info["CFBundleIdentifier"] + ".")
        assert widget["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
        unsigned_arm64(archive.read(app + info["CFBundleExecutable"]))
        unsigned_arm64(archive.read(ext + widget["CFBundleExecutable"]))
        for name in names:
            if name.endswith(".dylib"):
                unsigned_arm64(archive.read(name))
        report = {"file": path.name, "bytes": path.stat().st_size,
                  "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                  "bundle_id": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
                  "build": info["CFBundleVersion"], "architecture": "arm64", "signed": False,
                  "widget_extension": widget["CFBundleIdentifier"]}
        print(json.dumps(report, indent=2))
        path.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
