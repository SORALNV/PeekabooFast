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

    def test_visible_inventory_ignores_hidden_window_churn_but_rejects_visible_reordering(self):
        samples = self.samples()
        for sample in samples:
            sample.update(monitor_schema=2, visible_non_target_order_sha256='visible',
                          visible_non_target_windows_above=2)
        samples[-1].update(non_target_order_sha256='hidden churn', non_target_windows_above=3)
        self.assertTrue(module.summarize_monitor(samples, 200)['preserved'])
        samples[-1]['visible_non_target_order_sha256'] = 'reordered'
        self.assertFalse(module.summarize_monitor(samples, 200)['preserved'])

    def test_visible_monitor_missing_visible_order_never_falls_back_to_all_windows(self):
        samples = self.samples()
        for sample in samples:
            sample['monitor_schema'] = 2
        self.assertFalse(module.summarize_monitor(samples, 200)['preserved'])

    def nonvisible_samples(self, hidden):
        samples = self.samples()
        for sample in samples:
            sample.update(monitor_schema=3, target_onscreen=False, target_hidden=hidden,
                          target_space_ids='5', active_space_ids='4148', target_on_active_space=False,
                          session_locked=False, visible_non_target_geometry_sha256='geometry',
                          visible_non_target_order_sha256='visible', visible_non_target_windows_above=0,
                          target_x=0, target_y=316, target_width=868, target_height=796)
        return samples

    def test_hidden_and_offspace_require_independent_visibility_evidence(self):
        for state, hidden in [('hidden', True), ('offspace', False)]:
            with self.subTest(state=state):
                samples = self.nonvisible_samples(hidden)
                self.assertTrue(module.summarize_monitor(samples, 200, state)['preserved'])
                for key, value in [('target_onscreen', True), ('session_locked', True),
                                   ('target_hidden', not hidden), ('active_space_ids', ''),
                                   ('target_space_ids', ''), ('monitor_schema', 2)]:
                    bad = [dict(sample, **{key: value}) for sample in samples]
                    self.assertFalse(module.summarize_monitor(bad, 200, state)['preserved'], key)
                for key in ['target_hidden', 'target_space_ids', 'visible_non_target_geometry_sha256']:
                    bad = [dict(sample) for sample in samples]
                    del bad[-1][key]
                    self.assertFalse(module.summarize_monitor(bad, 200, state)['preserved'], key)
        samples = self.nonvisible_samples(False)
        for sample in samples:
            sample['target_on_active_space'] = True
        self.assertFalse(module.summarize_monitor(samples, 200, 'offspace')['preserved'])

    def test_nonvisible_target_and_workspace_geometry_must_remain_stable(self):
        for state, hidden in [('hidden', True), ('offspace', False)]:
            for key, value in [('target_space_ids', '6'), ('active_space_ids', '4149'),
                               ('target_x', 1), ('visible_non_target_geometry_sha256', 'changed')]:
                samples = self.nonvisible_samples(hidden)
                samples[-1][key] = value
                self.assertFalse(module.summarize_monitor(samples, 200, state)['preserved'], key)

    def test_stable_complete_background_evidence_passes(self):
        self.assertTrue(module.summarize_monitor(self.samples(), 200)['preserved'])

if __name__ == '__main__':
    unittest.main()
