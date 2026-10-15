# Batch/state-diff measurements

Measured locally on 2026-10-15 (Japan time). Baseline: `1e42f1d9053109d6d19e604504ea80bc229a88e8`
(upstream v4.9.3). Both binaries use the same debug configuration, Swift 6.4,
arm64 macOS, and the same dependency commits. `/tmp/peekaboo-baseline` was built
from the unmodified commit before restoring the feature sources. Server startup
is excluded. No LLM inference or artificial network delay is included.

## Real stdio MCP transport

Each round performs eight existing `sleep(duration=1ms)` actions. Both versions
use the ordinary tool executor. Baseline sends eight individual requests; the
feature sends one `execute_steps` request. Five warmups and 50 timed rounds were
run for each version. Raw samples are retained in `before.json` and `after.json`.

| Metric | Before | After |
| --- | ---: | ---: |
| MCP requests per round | 8 | 1 |
| p50 | 91.485 ms | 22.554 ms |
| p95 (nearest rank) | 94.786 ms | 42.239 ms |

The median improvement is 4.06× (75.3% less elapsed time) for
this transport-focused workload. The GUI actions themselves have not been made
4.06× faster. OS timer coalescing, other host work, JSON serialization, and
IPC all contribute. Runs were consecutive, not randomized; this is a local
benchmark, not a confidence-bounded general performance claim.

```sh
python3 benchmarks/batch-state-diff/transport.py /tmp/peekaboo-baseline sequential benchmarks/batch-state-diff/before.json
python3 benchmarks/batch-state-diff/transport.py Apps/CLI/.build/debug/peekaboo batch benchmarks/batch-state-diff/after.json
```

## AX table payload and local computation

Synthetic input: 1,000 uniquely identified fields, local IDs changed between
observations, one value changed. Five warmups and 100 measured rounds.
`ax-payload.json` retains all samples. This tests the production differ and JSON
encoding, without AX acquisition, MCP envelopes, screenshots, or LLM processing.

| Metric | Full after-table | Difference |
| --- | ---: | ---: |
| Encoded JSON bytes | 160,669 | 397 |
| p50 compute + encode | 4.454 ms | 4.682 ms |

Payload reduction: 99.753%. Diff computation
costs slightly more locally in this measurement. No end-to-end LLM/token savings
were measured, and no tokenizer estimate is presented as a measured token count.
Nodes without unique AXIdentifiers are removed/added conservatively, so apps
without identifiers can have little or no payload reduction.

```sh
PEEKABOO_DIFF_BENCHMARK_OUTPUT="$PWD/benchmarks/batch-state-diff/ax-payload.json" swift test --package-path Core/PeekabooAutomationKit --filter UIStateDiffTests
```

## Completed foreground Discord comparison (2026-10-15 JST)

The final build ran five attempts per version in ABBA order blocks. Every run
started at the same named server, focused the pinned Discord window, opened the
DM tab, selected たぬき, typed a unique 21-character ASCII test message, sent it,
and verified the exact sent text plus an empty composer. Computer Use separately
read back all ten final messages and the empty composer in the requested DM.

| Metric | Pristine upstream baseline | Measured feature build (`b758f64d`) |
| --- | ---: | ---: |
| Successful attempts | 5 / 5 (100%) | 5 / 5 (100%) |
| Median | 13.199 s | 9.484 s |
| Min–max | 12.358–13.511 s | 9.301–9.722 s |
| Driver steps / explicit verifications | 12 / 5 | 12 / 5 |
| MCP transport requests | 17 | 1 |

The median was **28.1% shorter (1.39×)**. This compares the combined
implementation changes, including the exact-receiver fast path and batching;
it does not isolate batching's contribution. Both versions execute the same GUI
work and verification predicates. `get_state_diff` is not used by this workload.
There is no LLM inference or artificial network delay. Process startup, initial
window restoration and the common server reset are excluded; the timed plan
includes its own exact-window focus step before navigation.

