import hashlib
import io
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
import zipfile

from fetch_native_libraries import fetch, read_manifest, target_path


def main():
    payload = b'checked native library'
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, 'w') as output:
        output.writestr('Release/runtime.dll', payload)
    archive_bytes = archive.getvalue()
    info = {'path': 'windows/runtime.dll', 'size': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}
    manifest = {'repository': 'RWKV-APP/rwkv-mobile', 'tag': 'v4.8.0-native.1', 'commit': 'a' * 40,
                'platforms': {'windows-x64': {'archive': 'native.zip', 'sha256': hashlib.sha256(archive_bytes).hexdigest(),
                                            'files': {'Release/runtime.dll': info}}}}
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        with patch('fetch_native_libraries.urlopen', return_value=io.BytesIO(archive_bytes)):
            fetch(root, manifest, ['windows-x64'])
        with patch('fetch_native_libraries.urlopen', side_effect=AssertionError('verification must not use the network')):
            fetch(root, manifest, ['windows-x64'], verify_only=True)
        destination = root / info['path']
        manifest['platforms']['windows-x64']['source'] = {
            'repository': 'RWKV-APP/rwkv_mobile_flutter', 'tag': '4.8.2-android-16kb', 'commit': 'b' * 40}
        destination.write_bytes(b'old')
        with patch('fetch_native_libraries.urlopen', return_value=io.BytesIO(archive_bytes)) as request:
            fetch(root, manifest, ['windows-x64'])
            assert request.call_args.args[0].full_url == (
                'https://github.com/RWKV-APP/rwkv_mobile_flutter/releases/download/4.8.2-android-16kb/native.zip')
        destination.write_bytes(b'old')
        with patch('fetch_native_libraries.urlopen', return_value=io.BytesIO(b'corrupt archive')):
            try:
                fetch(root, manifest, ['windows-x64'])
                raise AssertionError('corrupt archive was accepted')
            except ValueError as error:
                assert 'checksum' in str(error)
        assert destination.read_bytes() == b'old'
        (root / 'native-libraries.json').write_text(json.dumps(manifest), encoding='utf-8')
        (root / 'local.zip').write_bytes(archive_bytes)
        local_asset = {'archive': 'local.zip', 'localArchive': 'local.zip',
                       'sha256': hashlib.sha256(archive_bytes).hexdigest(),
                       'source': {'baseCommit': 'c' * 40, 'snapshotSha256': 'd' * 64},
                       'files': {'Release/runtime.dll': info}}
        local = {'platforms': {'windows-x64': local_asset}}
        (root / 'native-libraries.local.json').write_text(json.dumps(local), encoding='utf-8')
        with patch('fetch_native_libraries.urlopen', side_effect=AssertionError('local builds must stay offline')):
            fetch(root, read_manifest(root), ['windows-x64'])
            fetch(root, read_manifest(root), ['windows-x64'], verify_only=True)
            destination.write_bytes(b'old')
            (root / 'local.zip').write_bytes(b'corrupt archive')
            try:
                fetch(root, read_manifest(root), ['windows-x64'])
                raise AssertionError('corrupt local archive was accepted')
            except ValueError as error:
                assert 'checksum' in str(error)
        assert destination.read_bytes() == b'old'
        local_asset['files'] = {'Release/runtime.dll': {**info, 'path': 'outside-layout.dll'}}
        (root / 'native-libraries.local.json').write_text(json.dumps(local), encoding='utf-8')
        try:
            read_manifest(root)
            raise AssertionError('local destination override was accepted')
        except ValueError as error:
            assert 'layout' in str(error)
        extra = {**info, 'path': 'windows/cublas64_13.dll'}
        local_asset['files'] = {'Release/runtime.dll': info, 'Release/cublas64_13.dll': extra}
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('Release/runtime.dll', payload)
            output.writestr('Release/cublas64_13.dll', payload)
        (root / 'local.zip').write_bytes(archive.getvalue())
        local_asset['sha256'] = hashlib.sha256(archive.getvalue()).hexdigest()
        (root / 'native-libraries.local.json').write_text(json.dumps(local), encoding='utf-8')
        with patch('fetch_native_libraries.urlopen', side_effect=AssertionError('local runtime restore must stay offline')):
            fetch(root, read_manifest(root), ['windows-x64'])
            fetch(root, read_manifest(root), ['windows-x64'], verify_only=True)
        bundle = root / 'windows/native-runtime-libraries.txt'
        assert bundle.read_text() == 'cublas64_13.dll\nruntime.dll\n'
        (root / 'native-libraries.local.json').unlink()
        fetch(root, read_manifest(root), ['windows-x64'])
        assert bundle.read_text() == 'runtime.dll\n'
        assert (root / extra['path']).exists(), 'Restoring the release must not delete retained runtime files'
        try:
            target_path(root, '../outside.dll')
            raise AssertionError('path escape was accepted')
        except ValueError:
            pass
    print('Pinned native fetch, offline verification, checksum failure and path bounds passed')


if __name__ == '__main__':
    main()
