#!/usr/bin/env python3
"""Real stdio MCP latency. No LLM/network delays are simulated or included."""
import argparse
import json
import math
import os
import statistics
import subprocess
import time
from pathlib import Path

class Client:
    def __init__(self, binary, foreground=False):
        self.log = open('/tmp/peekaboo-benchmark-server.log', 'a')
        env = dict(os.environ, PEEKABOO_ALLOW_TOOLS='sleep,execute_steps,permissions,app,inspect_ui,get_state_diff,verify_state,set_value,click,press,type,see,action,window')
        self.process = subprocess.Popen([binary, 'mcp', '--no-remote'] + (['--allow-foreground'] if foreground else []), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, text=True, env=env)
        self.counter = 0
        self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                                   'clientInfo': {'name': 'peekaboo-benchmark', 'version': '1'}})
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'})+'\n')
        self.process.stdin.flush()

    def request(self, method, params):
        self.counter += 1
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': self.counter,
                                            'method': method, 'params': params})+'\n')
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError('Server exited; see /tmp/peekaboo-benchmark-server.log')
            value = json.loads(line)
            if value.get('id') == self.counter:
                if 'error' in value:
                    raise RuntimeError(value['error'])
                return value['result']

    def call(self, name, arguments):
        result = self.request('tools/call', {'name': name, 'arguments': arguments})
        if result.get('isError'):
            raise RuntimeError(result)
        return result

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.log.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary')
    parser.add_argument('mode', choices=['sequential', 'batch'])
    parser.add_argument('output')
    parser.add_argument('--rounds', type=int, default=50)
    args = parser.parse_args()
    client = Client(str(Path(args.binary).resolve()))
    try:
        samples = []
        for iteration in range(args.rounds+5):
            started = time.perf_counter_ns()
            if args.mode == 'sequential':
                for _ in range(8):
                    client.call('sleep', {'duration': 1})
            else:
                result = client.call('execute_steps', {'steps': [
                    {'tool': 'sleep', 'arguments': {'duration': 1}} for _ in range(8)]})
                structured = result.get('structuredContent') or json.loads(result['content'][0]['text'])
                assert structured['completed'] == 8 and not structured['stopped_on_error']
            elapsed = (time.perf_counter_ns()-started)/1e6
            if iteration >= 5:
                samples.append(elapsed)
        ordered = sorted(samples)
        output = {'mode': args.mode, 'workload': '8 x sleep(1ms)', 'warmup_rounds': 5,
                  'rounds': args.rounds, 'calls_per_round': 8 if args.mode == 'sequential' else 1,
                  'p50_ms': statistics.median(samples), 'p95_ms': ordered[math.ceil(len(ordered)*0.95)-1],
                  'samples_ms': samples, 'llm_included': False}
        Path(args.output).write_text(json.dumps(output, indent=2)+'\n')
        print(json.dumps({k:v for k,v in output.items() if k != 'samples_ms'}, indent=2))
    finally:
        client.close()

if __name__ == '__main__':
    main()
