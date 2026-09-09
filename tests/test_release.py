"""Exercise publication failure boundaries without GitHub or signing credentials."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'tools/release/publish.sh'
FAKE_GH = '''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open('calls.jsonl', 'a') as f: f.write(json.dumps(args) + '\\n')
case = os.environ['CASE']
if args[0] == 'api':
    if '--paginate' in args:
        if case == 'api_error': sys.exit(1)
        if case in ('published', 'draft', 'wrong_draft'):
            print('1\\t' + ('false' if case == 'published' else 'true') + '\\t' + ('b' * 40 if case == 'wrong_draft' else 'a' * 40))
    elif '/git/ref/tags/' in args[1]: print('d' * 40 if case == 'replaced_tag_object' else 'c' * 40)
    else: print('b' * 40 if case == 'moved_tag' else 'a' * 40)
elif args[:2] == ['release', 'upload'] and case == 'upload_error': sys.exit(1)
elif args[:2] == ['release', 'view']:
    assets = [{'name': p.name, 'size': p.stat().st_size} for p in pathlib.Path('release-assets').iterdir()]
    if case == 'extra_asset': assets.append({'name': 'unexpected', 'size': 0})
    print(json.dumps({'assets': assets}))
'''


class ReleaseTests(unittest.TestCase):
    def run_case(self, case, success):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'gh').write_text(FAKE_GH)
            (root / 'gh').chmod(0o755)
            assets = root / 'release-assets'
            assets.mkdir()
            name = 'lnpctl-0.1.3-macos-arm64.dmg'
            (assets / name).write_bytes(b'fixture')
            (assets / 'SHA256SUMS').write_text(hashlib.sha256(b'fixture').hexdigest() + '  ' + name + '\n')
            (assets / 'release.json').write_text(json.dumps({
                'tag': 'v0.1.3', 'commit': 'a' * 40, 'tag_object': 'c' * 40,
                'notarization': {'status': 'Invalid' if case == 'rejected' else 'Accepted'},
            }))
            if case == 'bad_hash': (assets / name).write_bytes(b'changed')
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       GH_TOKEN='test', GH_REPO='test/test', RELEASE_TAG='v0.1.3',
                       RELEASE_SHA='a' * 40, RELEASE_TAG_OBJECT='c' * 40, RUNNER_TEMP=directory, CASE=case)
            result = subprocess.run(['bash', str(SCRIPT)], cwd=root, env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()] if (root / 'calls.jsonl').exists() else []
            published = any(c[:2] == ['release', 'edit'] for c in calls)
            self.assertEqual(result.returncode == 0, success, result.stderr + str(calls))
            self.assertEqual(published, success)
            if case in ('published', 'wrong_draft', 'moved_tag', 'replaced_tag_object', 'api_error', 'rejected', 'bad_hash'):
                self.assertFalse(any(c[:2] == ['release', 'upload'] for c in calls))

    def test_new_release(self): self.run_case('new', True)
    def test_resume_draft(self): self.run_case('draft', True)
    def test_failures_never_publish(self):
        for case in ('published', 'wrong_draft', 'moved_tag', 'replaced_tag_object', 'api_error', 'rejected', 'bad_hash', 'upload_error', 'extra_asset'):
            with self.subTest(case=case): self.run_case(case, False)


if __name__ == '__main__':
    unittest.main()
