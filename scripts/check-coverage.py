#!/usr/bin/env python3
"""Enforce 100% aggregate line coverage for every VaultCore source file."""
import json
from pathlib import Path
import sys


def check(report, root):
    source = (root / 'Sources' / 'VaultCore').resolve()
    expected = {p.resolve() for p in source.rglob('*.swift')}
    if not expected:
        raise ValueError('No VaultCore sources found')
    summaries = {}
    for unit in report['data']:
        for entry in unit['files']:
            path = Path(entry['filename']).resolve()
            if path not in expected:
                continue
            if path in summaries:
                raise ValueError(f'Duplicate coverage for {path.name}')
            lines = entry['summary']['lines']
            count, covered = lines['count'], lines['covered']
            if type(count) is not int or type(covered) is not int or not 0 <= covered <= count:
                raise ValueError(f'Invalid line counts for {path.name}')
            summaries[path] = (count, covered)
    missing = expected - summaries.keys()
    if missing:
        raise ValueError('Missing coverage: ' + ', '.join(sorted(p.name for p in missing)))
    total = sum(x[0] for x in summaries.values())
    covered = sum(x[1] for x in summaries.values())
    if total == 0:
        raise ValueError('Coverage report has no executable lines')
    # Compare integers: 99.999% must never round up to a pass.
    passed = covered * 100 >= total * 100
    print(f'VaultCore line coverage: {covered}/{total} ({covered / total:.2%}); required: 100%.')
    if not passed:
        print('Push blocked: add tests to reach 100% coverage.', file=sys.stderr)
    return passed


def main():
    try:
        report = json.loads(Path(sys.argv[1]).read_text())
        root = Path(sys.argv[2])
        return 0 if check(report, root) else 1
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        print(f'Coverage check failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