Raw results, order, binary and harness hashes are in
`repeated-uninterrupted-2026-10-15/`. The two binaries are debug builds on the same
arm64 macOS 26.6.2 host. The DM history grew across runs; order blocks reduce, but
do not eliminate, order effects. Five attempts per version support a local
comparison, not a universal reliability guarantee or a meaningful tail-latency
estimate.

### Foreground stability and observer effects

The final cohort runs in one execution cell. After starting it, no additional
`exec_command` calls or CUA operations occur until all ten trials finish. A
read-only native monitor runs identically during both versions and records focus,
window geometry and on-screen state. All **1,327 observed samples** within the
trial intervals show the same Discord process in front, the same 868×796 window,
and `on_screen=true`. The monitor samples at roughly 100 ms; it cannot rule out
changes between samples. See `focus-observation.json` and `cua-readback.json`.

Earlier final-binary attempts are also retained, with no failed trial deleted or
silently retried:

| Cohort | Before | After | Interpretation |
| --- | ---: | ---: | --- |
| `repeated-2026-10-15` | 1/5 | 0/5 | Window identity/bounds and focus changed; no valid after-speed estimate |
| `repeated-monitored-2026-10-15` | 3/5 | 3/5 | All four failed attempts overlap Codex being frontmost and Discord being off screen |
| `repeated-uninterrupted-2026-10-15` | 5/5 | 5/5 | No sampled foreground/geometry change; final controlled comparison above |

The middle cohort's successful medians were 12.167 s and 9.278 s; those are based
on only three successes per version and are not pooled with the final cohort.
The native monitor identifies the other frontmost process as the Codex/ChatGPT
app. The activation initiator is **not established**. Extra diagnostic shell
calls were removed to avoid a potential observer effect; success after that
change alone does not prove which component caused the earlier activations.
Real focus/identity changes still stop input safely. The results therefore do
not claim reliable operation while another app repeatedly takes foreground.

### Reproduce the sending test

This deliberately sends ten messages. Use current observed PID/window and labels,
a fresh output directory, and a foreground-stable interval. Keep build/test work
outside the measurements. Run the following as one uninterrupted process:

```sh
python3 benchmarks/batch-state-diff/repeat-discord.py \
  --before /tmp/peekaboo-baseline --after /tmp/peekaboo-after-final \
  --pid CURRENT_DISCORD_PID --window CURRENT_WINDOW_ID \
  --server '自作erの集い' --recipient 'たぬき' \
  --dm-label 'たぬき (ダイレクトメッセージ)' \
  --output benchmarks/batch-state-diff/FRESH_RUN_DIRECTORY
```

The runner creates a unique run prefix, preserves every attempt (including
preparation/readback/cleanup failures), and refuses to overwrite an output
directory. Both versions use depth 120, 10,000 elements, 1,000 children, 10 ms
literal typing cadence, and two stable verification samples within a 10-second
hard cap. Window focus uses explicit foreground authority; typing and Return are
bound to the exact background receiver. There are no hidden observation/action
retries. Full private UI traces stay in `/tmp/peekaboo-discord-last-run.json`,
outside this repository.

`focus-monitor.swift` is a read-only companion that reports numeric focus/window
state without message history. Start it before the runner, redirect its output
to a temporary log, then stop it after the comparison:

```sh
swiftc -swift-version 6 benchmarks/batch-state-diff/focus-monitor.swift -o /tmp/peekaboo-focus-record
/tmp/peekaboo-focus-record CURRENT_DISCORD_PID CURRENT_WINDOW_ID
```

### Historical exploratory records

The earlier B pair (`discord-before.json`, `discord-after.json`, also with B
suffixes) took 9.834 s versus 10.415 s with the old 11-step plan. C stopped during
typing before send; E/F/G hit AX verification failures. A subsequent pilot is in
`pilot-repeated-2026-10-15/`: both versions 5/5, medians 10.719 s and 8.499 s.
That pilot used the focus step after recipient selection and preceded final
native-probe/diagnostic adjustments. These differing plans/builds/text lengths
are not pooled with the final comparison.

