#!/usr/bin/env python3
"""Regression tests for coverage policy and real Git pre-push invocation."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('coverage_policy', ROOT / 'scripts/check-coverage.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class CoveragePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'Sources/VaultCore/Example.swift'
        self.source.parent.mkdir(parents=True)
        self.source.write_text('// fixture')

    def report(self, covered=100, count=100):
        return {'data': [{'files': [{'filename': str(self.source), 'summary': {
            'lines': {'covered': covered, 'count': count}}}]}]}

    def test_exact_threshold_and_below_without_rounding(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertTrue(policy.check(self.report(), self.root))
            self.assertTrue(policy.check(self.report(100), self.root))
            self.assertFalse(policy.check(self.report(94), self.root))
            self.assertFalse(policy.check(self.report(99), self.root))
            self.assertFalse(policy.check(self.report(99999, 100000), self.root))

    def test_missing_sources_are_not_silently_excluded(self):
        (self.source.parent / 'Untested.swift').touch()
        with self.assertRaisesRegex(ValueError, 'Missing coverage'):
            policy.check(self.report(), self.root)

    def test_empty_invalid_and_duplicate_reports_fail(self):
        for covered, total in [(0, 0), (101, 100), (-1, 100), (95.0, 100)]:
            with self.subTest(covered=covered, total=total), self.assertRaises(ValueError):
                policy.check(self.report(covered, total), self.root)
        report = self.report()
        report['data'] *= 2
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            policy.check(report, self.root)

    def test_tests_and_other_targets_do_not_inflate_coverage(self):
        report = self.report(94)
        other = json.loads(json.dumps(report['data'][0]['files'][0]))
        other['filename'] = str(self.root / 'Tests/Test.swift')
        other['summary']['lines'] = {'covered': 10000, 'count': 10000}
        report['data'][0]['files'].append(other)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(policy.check(report, self.root))


class PrePushTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith('GIT_'):
                del self.env[key]
        self.env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
        self.run_git('init', '-q', '-b', 'main')
        self.run_git('config', 'user.name', 'Coverage Test')
        self.run_git('config', 'user.email', 'test@example.invalid')
        subprocess.run(['git', 'init', '-q', '--bare', str(self.root / 'origin.git')], check=True, env=self.env)
        self.run_git('remote', 'add', 'origin', str(self.root / 'origin.git'))
        self.run_git('remote', 'add', 'other', str(self.root / 'origin.git'))
        shutil.copytree(ROOT / '.githooks', self.repo / '.githooks')
        (self.repo / 'scripts').mkdir()
        for name in ['check-coverage.sh', 'check-coverage.py', 'install-hooks.sh']:
            shutil.copy2(ROOT / 'scripts' / name, self.repo / 'scripts' / name)
        source = self.repo / 'Sources/VaultCore/Example.swift'
        source.parent.mkdir(parents=True)
        source.write_text('committed')
        self.run_git('add', '.')
        self.run_git('commit', '-qm', 'fixture')
        subprocess.run(['bash', 'scripts/install-hooks.sh'], cwd=self.repo, env=self.env, check=True, capture_output=True)
        binary = self.root / 'bin'
        binary.mkdir()
        swift = binary / 'swift'
        swift.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path.cwd()
assert (root / 'Sources/VaultCore/Example.swift').read_text() == 'committed'
if '--show-codecov-path' in sys.argv:
    print(root / 'coverage.json')
else:
    if os.environ.get('FAIL_TESTS'): sys.exit(1)
    source = root / 'Sources/VaultCore/Example.swift'
    report = {'data': [{'files': [{'filename': str(source), 'summary': {'lines': {
        'covered': int(os.environ.get('COVERED', '100')), 'count': 100}}}]}]}
    (root / 'coverage.json').write_text(json.dumps(report))
''')
        swift.chmod(0o755)
        self.env['PATH'] = str(binary) + os.pathsep + self.env['PATH']
        # A passing working file must not replace the committed content under test.
        source.write_text('uncommitted')

    def run_git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, env=self.env, check=True, capture_output=True, text=True)

    def test_push_enforces_threshold_on_committed_snapshot(self):
        self.env['COVERED'] = '94'
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_git('push', 'origin', 'main')
        self.env['COVERED'] = '100'
        result = self.run_git('push', 'origin', 'main')
        self.assertIn('100.00%', result.stdout + result.stderr)
        self.assertEqual((self.repo / 'Sources/VaultCore/Example.swift').read_text(), 'uncommitted')

    def test_failed_tests_block_origin(self):
        self.env['FAIL_TESTS'] = '1'
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_git('push', 'origin', 'main')

    def test_full_xcode_without_extra_flags(self):
        selector = self.root / 'bin/xcode-select'
        selector.write_text('#!/bin/sh\necho /Applications/Xcode.app/Contents/Developer\n')
        selector.chmod(0o755)
        self.run_git('push', 'origin', 'main')

    def test_installer_preserves_existing_hooks(self):
        self.run_git('config', '--unset', 'core.hooksPath')
        hook = self.repo / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        result = subprocess.run(['bash', 'scripts/install-hooks.sh'], cwd=self.repo,
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Existing active hook', result.stderr)
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_git('config', '--get', 'core.hooksPath')
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_git('commit', '--allow-empty', '-qm', 'must stay blocked')

    def test_other_remote_skips_gate(self):
        self.env['FAIL_TESTS'] = '1'
        self.run_git('push', 'other', 'main')


if __name__ == '__main__':
    unittest.main()
