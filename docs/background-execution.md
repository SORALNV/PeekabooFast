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
  A subsequent unlocked same-Space background cohort completed with this handshake
  requested as a common precondition for both versions.
- `execute_steps.snapshot_from_step` explicitly passes a preceding observation's
  snapshot ID to background `type`/`press` while retaining their normal validation.
- Semantic clicks can select an enabled AXRow exposing writable AXSelected but no
  AXPress. This path does not hit-test the desktop or focus an application and
  reports dispatched/unverified until the caller verifies the requested state.
  Unit tests cover dispatch, policy refusal, identity revalidation, and refusal to
  replay after uncertain AXPress failure. It is not a claimed fix for every
  Discord row: some observed rows expose neither writable selection nor AXPress.

## Discord status: same-Space background verified, hidden/off-Space unresolved

After the user unlocked the Mac, a controlled ten-attempt cohort ran without
foreground authority. Each trial reset to the same server through a background
action, opened the DM tab, selected たぬき, typed a unique test message, sent it,
and verified the exact sent text and empty composer. Discord was already onscreen
behind an existing Finder window on the same regular Space. No fixture was created.

| Result | Pristine upstream | PeekabooFast editor-focus build |
| --- | ---: | ---: |
| Verified sends with workspace preserved | 2/5 | 5/5 |
| Successful-run median | 16.121 s | 11.117 s |
| Outer MCP requests | 16 | 1 |

The successful-run median was 31.0% shorter. This comparison includes all fork
changes; it does not isolate batching or the editor-focus repair. Failed trials
remain in the denominator. Five attempts on one host are not a general reliability
estimate, and medians conditional on success omit three failed baseline timings.
No LLM inference is included. See
[`background-visible-order-2026-10-15`](../benchmarks/batch-state-diff/background-visible-order-2026-10-15).

A native monitor covered startup, server preparation, timed work and readback.
All 1,324 samples preserved foreground Finder, its exact keyboard receiver, the
physical pointer, onscreen window order and Space-change count. Discord remained
onscreen and background. Sampling cannot exclude changes between observations.
CUA independently observed all seven sent messages and an empty composer.

The setup condition matters: during explicitly permitted unattended diagnostics,
Discord was unhidden/activated once, then an existing Finder window was focused.
That foreground setup is **outside** this background acceptance claim. Normal
background sessions never perform it automatically. Restoring a hidden target or
working across another fullscreen Space remains unresolved; the earlier hidden
post-unlock pilot failed. Therefore this result does not meet a universal
background-computer-use requirement or prove superiority to another product.

### Remaining editor-focus cause and repair

The published pre-repair fork navigated successfully in the same condition but
refused typing because application AXFocusedUIElement returned noValue. The
composer advertised AXPress and accepted the click without becoming the native
keyboard receiver. A CUA click on the exact composer alone established a real
AXTextArea receiver while Finder remained foreground; no text input was needed.

ActionInputDriver now prefers writable AXFocused for enabled text-entry controls,
even if AXPress is advertised, when accessibility-value delivery is permitted.
Positional resolution likewise admits focus instead of selecting that editor's
press route. Policy opt-out retains AXPress. Existing exact-owner/generation/window
validation remains in force. A failed focus setter is not followed by blind press
or global activation. The fixed pilot's click reported accessibility_value and its
literal typing reported window_targeted_events with confirmed change. This is a
focus change inside Discord, not a change of the user's foreground receiver.

### Retained failures and monitor correction

The first post-repair ten-attempt cohort verified 2/5 baseline and 5/5 fork sends,
but its strict all-window-order criterion failed every trial. All-window inventory
included hidden system windows. An additional diagnostic identified additions and
removals belonging to Apple's CursorUIViewService; they were offscreen, while the
visible order remained constant. The original records and harness remain intact
in `background-controlled-2026-10-15` and `background-all-window-harness`.

Monitor schema 2 separately measures onscreen window order and retains all-window
inventory changes for diagnosis. It still rejects foreground, keyboard receiver,
pointer, visible order, target-visibility and Space changes or missing evidence.
A **new** full ten-attempt cohort used that monitor. No old trial was reclassified
or silently retried into the new cohort's success rate. Unit regressions cover
hidden-window churn versus visible reordering and missing schema-2 evidence.

Earlier six failed pilots, seven resumed pilots, and four new unlocked diagnostic
pilots are preserved separately under `benchmarks/batch-state-diff/`; different
builds and prerequisites are not pooled. Earlier foreground results are a different
workload. Previously obstructive fixture processes were removed; after this
cohort Discord was hidden again and the original ChatGPT/Codex app restored.
No lock/security preferences were changed.

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
