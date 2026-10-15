#!/usr/bin/env python3
"""Explicit live Discord DM benchmark. Sends exactly one test message per run.
Requires recipient and server labels observed in the current UI; no deep-link shortcut.
"""
import argparse
import json
import os
import time
from pathlib import Path
from transport import Client


def verify_args(pid, window, label, role=None):
    selector = {'label': label}
    if role:
        selector['role'] = role
    return {'pid': pid, 'window_id': window, 'timeout_ms': 10000, 'stable_samples': 2,
            'predicates': [{'kind': 'element_exists', 'selector': selector, 'expected': True}]}


def observation(pid, window):
    return {'tool': 'inspect_ui', 'arguments': {'app_target': f'PID:{pid}', 'window_id': window,
                                               'max_depth': 120, 'include_elements': True}}


def raw_call(client, name, arguments):
    response = client.request('tools/call', {'name': name, 'arguments': arguments})
    return response


def verified(response):
    return not response.get('isError') and any(
        x.get('text', '').startswith('Verification satisfied ') for x in response.get('content', []))


def failure_summary(response):
    structured = response.get('structuredContent')
    if structured is None:
        try:
            structured = json.loads(response.get('content', [{}])[0].get('text', ''))
        except (ValueError, TypeError):
            structured = None
    if isinstance(structured, dict) and structured.get('results'):
        response = structured['results'][-1]
    metadata = response.get('_meta', response.get('meta')) or {}
    safe_keys = {'state', 'effect', 'dispatch_state', 'dispatched_unit_count', 'delivery_mode',
                 'delivery_mechanism', 'escalation', 'retry_safe', 'retry_safety', 'evidence',
                 'mutation_dispatched', 'requires_fresh_observation', 'target_receipt',
                 'target_identity', 'error_code'}
    message = str(response.get('content', [{}])[0].get('text', ''))[:1600]
    if 'ui_elements' in metadata:
        message = 'AX observation failed; detailed UI state retained only in the temporary diagnostic trace'
    return {'is_error': response.get('isError', response.get('is_error')),
            'tool': response.get('tool'), 'meta': {key: value for key, value in metadata.items() if key in safe_keys},
            'message': message,
            'verification': str(response.get('verification', {}).get('content', [{}])[0].get('text', ''))[:1200] if response.get('verification') else None}



def check(response):
    if response.get('isError'):
        raise RuntimeError(failure_summary(response))
    return response


