#!/usr/bin/env python3
"""Stage/check only real pinned models needed by a manually selected release."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import tempfile
import time
import urllib.request

REPOSITORY = Path(__file__).resolve().parents[1]
MANIFEST = REPOSITORY / 'Packages/InkribeModelAssets/Sources/InkribeModelAssets/Resources/ModelAssets.json'
SMALL_ID = 'whisper-small-multilingual'
CHUNK_SIZE = 1024 * 1024


def assets():
    manifest = json.loads(MANIFEST.read_text())
    if manifest['schemaVersion'] != 1 or not manifest['assets']:
        raise ValueError('Unsupported or empty model manifest')
    result = manifest['assets']
    seen = set()
    for asset in result:
        path = PurePosixPath(asset['relativePath'])
        if path.is_absolute() or '..' in path.parts or asset['relativePath'] in seen:
            raise ValueError('Invalid/duplicate model path')
        seen.add(asset['relativePath'])
        if asset['byteCount'] <= 0 or len(asset['sha256']) != 64:
            raise ValueError('Invalid model integrity metadata')
        url = asset['downloadURL']
        if not url.startswith('https://huggingface.co/') or '/' + asset['revision'] + '/' not in url:
            raise ValueError('Model URL must use the pinned HTTPS revision')
    return result


def selected(platform, ios_models):
    catalog = assets()
    if platform in ('macOS', 'both'):
        return catalog
    if ios_models == 'bundled':
        matches = [asset for asset in catalog if asset['id'] == SMALL_ID]
        if len(matches) != 1:
            raise ValueError('Small model missing from manifest')
        return matches
    return []


def verify(path, asset):
    if path.is_symlink() or not path.is_file() or path.stat().st_size != asset['byteCount']:
        raise ValueError('Missing/wrong-size model: ' + str(path))
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(CHUNK_SIZE), b''):
            digest.update(block)
    if digest.hexdigest() != asset['sha256']:
        raise ValueError('Model checksum mismatch: ' + str(path))
    print('Verified ' + asset['id'] + ': ' + str(path), flush=True)


def download(path, asset):
    path.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(1, 4):
        descriptor, temporary = tempfile.mkstemp(prefix='.release-', suffix='.partial', dir=path.parent)
        staged = Path(temporary)
        try:
            with os.fdopen(descriptor, 'wb') as output:
                request = urllib.request.Request(asset['downloadURL'], headers={'User-Agent': 'Inkribe-Build-Release'})
                with urllib.request.urlopen(request, timeout=120) as response:
                    if response.status != 200 or not response.url.startswith('https://'):
                        raise ValueError('Expected a successful HTTPS model download')
                    written = 0
                    for block in iter(lambda: response.read(CHUNK_SIZE), b''):
                        written += len(block)
                        if written > asset['byteCount']:
                            raise ValueError('Model download exceeds pinned size')
                        output.write(block)
            verify(staged, asset)
            os.replace(staged, path)
            return
        except Exception:
            if attempt == 3:
                raise
            print('Model download failed; retrying ' + asset['id'], flush=True)
            time.sleep(attempt * 2)
        finally:
            staged.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=['iOS', 'macOS', 'both'])
    parser.add_argument('--ios-models', required=True, choices=['download', 'bundled'])
    parser.add_argument('--root', type=Path, default=REPOSITORY / 'Models')
    parser.add_argument('--download', action='store_true', help='Repair/download missing or invalid real assets')
    options = parser.parse_args()
    required = selected(options.platform, options.ios_models)
    if not required:
        print('Download-enabled iOS: no bundled weights required or downloaded.')
    for asset in required:
        destination = options.root / asset['relativePath']
        try:
            verify(destination, asset)
        except (OSError, ValueError):
            if not options.download:
                raise
            download(destination, asset)
            verify(destination, asset)


if __name__ == '__main__':
    main()
