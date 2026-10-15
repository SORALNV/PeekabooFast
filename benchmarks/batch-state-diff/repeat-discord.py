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


def summarize_monitor(samples, target_pid, expected_target_state="onscreen"):
    """A send and preserved workspace are separate acceptance conditions, including preparation."""
    visible_inventory = bool(samples) and all(sample.get('monitor_schema') in [2, 3] for sample in samples)
    order_keys = (['visible_non_target_order_sha256', 'visible_non_target_windows_above']
                  if visible_inventory else ['non_target_order_sha256', 'non_target_windows_above'])
    keys = ['front_pid', 'ax_front_pid', 'pointer_x', 'pointer_y', 'target_onscreen',
            'target_present', 'space_change_count',
            'receiver_hash', 'receiver_window_id', 'receiver_pid'] + order_keys
    state_keys = ['target_hidden', 'target_space_ids', 'active_space_ids', 'target_on_active_space',
                  'session_locked', 'visible_non_target_geometry_sha256', 'target_x', 'target_y',
                  'target_width', 'target_height'] if expected_target_state != 'onscreen' else []
    keys += state_keys
    def target_condition(sample):
        if expected_target_state == 'onscreen':
            return sample.get('target_onscreen') is True
        common = (sample.get('monitor_schema') == 3 and sample.get('target_onscreen') is False
                  and sample.get('session_locked') is False and bool(sample.get('target_space_ids'))
                  and bool(sample.get('active_space_ids')))
        if expected_target_state == 'hidden':
            return common and sample.get('target_hidden') is True
        if expected_target_state == 'offspace':
            return (common and sample.get('target_hidden') is False
                    and sample.get('target_on_active_space') is False)
        return False
    changed = [key for key in keys if len({sample.get(key) for sample in samples}) != 1]
    sufficient = len(samples) >= 2 and all(all(key in sample and sample[key] is not None for key in keys)
                                         and sample.get('space_change_count') == 0
                                         and sample.get('receiver_window_id', 0) > 0
                                         and sample.get('receiver_pid') == sample.get('front_pid')
                                         and sample.get('target_present') and target_condition(sample)
                                         and sample.get('front_pid') not in [0, target_pid]
                                         and sample.get('ax_front_pid') == sample.get('front_pid')
                                         for sample in samples)
    return {'samples': len(samples), 'preserved': sufficient and not changed, 'changed_fields': changed,
            'target_remained_background': bool(samples) and all(sample.get('front_pid') != target_pid for sample in samples),
            'includes_preparation': True, 'expected_target_state': expected_target_state,
            'window_order_scope': 'onscreen windows; all-window churn retained for diagnosis' if visible_inventory else 'all windows (legacy monitor)',
            'sampling_limit': 'Transient changes between samples may be missed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['before', 'after', 'pid', 'window', 'server', 'recipient', 'dm-label', 'output']:
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--before-mode', choices=['sequential', 'batch'], default='sequential')
    parser.add_argument('--target-state', choices=['onscreen', 'hidden', 'offspace'], default='onscreen')
    parser.add_argument('--background-only', action='store_true')
    parser.add_argument('--monitor', help='Compiled focus-monitor.swift; observes preparation and timed work')
    parser.add_argument('--require-preserved-workspace', action='store_true')
    args = parser.parse_args()
    if args.require_preserved_workspace and not args.monitor:
        parser.error('--require-preserved-workspace requires --monitor')
    if args.monitor and not Path(args.monitor).is_file():
        parser.error('Monitor binary is missing')
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
        'plan': '11 background driver steps, five explicit verifications' if args.background_only else '12 driver steps, focus before navigation; five explicit verifications',
        'background_only': args.background_only,
        'expected_target_state': args.target_state,
        'modes': {'before': args.before_mode, 'after': 'batch'},
        'require_preserved_workspace': args.require_preserved_workspace,
        'monitor_sha256': hashlib.sha256(Path(args.monitor).read_bytes()).hexdigest() if args.monitor else None,
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
            args.before_mode if version == 'before' else 'batch', str(result_path),
            '--pid', args.pid, '--window', args.window, '--server', args.server,
            '--recipient', args.recipient, '--dm-label', args.dm_label,
            '--text', f'Peekaboo {run_tag} {"A" if version == "before" else "B"}{index:02}',
        ]
        if args.background_only:
            command.append('--background-only')
        trial_started = time.time()
        monitor = None
        monitor_path = output / f'{index:02}-{version}-monitor.jsonl'
        monitor_file = None
        if args.monitor:
            monitor_file = monitor_path.open('w')
            monitor = subprocess.Popen([args.monitor, args.pid, args.window, '3000'], stdout=monitor_file)
        try:
            preflight = None
            if monitor and args.target_state != 'onscreen':
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    try:
                        samples = [json.loads(line) for line in monitor_path.read_text().splitlines() if line.strip()]
                    except json.JSONDecodeError:
                        samples = []
                    if len(samples) >= 2:
                        preflight = summarize_monitor(samples, int(args.pid), args.target_state)
                        break
                    time.sleep(0.05)
                if not preflight or not preflight['preserved']:
                    result_path.write_text(json.dumps({
                        'success': False, 'phase': 'precondition', 'mutation_dispatched': False,
                        'error': 'Target condition or stable workspace was not established before input',
                        'workspace_preflight': preflight,
                    }, ensure_ascii=False, indent=2) + '\n')
            if result_path.exists():
                run = subprocess.CompletedProcess(command, 2, '', '')
            else:
                run = subprocess.run(command, capture_output=True, text=True)
        finally:
            if monitor:
                monitor.terminate()
                monitor.wait(timeout=5)
                monitor_file.close()
        trial_finished = time.time()
        record = json.loads(result_path.read_text()) if result_path.exists() else {
            'success': False, 'error': 'Harness exited before writing result',
        }
        if run.returncode and record.get('success'):
            record.update(success=False, sent_verified=True, phase='cleanup',
                          error='Harness failed after the verified send')
        if args.monitor:
            samples = [json.loads(line) for line in monitor_path.read_text().splitlines() if line.strip()]
            monitor_summary = summarize_monitor(samples, int(args.pid), args.target_state)
            record['workspace_monitor'] = monitor_summary
            if args.require_preserved_workspace and record.get('success') and not monitor_summary['preserved']:
                record.update(success=False, sent_verified=True, phase='workspace_verification',
                              error='Send verified, but workspace preservation was not established')
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
