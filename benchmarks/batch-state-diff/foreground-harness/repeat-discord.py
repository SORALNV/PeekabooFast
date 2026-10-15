#!/usr/bin/env python3
"""Counterbalanced live sends. Retain every attempt; never retry only failed trials."""
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import sys
import time
import uuid
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['before', 'after', 'pid', 'window', 'server', 'recipient', 'dm-label', 'output']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    run_tag = uuid.uuid4().hex[:8]
    # ABBA blocks reduce a simple monotonic order bias; five trials per version.
    order = ['before', 'after', 'after', 'before', 'before', 'after', 'after', 'before', 'before', 'after']
    manifest = {
        'run_tag': run_tag,
        'host': {'architecture': platform.machine(), 'macos_version': platform.mac_ver()[0]},
        'harness_sha256': {
            name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
            for name in ['discord.py', 'transport.py', 'repeat-discord.py']
        },
        'plan': '12 driver steps, focus before navigation; five explicit verifications',
        'order': order,
        'trials_per_version': 5,
        'warmup_sends': 0,
        'pid': int(args.pid),
        'window': int(args.window),
        'server': args.server,
        'recipient': args.recipient,
        'startup_and_server_preparation_excluded': True,
        'llm_included': False,
        'binaries': {
            version: {
                'path': str(Path(getattr(args, version)).resolve()),
                'sha256': hashlib.sha256(Path(getattr(args, version)).read_bytes()).hexdigest(),
            } for version in ['before', 'after']
        },
    }
    (output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    records = []
    for index, version in enumerate(order, 1):
        result_path = output / f'{index:02}-{version}.json'
        command = [
            sys.executable, str(Path(__file__).with_name('discord.py')), getattr(args, version),
            'sequential' if version == 'before' else 'batch', str(result_path),
            '--pid', args.pid, '--window', args.window, '--server', args.server,
            '--recipient', args.recipient, '--dm-label', args.dm_label,
            '--text', f'Peekaboo {run_tag} {"A" if version == "before" else "B"}{index:02}',
        ]
        trial_started = time.time()
        run = subprocess.run(command, capture_output=True, text=True)
        trial_finished = time.time()
        record = json.loads(result_path.read_text()) if result_path.exists() else {
            'success': False, 'error': 'Harness exited before writing result',
        }
        if run.returncode and record.get('success'):
            record.update(success=False, sent_verified=True, phase='cleanup',
                          error='Harness failed after the verified send')
        record.update(trial=index, version=version, exit_code=run.returncode,
                      trial_started_at_unix_seconds=trial_started,
                      trial_finished_at_unix_seconds=trial_finished)
        result_path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
        records.append(record)
        print(json.dumps({key: record.get(key) for key in [
            'trial', 'version', 'success', 'elapsed_ms', 'error',
        ]}, ensure_ascii=False), flush=True)
    summary = {}
    for version in ['before', 'after']:
        group = [record for record in records if record['version'] == version]
        successful = [record['elapsed_ms'] for record in group if record.get('success')]
        summary[version] = {
            'successes': len(successful), 'attempts': len(group),
            'success_rate': len(successful) / len(group),
            'successful_elapsed_ms': successful,
            'median_ms': statistics.median(successful) if successful else None,
            'min_ms': min(successful) if successful else None,
            'max_ms': max(successful) if successful else None,
        }
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