def main():
    p = argparse.ArgumentParser()
    p.add_argument('binary')
    p.add_argument('mode', choices=['sequential', 'batch'])
    p.add_argument('output')
    p.add_argument('--pid', type=int, required=True)
    p.add_argument('--window', type=int, required=True)
    p.add_argument('--server', required=True)
    p.add_argument('--recipient', required=True)
    p.add_argument('--dm-label', required=True)
    p.add_argument('--text', required=True)
    args = p.parse_args()
    os.environ['PEEKABOO_AX_MAX_DEPTH'] = '120'
    os.environ['PEEKABOO_AX_MAX_ELEMENTS'] = '10000'
    os.environ['PEEKABOO_AX_MAX_CHILDREN'] = '1000'
    c = Client(str(Path(args.binary).resolve()), foreground=True)
    history = []
    phase = 'preparation'
    try:
        obs = observation(args.pid, args.window)
        check(raw_call(c, 'window', {'action': 'focus', 'app': 'Discord', 'window_id': args.window}))
        # Preparation is excluded from timings. Start each run on a named server, never the DM tab.
        initial = check(raw_call(c, obs['tool'], obs['arguments']))
        server_rows = [e for e in initial['_meta']['ui_elements'] if e.get('label') == args.server and e.get('ax_role') == 'AXRow']
        if len(server_rows) != 1:
            raise RuntimeError('Server row must match uniquely')
        reset = raw_call(c, 'action', {'on': server_rows[0]['id'], 'action': 'AXPress'})
        meta = reset.get('_meta', {})
        if reset.get('isError') and meta.get('state') != 'dispatched_unverified':
            raise RuntimeError(failure_summary(reset))
        reset_verification = raw_call(c, 'verify_state', verify_args(args.pid, args.window, f'{args.server}、サーバー操作', 'AXButton'))
        if not verified(reset_verification):
            raise RuntimeError(failure_summary(reset_verification))
        state = check(raw_call(c, obs['tool'], obs['arguments']))
        summary = '\n'.join(x.get('text', '') for x in state['content'])
        if args.server not in summary:
            raise RuntimeError('Initial state is not the requested server')
        composer = f'@{args.recipient} へメッセージを送信'
        typed_verification = verify_args(args.pid, args.window, composer, 'AXTextArea')
        typed_verification['predicates'][0] = {
            'kind': 'element_value', 'selector': {'label': composer, 'role': 'AXTextArea'},
            'expected_value': args.text}
        steps = [{'tool': 'window', 'arguments': {'action': 'focus', 'app': 'Discord', 'window_id': args.window}}, obs,
                 {'tool': 'click', 'arguments': {'query': 'ダイレクトメッセージ'},
                  'verify': verify_args(args.pid, args.window, 'フレンド', 'AXLink')},
                 obs,
                 {'tool': 'click', 'arguments': {'query': args.dm_label},
                  'verify': verify_args(args.pid, args.window, composer, 'AXTextArea')},
                 obs,
                 {'tool': 'click', 'arguments': {'query': composer},
                  'verify': verify_args(args.pid, args.window, composer, 'AXTextArea')},
                 obs,
                 {'tool': 'type', 'arguments': {'app': 'Discord', 'window_id': args.window, 'foreground': False, 'text': args.text, 'clear': True, 'delay': 10}, 'verify': typed_verification},
                 obs,
                 {'tool': 'press', 'arguments': {'app': 'Discord', 'window_id': args.window,
                                                'foreground': False, 'key': 'Return'},
                  'verify': verify_args(args.pid, args.window, args.text, 'AXStaticText')},
                 obs]
        phase = 'timed_workload'
        starting_calls = c.counter
        started = time.perf_counter_ns()
        if args.mode == 'batch':
            response = raw_call(c, 'execute_steps', {'steps': steps})
            history.append({'tool': 'execute_steps', 'response': response})
            check(response)
            structured = response.get('structuredContent') or json.loads(response['content'][0]['text'])
            assert structured['completed'] == len(steps)
            call_count = 1
        else:
            call_count = 0
            for step in steps:
                response = raw_call(c, step['tool'], step['arguments'])
                call_count += 1
                history.append({'tool': step['tool'], 'response': response})
                recoverable = response.get('_meta', {}).get('state') == 'dispatched_unverified'
                if response.get('isError') and not (recoverable and 'verify' in step):
                    raise RuntimeError(failure_summary(response))
                if 'verify' in step:
                    verification = raw_call(c, 'verify_state', step['verify'])
                    call_count += 1
                    history.append({'tool': 'verify_state', 'response': verification})
                    check(verification)
                    if not verified(verification):
                        raise RuntimeError(failure_summary(verification))
        elapsed = (time.perf_counter_ns()-started)/1e6
        call_count = c.counter - starting_calls
        # Independent readback excluded from timing, verifies exact recipient and sent text.
        phase = 'independent_readback'
        final = check(raw_call(c, obs['tool'], obs['arguments']))
        labels = [e.get('label','') for e in final['_meta']['ui_elements']]
        assert composer in labels and args.text in labels, 'Sent message not visible in exact DM'
        fields = [e for e in final['_meta']['ui_elements'] if e.get('label') == composer and e.get('ax_role') == 'AXTextArea']
        assert len(fields) == 1 and not fields[0].get('value', '').replace('\ufeff','').strip(), 'Composer not empty after send'
        output = {'mode': args.mode, 'elapsed_ms': elapsed, 'mcp_calls': call_count,
                  'driver_steps': len(steps), 'verifications': 5, 'success': True,
                  'initial_state': 'server', 'recipient': args.recipient, 'text': args.text,
                  'llm_included': False, 'composer_empty': True}
        Path(args.output).write_text(json.dumps(output, ensure_ascii=False, indent=2)+'\n')
        print(json.dumps(output, ensure_ascii=False, indent=2))
    except Exception as error:
        failure = {'success': False, 'mode': args.mode, 'text': args.text, 'phase': phase, 'error': str(error)[:3000]}
        if 'started' in locals():
            failure['elapsed_ms'] = (time.perf_counter_ns()-started)/1e6
        Path(args.output).write_text(json.dumps(failure, ensure_ascii=False, indent=2)+'\n')
        raise
    finally:
        # Diagnostic history may include other messages; keep it outside the repository.
        Path('/tmp/peekaboo-discord-last-run.json').write_text(json.dumps(history,ensure_ascii=False,indent=2))
        c.close()

if __name__ == '__main__':
    main()
