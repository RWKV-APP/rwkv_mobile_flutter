"""Fetch or verify the exact native release in native-libraries.json (Python 3)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from urllib.parse import quote
from urllib.request import Request, urlopen
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def target_path(root, relative):
    path = (root / relative).resolve()
    if not relative or Path(relative).is_absolute() or not path.is_relative_to(root.resolve()) or path == root.resolve():
        raise ValueError(f'Invalid native artifact path: {relative}')
    return path


def matches(path, info):
    return path.is_file() and path.stat().st_size == info['size'] and sha256(path) == info['sha256']


def fetch(root, manifest, platforms, verify_only=False):
    for platform in platforms:
        asset = manifest['platforms'][platform]
        source = {key: manifest[key] for key in ('repository', 'tag', 'commit')}
        source.update(asset.get('source', {}))
        if not re.fullmatch(r'[\w.-]+/[\w.-]+', source['repository']):
            raise ValueError('Invalid native repository')
        if not re.fullmatch(r'[0-9a-f]{40}', source['commit']):
            raise ValueError('A full native commit is required')
        if source['tag'] in ('latest', 'master', 'main') or not source['tag']:
            raise ValueError('A fixed native release tag is required')
        files = asset['files']
        if not files or not re.fullmatch(r'[0-9a-f]{64}', asset['sha256']):
            raise ValueError(f'Incomplete native manifest: {platform}')
        destinations = {member: target_path(root, info['path']) for member, info in files.items()}
        if all(matches(destinations[member], info) for member, info in files.items()):
            print(f'{platform}: native files verified at {source["commit"]}')
            continue
        if verify_only:
            raise ValueError(f'{platform}: native files differ from the pinned release; run the fetch script')
        url = f'https://github.com/{source["repository"]}/releases/download/{quote(source["tag"], safe="")}/{quote(asset["archive"], safe="")}'
        with tempfile.TemporaryDirectory(prefix='rwkv-native-') as temporary:
            archive_path = Path(temporary) / 'native.zip'
            print(f'{platform}: downloading {asset["archive"]}', flush=True)
            with urlopen(Request(url, headers={'User-Agent': 'rwkv-mobile-flutter'}), timeout=120) as response, archive_path.open('wb') as output:
                shutil.copyfileobj(response, output)
            if sha256(archive_path) != asset['sha256']:
                raise ValueError(f'{platform}: native archive checksum mismatch')
            staged = {}
            with zipfile.ZipFile(archive_path) as archive:
                for index, (member, info) in enumerate(files.items()):
                    if archive.getinfo(member).file_size != info['size']:
                        raise ValueError(f'{platform}: native member size mismatch: {member}')
                    stage = Path(temporary) / str(index)
                    with archive.open(member) as source, stage.open('wb') as output:
                        shutil.copyfileobj(source, output)
                    if not matches(stage, info):
                        raise ValueError(f'{platform}: native member checksum mismatch: {member}')
                    staged[member] = stage
            # Verify every member before replacing any installed file.
            for member, stage in staged.items():
                destination = destinations[member]
                destination.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
                    pending = Path(output.name)
                    with stage.open('rb') as source:
                        shutil.copyfileobj(source, output)
                try:
                    os.replace(pending, destination)
                finally:
                    pending.unlink(missing_ok=True)
            print(f'{platform}: installed and verified native files')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', action='append', help='Repeat for each platform; defaults to all manifest platforms')
    parser.add_argument('--verify-only', action='store_true', help='Check vendored files without network access')
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'native-libraries.json').read_text(encoding='utf-8'))
    fetch(ROOT, manifest, args.platform or list(manifest['platforms']), args.verify_only)


if __name__ == '__main__':
    main()