An exploratory AX-value test sent `Peekaboo`: AXValue readback alone did not
establish Discord's controlled composer state. Final trials use actual keyboard
input and verify the sent message. The old test draft was cleared; CUA confirms
an empty composer after the final cohort. The Mac-lock refusal happened before
measurement and is not counted as a timed trial.

## Causes, fixes and validation

[Window and focus diagnosis](../../docs/discord-window-diagnosis.md) explains the
empty AXWindows fallback, live receiver verification, deadline budgeting and the
controlled inactive-window reproduction. Observation timeouts no longer claim
that focus physically moved. Verification remains read-only; it never steals
focus or retries a send.

- Baseline and final feature CLI builds: passed.
- Full `pnpm run test:safe`: passed (2,391 Swift Testing cases plus script/Node checks).
- Final-source targeted core run: 73 tests passed.
- Final-source targeted automation-kit run: 46 Swift Testing + 20 XCTest cases passed.
- Repository format check: passed. Changed-file SwiftLint: 0 violations in 33 files.
- Repository lint: passed with existing warnings, no serious violations.
- Standalone read-only diagnostics: compiled successfully with Swift 6.
- `validation.json` records commands, outcomes and the retained final binary hash.

## Controlled background comparison after editor-focus repair

`discord.py` and `repeat-discord.py` accept `--background-only`. MCP starts
without foreground authority and every focus operation is omitted, including
server-reset preparation. The workload has 11 driver steps and five verifications:
16 outer MCP calls upstream versus one `execute_steps` call in the fork. Both use
fresh snapshot references, literal typing and identical readback predicates.

After manual unlock, Discord was prepositioned onscreen behind an existing Finder
window on the same regular Space. This initial setup used authorized foreground
diagnostics and is excluded from the background claim. The complete trial, including
subsequent server resets, was monitored. No temporary foreground fixture was created.
Electron AXManualAccessibility had been requested as a common precondition for
both versions; AXEnhancedUserInterface stayed disabled. Prior diagnostic sends
mean this is not a cold-start test. `warmup_sends=0` only describes runner warmups.

| Metric | Upstream baseline (`95c61d71`) | Editor-focus fork (`ddfe3a68`) |
| --- | ---: | ---: |
| Verified sends with preserved workspace | 2/5 (40%) | 5/5 (100%) |
| Successful-run median | 16.121 s | 11.117 s |
| Successful min–max | 15.755–16.487 s | 10.941–13.214 s |
| Driver steps / explicit verifications | 11 / 5 | 11 / 5 |
| Outer MCP calls | 16 | 1 |

Successful-run median: **31.0% shorter (1.45×)**. Failure timings are retained;
three baseline failures are not included in that conditional median. A five-trial
cohort supports this local observation, not a general success probability or tail
estimate. This combines all fork changes and does not isolate batching or focus.
LLM inference, process startup and the common server reset are outside the timed
workload. Preparation is still inside the workspace-preservation interval.

Records are in `background-visible-order-2026-10-15/`: all ten outcomes, ABBA order,
binary/harness/monitor hashes, exact harness copies, numeric monitor logs, conditions,
and independent CUA readback. All **1,324 samples** preserve foreground Finder, its
exact native receiver, pointer, onscreen window order, target visibility and Space
change count. All ten trials pass workspace preservation, including three failed
baseline sends. CUA independently sees two baseline and five fork messages plus
an empty composer. Sampling at roughly 100 ms cannot exclude intersample changes.

The remaining focus cause was AXPress on Discord's editable composer: the action
was accepted without establishing its native keyboard receiver. Prefer writable
AXFocused on text-entry controls when policy permits. The pre-repair same-Space
pilot failed before typing; the fixed pilot succeeded. The three final baseline
failures lost proof of the receiver during typing and stopped without blind retry.
[Diagnosis](../../docs/discord-window-diagnosis.md) describes the native evidence.

