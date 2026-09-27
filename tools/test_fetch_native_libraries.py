import hashlib
import io
from pathlib import Path
import tempfile
from unittest.mock import patch
import zipfile

from fetch_native_libraries import fetch, target_path


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
        try:
            target_path(root, '../outside.dll')
            raise AssertionError('path escape was accepted')
        except ValueError:
            pass
    print('Pinned native fetch, offline verification, checksum failure and path bounds passed')


if __name__ == '__main__':
    main()
