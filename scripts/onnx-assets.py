#!/usr/bin/env python3
"""Download and verify pinned ONNX resources on a build machine only."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
import time
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts" / "onnx-assets.json"
DEFAULT_ROOT = ROOT / "Resources" / "ONNX"


def assets():
    spec = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if spec.get("schema_version") != 1 or len(spec.get("resources", [])) != 6:
        raise RuntimeError("Unexpected ONNX asset manifest")
    found = set()
    for item in spec["resources"]:
        relative = item["path"]
        path = PurePosixPath(relative)
        if path.is_absolute() or ".." in path.parts or len(path.parts) != 2:
            raise RuntimeError(f"Unsafe ONNX asset path: {relative}")
        if relative in found:
            raise RuntimeError(f"Duplicate ONNX asset: {relative}")
        found.add(relative)
        if not item["url"].startswith("https://huggingface.co/"):
            raise RuntimeError("Unexpected ONNX asset source")
    return spec["resources"]


def path_for(root, relative):
    destination = root.joinpath(*PurePosixPath(relative).parts)
    parent = root
    if root.is_symlink():
        raise RuntimeError("ONNX resource root must not be a symlink")
    for part in PurePosixPath(relative).parts:
        parent = parent / part
        if parent.is_symlink():
            raise RuntimeError(f"Symlink not allowed in ONNX bundle: {relative}")
    return destination


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                return digest.hexdigest()
            digest.update(chunk)


def valid_file(file, asset):
    if not file.is_file() or file.is_symlink():
        return False
    size = file.stat().st_size
    if "size" in asset and size != asset["size"]:
        return False
    if size < asset.get("min_bytes", 1):
        return False
    if "sha256" in asset and sha256(file) != asset["sha256"]:
        return False
    return True


def verify(root):
    for item in assets():
        file = path_for(root, item["path"])
        if not valid_file(file, item):
            raise RuntimeError(f"Missing, truncated or invalid bundled ONNX resource: {item['path']}")
    data = json.loads((root / "ONNXG2P" / "misaki-en_us-g2p.json").read_text(encoding="utf-8"))
    for key in ("graphemes", "phonemes", "gold", "silver", "kokoro_vocab",
                "start_id", "bos_id", "eos_id", "unknown_id", "max_steps"):
        if key not in data:
            raise RuntimeError(f"Missing G2P metadata: {key}")
    if not isinstance(data["kokoro_vocab"], dict) or " " not in data["kokoro_vocab"]:
        raise RuntimeError("G2P Kokoro token vocabulary is invalid")
    print(f"Verified all {len(assets())} bundled ONNX resources at {root}")


def download(root):
    for item in assets():
        destination = path_for(root, item["path"])
        if valid_file(destination, item):
            print(f"Reusing verified {item['path']}", flush=True)
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        last_error = None
        for attempt in range(1, 4):
            temporary = None
            try:
                fd, name = tempfile.mkstemp(prefix=".download-", dir=destination.parent)
                temporary = Path(name)
                with os.fdopen(fd, "wb") as output:
                    request = Request(item["url"], headers={"User-Agent": "ReadAloud-build/1.0"})
                    with urlopen(request, timeout=120) as response:
                        shutil.copyfileobj(response, output, length=1024 * 1024)
                if not valid_file(temporary, item):
                    raise RuntimeError(f"Asset integrity check failed: {item['path']}")
                os.replace(temporary, destination)
                temporary = None
                print(f"Downloaded and verified {item['path']}", flush=True)
                last_error = None
                break
            except Exception as exc:
                last_error = exc
                print(f"Download attempt {attempt}/3 failed for {item['path']}: {exc}",
                      file=sys.stderr, flush=True)
                if attempt < 3:
                    time.sleep(attempt * 2)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
        if last_error is not None:
            raise RuntimeError(f"Cannot bundle {item['path']}: {last_error}")
    verify(root)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["download", "verify"])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    args = parser.parse_args()
    root = args.root.resolve()
    if args.command == "download":
        download(root)
    else:
        verify(root)


if __name__ == "__main__":
    main()