The final source additionally preserves combo-box AXPress semantics and makes
positional editor focus take precedence over a pressable ancestor. The measured
cohort used semantic AXTextArea clicks; that route is unchanged. The measured
binary hash stays distinct from the final qualification build. Final source:
118 related driver tests, six monitor-acceptance tests, and the full 2,391-case
`test:safe` suite plus script/Node checks pass. Root lint has 110 existing warnings,
changed driver/test files have zero strict-lint violations, and format/docs lint pass.

### Retained unsuccessful acceptance cohort and monitor diagnosis

`background-controlled-2026-10-15/` retains the preceding complete ten attempts.
It verified 2/5 baseline and 5/5 fork sends but certified **0/5 versus 0/5** workspace
acceptance under a strict all-window inventory rule. Foreground, receiver, pointer,
target visibility and Space stayed stable; all-window ordering changed. Do not
reclassify these attempts as passed or pool them with the subsequent cohort.

A separate diagnostic pilot identified offscreen windows created/removed by Apple's
CursorUIViewService (PID 625). The onscreen inventory stayed constant. Its numeric
inventory changes and aggregate are retained in
`background-unlocked-pilots-2026-10-15/window-churn-diagnosis.json`.
Monitor schema 2 therefore measures **onscreen** window ordering for visible
interference and retains all-window ordering/inventory changes as diagnostic data.
Missing schema-2 onscreen evidence cannot fall back to an all-window pass. A fresh
full cohort used the revised monitor; it did not retry only failed trials.
The preceding harness is preserved in `background-all-window-harness/`.

### Scope and unresolved cases

This is an already-onscreen, same-Space result. Hidden/off-Space navigation remains
unresolved: the post-unlock hidden pilot failed verification. No product fallback
activates/unhides targets or switches Spaces during user work. The result does not
establish a general replacement for ChatGPT Computer Use. Discord was hidden and
the original ChatGPT/Codex app restored after testing.

Six earlier failed exploratory attempts in `background-pilots-2026-10-15`, seven
resumed attempts in `background-resumed-2026-10-15`, and four later unlocked pilots
in `background-unlocked-pilots-2026-10-15` use differing prerequisites/binaries and
remain separate. Earlier foreground fixtures obstructed the user's work and were
removed. Those runs do not count as practical background successes. See
[the contract and limits](../../docs/background-execution.md).

The exact three Python harness sources for the completed foreground cohort are
preserved in `foreground-harness/`. Their SHA-256 hashes match all three entries
in `repeated-uninterrupted-2026-10-15/manifest.json`. The scripts at this directory's
root additionally support the newer background-only experiment and therefore
have different hashes.

### Strict background acceptance for a new controlled cohort

Compile the current monitor and pass it to the runner. This monitors preparation
as well as timed work and marks a send as failed acceptance when workspace
preservation cannot be established. Use one unchanged unlocked desktop condition
for all trials, and record any accessibility-mode preparation identically for
both versions. Do not run this while the Mac is locked.

```sh
swiftc -swift-version 6 benchmarks/batch-state-diff/focus-monitor.swift -o /tmp/peekaboofast-focus-monitor
python3 benchmarks/batch-state-diff/repeat-discord.py \
  --before /tmp/peekaboo-baseline --after /tmp/peekaboofast-editor-focus \
  --pid CURRENT_DISCORD_PID --window CURRENT_WINDOW_ID \
  --server '自作erの集い' --recipient 'たぬき' \
  --dm-label 'たぬき (ダイレクトメッセージ)' \
  --background-only --monitor /tmp/peekaboofast-focus-monitor \
  --require-preserved-workspace --output FRESH_OUTPUT_DIRECTORY
```

The monitor reports only numeric receiver/window state, pointer coordinates,
Space-change counts, onscreen ordering hashes and numeric inventory changes.
It does not publish
window titles, UI text, or message histories. A missing keyboard receiver or
insufficient samples is unknown evidence, never a successful preservation result.
`python3 benchmarks/batch-state-diff/test_monitor_summary.py` checks acceptance
against focus theft, pointer motion, visible reordering, hidden-window churn and
missing evidence. Schema-2 logs retain legacy all-window hashes for diagnosis;
onscreen windows determine the window-order acceptance predicate.
