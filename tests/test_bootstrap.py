"""Exercise actual Bash installer functions with temporary repos and no network."""
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)

    def checkout(self, relative, remote='https://github.com/Doist/doist-os.git'):
        target = self.home / relative
        subprocess.run(['git', 'init', '-q', '-b', 'main', str(target)], check=True)
        subprocess.run(['git', '-C', str(target), 'remote', 'add', 'origin', remote], check=True)
        return target

    def run_installer(self, name, **overrides):
        source = (ROOT / 'install' / name).read_text()
        self.assertTrue(source.endswith('main "$@"\n'))
        source = source.removesuffix('main "$@"\n')
        env = {**os.environ, 'HOME': str(self.home), 'TMPDIR': str(self.home), 'TRACE': str(self.home / 'trace')}
        for key in ['TODOIST_OS_DIR', 'DOIST_OS_DIR']:
            env.pop(key, None)
        env.update(overrides)
        (self.home / 'trace').unlink(missing_ok=True)
        # Keep selection and validation real. Record pull/clone instead of running them.
        source += '\nrun_quiet() { printf "%s\\n" "$@" > "$TRACE"; }\nclone_repo\nprintf "TARGET=%s\\n" "$TARGET_DIR"\n'
        result = subprocess.run(['bash', '-c', source], env=env, text=True, capture_output=True)
        trace = (self.home / 'trace').read_text() if (self.home / 'trace').exists() else ''
        return result, trace

    def each(self):
        return ['bootstrap-mac.sh', 'bootstrap-linux.sh']

    def test_fresh_install_targets_new_repository_and_folder(self):
        for name in self.each():
            with self.subTest(name=name):
                result, trace = self.run_installer(name)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('gh\nrepo\nclone\nDoist/todoist-os\n', trace)
                self.assertIn(f'TARGET={self.home / "todoist-os"}', result.stdout)

    def test_existing_locations_are_reused(self):
        for relative in ['doist-os', 'todoist-os', 'Documents/doist-os', 'Documents/todoist-os']:
            target = self.checkout(relative)
            for name in self.each():
                with self.subTest(name=name, relative=relative):
                    result, trace = self.run_installer(name)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn(f'git\n-C\n{target}\npull\n--rebase\norigin\nmain\n', trace)
                    self.assertNotIn('\nclone\n', trace)
            shutil.rmtree(target)

    def test_new_upstream_and_ssh_transports_are_accepted(self):
        target = self.checkout('todoist-os')
        for remote in ['https://github.com/doist/todoist-os.git', 'git@github.com:Doist/todoist-os.git', 'ssh://git@github.com/Doist/doist-os.git']:
            subprocess.run(['git', '-C', str(target), 'remote', 'set-url', 'origin', remote], check=True)
            for name in self.each():
                with self.subTest(name=name, remote=remote):
                    result, trace = self.run_installer(name)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('pull\n--rebase\norigin\nmain', trace)

    def test_custom_path_and_environment_precedence(self):
        for name in self.each():
            for overrides, expected in [
                ({'DOIST_OS_DIR': str(self.home / 'legacy custom')}, 'legacy custom'),
                ({'DOIST_OS_DIR': str(self.home / 'legacy custom'), 'TODOIST_OS_DIR': str(self.home / 'new custom')}, 'new custom'),
            ]:
                with self.subTest(name=name, overrides=overrides):
                    result, trace = self.run_installer(name, **overrides)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn(f'TARGET={self.home / expected}', result.stdout)

    def test_ambiguous_checkouts_require_explicit_selection(self):
        self.checkout('doist-os')
        selected = self.checkout('todoist-os')
        for name in self.each():
            result, trace = self.run_installer(name)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Multiple workspace checkouts', result.stdout)
            self.assertEqual(trace, '')
            result, trace = self.run_installer(name, TODOIST_OS_DIR=str(selected))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unrelated_repo_is_not_pulled_or_executed(self):
        self.checkout('doist-os', 'https://github.com/someone/other.git')
        for name in self.each():
            result, trace = self.run_installer(name)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('not the TodoistOS upstream', result.stdout)
            self.assertEqual(trace, '')

    def test_dirty_checkout_is_not_pulled(self):
        target = self.checkout('doist-os')
        (target / 'personal.txt').write_text('keep')
        for name in self.each():
            result, trace = self.run_installer(name)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Commit or stash', result.stdout)
            self.assertEqual(trace, '')
            self.assertEqual((target / 'personal.txt').read_text(), 'keep')

    def test_existing_non_repo_target_is_not_overwritten(self):
        (self.home / 'todoist-os').mkdir()
        for name in self.each():
            result, trace = self.run_installer(name)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('not a git repo', result.stdout)
            self.assertEqual(trace, '')

    def test_feature_branch_is_not_rebased(self):
        target = self.checkout('doist-os')
        subprocess.run(['git', '-C', str(target), 'symbolic-ref', 'HEAD', 'refs/heads/work'], check=True)
        for name in self.each():
            result, trace = self.run_installer(name)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Switch the target checkout to main', result.stdout)
            self.assertEqual(trace, '')

if __name__ == '__main__':
    unittest.main()
