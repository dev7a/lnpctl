"""Verify release tags against an isolated set of approved public keys."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'tools/release/verify-tag.sh'


class TagTests(unittest.TestCase):
    def test_only_approved_signed_annotated_tags_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / 'gpg'
            home.mkdir(mode=0o700)
            env = dict(os.environ, GNUPGHOME=str(home), GIT_CONFIG_NOSYSTEM='1',
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_AUTHOR_NAME='Test',
                       GIT_AUTHOR_EMAIL='test@example.invalid', GIT_COMMITTER_NAME='Test',
                       GIT_COMMITTER_EMAIL='test@example.invalid')

            def run(*args):
                return subprocess.check_output(args, cwd=root, env=env, stderr=subprocess.DEVNULL)

            run('git', 'init', '-q')
            run('git', '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'fixture')
            for user in ('Approved <approved@example.invalid>', 'Other <other@example.invalid>'):
                run('gpg', '--batch', '--pinentry-mode', 'loopback', '--passphrase', '',
                    '--quick-generate-key', user, 'ed25519', 'sign', '1d')
            keys = root / 'approved.asc'
            keys.write_bytes(run('gpg', '--armor', '--export', 'approved@example.invalid'))
            run('git', '-c', 'user.signingkey=approved@example.invalid', 'tag', '-s', 'v1.0.0', '-m', 'approved')
            run('git', '-c', 'user.signingkey=other@example.invalid', 'tag', '-s', 'v1.0.1', '-m', 'unapproved')
            run('git', 'tag', '-a', 'v1.0.2', '-m', 'unsigned')
            run('git', 'tag', 'v1.0.3')
            try:
                for tag, accepted in [('v1.0.0', True), ('v1.0.1', False), ('v1.0.2', False), ('v1.0.3', False)]:
                    with self.subTest(tag=tag):
                        result = subprocess.run(['bash', str(SCRIPT), tag, str(keys)], cwd=root,
                                                env=env, capture_output=True, text=True)
                        self.assertEqual(result.returncode == 0, accepted, result.stderr)
            finally:
                run('gpgconf', '--kill', 'gpg-agent')


if __name__ == '__main__':
    unittest.main()
