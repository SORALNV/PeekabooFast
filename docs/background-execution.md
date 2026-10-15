---
summary: 'PeekabooFast background execution contract, current implementation, and unresolved Discord limits.'
read_when:
  - 'Running automation while the user works in another application'
  - 'Interpreting Discord background test results'
---

# Background execution in PeekabooFast

Background execution is a requirement of this fork. It means the user's current
application, keyboard receiver, physical pointer, window order, and workspace
remain usable. Keeping Discord foreground for several minutes does not meet this
requirement. A test window that steals focus or covers the user's work also fails
it, even if the automation target itself never activates.

## Implemented

- Existing process/window-targeted input remains subject to the upstream
  background-only execution policy. There is no automatic foreground fallback.
- Exact-window discovery recovers owner-checked AXMainWindow/AXFocusedWindow
  references when AXWindows is successfully read but empty.
- Focus validation checks the current native receiver before a bounded tree
  search. Observation failures retain their actual cause instead of claiming
  physical focus moved.
- State verification recomputes its remaining monotonic deadline after target
  resolution; it does not grant AX a stale time budget.
- AX observation explicitly refuses a known locked macOS session instead of
  reporting a misleading incomplete tree or focus timeout.
- Electron observations request the documented `AXManualAccessibility` handshake
  in the existing bounded worker after process-generation validation. They never
  set `AXEnhancedUserInterface`, activate an app, or move a window. Setter acceptance
  is not treated as success; fresh AX evidence and exact delivery checks still apply.
  See [Electron's accessibility documentation](https://github.com/electron/electron/blob/main/docs/tutorial/accessibility.md).
  This latest integration has unit coverage; its first live pilot overlapped a
  confirmed screen lock and does not establish effectiveness.
- `execute_steps.snapshot_from_step` explicitly passes a preceding observation's
  snapshot ID to background `type`/`press` while retaining their normal validation.
- Semantic clicks can select an enabled AXRow exposing writable AXSelected but no
  AXPress. This path does not hit-test the desktop or focus an application and
  reports dispatched/unverified until the caller verifies the requested state.
  Unit tests cover dispatch, policy refusal, identity revalidation, and refusal to
  replay after uncertain AXPress failure. It is not a claimed fix for every
  Discord row: some observed rows expose neither writable selection nor AXPress.

## Discord status: incomplete

Reliable end-to-end background Discord sending remains unestablished. During a
separately authorized unattended follow-up, CUA sent one test DM and two native
exploratory runs verified a sent message plus an empty composer. Their prerequisites
and binaries differed, and full workspace preservation was not certified. These
are useful diagnostic successes, not a controlled success rate or a replacement
claim for ChatGPT Computer Use. The foreground benchmark measures a different condition.

Observed failure modes include:

1. After a background navigation dispatch, the window title changes but the AX
   content can still describe the previous page. CUA also observed a title/content
   disagreement and an image of the previous page. The specific Chromium/macOS
   internal cause has not been isolated.
2. Native Space queries showed a target outside the reported active Space during
   some failures. Other controlled samples reported the target on screen while a
   separate foreground fixture stayed active. Therefore Space membership alone
   is not a complete explanation.
3. Discord sidebar rows sometimes advertise only AXShowMenu/AXScrollToVisible,
   and AX-focused editors can still yield no application keyboard receiver.
   Input correctly stops before typing when no exact receiver can be proved.
4. A batch using only background authority previously could not pass a newly
   created snapshot ID to a later step. The explicit reference feature fixes
   that orchestration limitation; it does not manufacture native focus.

Disabling the enhanced AX mode exposed rows without AXPress; requesting Electron's
official manual accessibility mode restored AXPress in a native probe even though
its attribute readback stayed false. This motivates the bounded manual handshake;
it does not justify accepting a false readback as a successful input operation.
Experiments with target-only activation records, window-routed single clicks,
and Space membership did not establish reliable background sending. Experimental
single-click delivery changes were removed. No OS security protections were changed.

## Test interruption and remaining validation

The follow-up fixture opened a foreground window and setup focused Discord. This
obstructed the user's active work and is **not** acceptable background behavior.
After the user reported the obstruction, live UI tests stopped, fixture processes
were terminated, and Discord was hidden with a confirmed background native result.
The default contract forbids repeating that setup while the user is working.
A later explicit unattended interval authorized scoped live diagnostics again;
it did not change the product's default or turn foreground setup into background proof.

Six recorded exploratory attempts are preserved in
`benchmarks/batch-state-diff/background-pilots-2026-10-15`. They use different
experimental binaries and are not a controlled before/after cohort. They are all
failures; none is discarded or retried into a success count. Seven later pilot records are retained in
`benchmarks/batch-state-diff/background-resumed-2026-10-15`, including two verified
sends and the locked-session failure. They are not pooled. The requested final
five-before/five-after background comparison remains outstanding after the Mac
locked and CUA required manual unlock.

Future live acceptance must measure foreground preservation, window order and
visibility, physical pointer interference, and independent verification of the
exact recipient and sent message, in addition to elapsed time. Native inspection
must prove the selected target without creating a foreground test window or
moving the user's workspace. UI tests require an agreed test session; safe unit
checks and source work can continue without interacting with the desktop.

## Agent prompt and measurement contract

[External MCP client prompt](background-client-prompt.md) provides the same default for clients that do not use the built-in Agent.

Generated prompts at every authority level preserve the user's application,
keyboard receiver, pointer, window order and Space by default. Temporary unattended
permission expires on the user's return or the interval's end. Existing scoped
permission for harmless test messages is honored without repeated confirmation.
Batches retain child authority, fresh snapshot requirements and stop-on-unknown
verification; they never enable a foreground fallback.

The updated repeat harness can require a native monitor covering preparation as
well as timed work. It rejects a verified send as a successful background trial
when focus, receiver, pointer, window order or Space changed, or when required
monitor evidence is missing. Sampling cannot rule out changes between observations.
