#!/usr/bin/env python3
"""Acceptance regressions: sends do not excuse workspace interference or missing evidence."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('repeat_discord', Path(__file__).with_name('repeat-discord.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class MonitorAcceptanceTests(unittest.TestCase):
    def samples(self):
        sample = dict(front_pid=100, ax_front_pid=100, pointer_x=20, pointer_y=30,
                      target_onscreen=True, target_present=True, non_target_order_sha256='order',
                      non_target_windows_above=2, space_change_count=0,
                      receiver_hash=123, receiver_window_id=50, receiver_pid=100)
        return [dict(sample), dict(sample)]

    def test_target_activation_pointer_motion_and_covering_user_window_all_fail(self):
        for key, value in [('front_pid', 200), ('pointer_x', 21), ('non_target_windows_above', 0),
                           ('space_change_count', 1), ('receiver_hash', 456)]:
            with self.subTest(key=key):
                samples = self.samples()
                samples[-1][key] = value
                self.assertFalse(module.summarize_monitor(samples, 200)['preserved'])

    def test_incomplete_sampling_never_certifies_workspace(self):
        self.assertFalse(module.summarize_monitor([], 200)['preserved'])
        self.assertFalse(module.summarize_monitor(self.samples()[:1], 200)['preserved'])
        samples = self.samples()
        for sample in samples:
            del sample['receiver_hash']
        self.assertFalse(module.summarize_monitor(samples, 200)['preserved'])

    def test_stable_target_foreground_is_not_background_success(self):
        self.assertFalse(module.summarize_monitor(self.samples(), 100)['preserved'])

    def test_stable_complete_background_evidence_passes(self):
        self.assertTrue(module.summarize_monitor(self.samples(), 200)['preserved'])

if __name__ == '__main__':
    unittest.main()
