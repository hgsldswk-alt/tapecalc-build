import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

SCENES = ("01-paste", "02-edit", "03-review", "04-share", "05-notes")
SHOT = re.compile(r"^(store-(?:en|zh-Hans|zh-Hant)-\d{2}-[a-z]+|paid-01-paywall)(?=$|[. _-])")
PNG_HEADER = b"\x89PNG\r\n\x1a\n"


def named_shots(folder):
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    found = {}
    for case in manifest:
        for attachment in case["attachments"]:
            match = SHOT.match(attachment.get("suggestedHumanReadableName") or "")
            if not match:
                continue
            name = match[1]
            source = folder / attachment["exportedFileName"]
            if source.resolve().parent != folder.resolve():
                raise ValueError(f"Unsafe screenshot path: {source}")
            with source.open("rb") as handle:
                if handle.read(8) != PNG_HEADER:
                    raise ValueError(f"Expected PNG: {name}")
            if name in found:
                raise ValueError(f"Duplicate screenshot: {name}")
            found[name] = source
    return found


def export(folder, output):
    expected = {f"store-{lang}-{scene}" for lang in ("en", "zh-Hans", "zh-Hant") for scene in SCENES}
    expected.add("paid-01-paywall")
    found = named_shots(folder)
    if set(found) != expected:
        raise ValueError(f"Unexpected screenshot inventory: missing={sorted(expected - found.keys())}; extra={sorted(found.keys() - expected)}")
    output.mkdir(parents=True, exist_ok=True)
    for name, source in found.items():
        shutil.copy2(source, output / f"{name}.png")
    print(f"Exported {len(found)} screenshots to {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("result", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--attachments", action="store_true")
    args = parser.parse_args()
    if args.attachments:
        export(args.result, args.output)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=args.output.parent) as folder:
            subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(args.result),
                            "--output-path", folder], check=True)
            export(Path(folder), args.output)
