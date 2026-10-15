---
summary: 'Discord AXWindows can be empty while AXMainWindow remains valid; off-screen is not minimized.'
read_when:
  - 'Discord is visible but exact-window AX observation or focus fails'
---

# Discord exact-window diagnosis

The live comparison exposed a pre-existing discovery problem before any timed
message was sent. Computer Use could read and click the window, while stock
Peekaboo reported `no_matching_accessibility_window`, refused an exact AX
observation as incomplete, and could not focus/restore the window.

Direct read-only macOS API checks on the same process/window established:

| Observation | Value at reproduction |
| --- | --- |
| `AXWindows` | success, empty array |
| `AXMainWindow` / `AXFocusedWindow` | valid window, same exact CGWindowID |
| `AXMinimized` on that window | false |
| App `isHidden` | false |
| ScreenCaptureKit `isOnScreen` | false |

Computer Use independently exposed the same window and Discord composer. Thus
`isOnScreen=false` was not evidence of AX minimization. The exact reason macOS
excluded the window from the current on-screen catalog was not established;
other Spaces/window sets can also produce off-screen catalog entries. It is not
appropriate to infer a user action or a minimized state from that flag alone.

## Fix

- If `AXWindows` is successfully read but empty, supplement it with owner-checked
  `AXWindow` references from `AXMainWindow` and `AXFocusedWindow`, deduplicated by
  CF identity. A nonempty inventory is left unchanged.
- Apply this recovery to bounded inventory enrichment, exact-window scanning,
  live window lookup, and detached exact-window observations.
- Retain process-generation, exact window ID, and bounds validation. Fallback
  inventory remains explicitly partial; no synthetic window IDs or title guesses
  authorize input.
- Stop inferring `isMinimized=true` from an off-screen CG/SC entry. Preserve the
  off-screen capture refusal and leave unknown minimization unset in receipts.
- Include the traversal-limit reason in `verify_state` diagnostics.

After the fix, inventory classified the same window as `combined_eligible` and
Peekaboo's own verified `window focus --space-switch` succeeded. It then appeared
on screen and both the original and modified binaries could run the same visible
Discord workload. Window preparation is excluded from the timed comparison.

Historical exploratory harness observations:

- A partial-name action query can match a server folder or static text. Initial
  server selection therefore uses the freshly observed exact `AXRow` ID.
- Global raw Return reports an indeterminate outcome even if a message is sent.
  The comparison uses exact-window background Return plus explicit readback.
- `AXValue` readback alone did not establish that Discord's controlled composer
  state had updated. An exploratory value-set read back the requested string,
  while sending submitted an earlier draft (`Peekaboo`). Final trials use actual
  keyboard input and verify the sent message, not only the input field.
- Background typing can lose window focus midway. The batch stopped on that
  failure without sending or blindly retrying. An intermediate mitigation focused
  only after navigation and used foreground typing; those trials still stopped
  on AX deadlines. The follow-up below replaces that intermediate plan.

## Follow-up: focus loss and verification deadlines

The second investigation separated three different failure modes instead of
assuming every timeout meant the user had moved focus.

1. The exact keyboard receiver reader still depended exclusively on `AXWindows`.
   It now uses the same bounded, owner-checked main/focused-window fallback as
   discovery, only after a successfully read empty inventory.
2. That reader traversed up to 4,096 nodes before **every character**, inside a
   caller deadline of 200 ms. An expired observation was then reported as focus
   loss. It now first reads the application's live focused reference, verifies
   AXFocused, PID, exact owning window, role, identifier/title and frame, and uses
   the existing full scan only when that direct evidence cannot establish a
   match. Continuations retain the existing reflow policy. Every native probe
   remains bounded; no identity or focus check is bypassed. Timeout errors now
   retain their actual observation error, and cancellation propagates.
3. `verify_state` reused the sample's initial remaining duration after awaiting
   application/window resolution. This could grant a native traversal more time
   than actually remained and round a final tiny remainder up to 50 ms. It now
   recomputes the remaining monotonic budget immediately before AX acquisition
   and declines to enqueue a traversal when less than the worker's minimum 50 ms
   remains. The overall 10-second hard cap is unchanged.

The original apparent AX traversal timeout also concealed a transition problem:
per-sample diagnostics showed repeated **unsatisfied, count=0** results before
only the final near-deadline observation became truncated. A controlled live
experiment established the following, without sending a message:

- Focus Discord and select the server: verified.
- Switch to Codex, press the Discord DM row through background AX: dispatched.
- Observe the expected Friends link: not verified within 3 seconds.
- Focus the same exact Discord window and **do not replay the click**: the same
  predicate becomes satisfied in two samples (0.510 s).

The record is `benchmarks/batch-state-diff/focus-transition-diagnosis.json`.
This establishes that foreground settlement affects this Discord transition's AX
readback. It does not establish which internal Chromium/macOS cache caused it.
The occasional WindowServer thumbnail-sized bounds change is likewise treated as
an identity change, never ignored to obtain a success.

The live workflow now explicitly focuses the pinned Discord window **before
navigation**, uses fresh observations and two stable verification samples, and
keeps literal typing/Return bound to the exact background receiver. This avoids
treating global-key dispatch or an AXValue-only draft as successful delivery.
Verification itself remains read-only and never steals focus or retries a send.
A real receiver change still stops the operation safely.

Regression tests cover empty versus failed inventories, exact receiver mismatch,
initial versus continuation frame checks, observation timeout diagnostics, and
remaining AX deadline budgets. Repeated sending results and the precise common
starting conditions are recorded in the benchmark README.

## Historical foreground post-unlock comparison

Two post-unlock cohorts exposed real foreground changes, distinct from the
observation-timeout misclassification fixed above. Native AX/Workspace focus
monitoring recorded the Codex/ChatGPT app taking foreground during all four
failed attempts in the monitored cohort; Discord became off screen. Other
attempts succeeded. The activation initiator is not established, and the data
does not justify blaming user input or a specific tool component.

To avoid a possible observer effect from extra diagnostic shell calls, the final
comparison runs all ten trials in one execution cell, with no further shell or
CUA calls until completion. A read-only monitor records the same target and
geometry throughout all 1,327 sampled observations. Both versions then achieve
5/5 successful sends. CUA independently confirms all ten final messages and an
empty composer. Earlier 1/5 versus 0/5 and 3/5 versus 3/5 cohorts remain in the
report; no failed attempts are removed from their cohort success rates.

This validates the repaired workflow under a stable foreground condition. It
does not claim to prevent another application from taking focus. Exact target
identity checks continue to stop input when that condition changes.

## Remaining background focus: AXPress does not establish an editor receiver

The later same-Space reproduction separates native application focus from global
foreground focus. Finder remained frontmost with the same system keyboard receiver.
The published fork could navigate Discord, but AXPress on its composer left the
application's AXFocusedUIElement absent (`noValue`, -25212). CUA clicking only that
composer established AXTextArea as Discord's native receiver without activating
Discord. This localizes the remaining defect to click delivery semantics rather
than requiring the user to keep Discord foreground.

The repair prefers writable AXFocused for enabled text-entry roles when value
delivery is allowed, even if AXPress is advertised. An accessibility-value opt-out
continues to use AXPress. Exact target validation is retained, no global pointer
events or foreground fallback are added, and uncertain input is never replayed.
The pilot then verified a complete background send. New policy regressions for
both semantic and positional clicks pass with the surrounding driver tests.

The final background cohort completed 2/5 upstream versus 5/5 repaired sends,
with successful medians 16.121 s versus 11.117 s. All ten trials preserved the
monitored workspace. The three upstream failures lost proof of the exact native
receiver during typing and stopped without blind retry. CUA independently read
back all seven sent messages and an empty composer. See the benchmark README for
raw trials, binary hashes, monitor changes and small-sample limits.

This validates an already-onscreen target behind Finder on the same regular
Space. A hidden/off-Space pilot still failed to verify navigation, so that scope
remains unresolved. It must not be repaired by stealing focus during normal user
work. The Electron AXManualAccessibility request was common preparation for both
versions; AXEnhancedUserInterface remained disabled. No private Discord contents
are retained in the diagnostic artifacts.

## Reproduce the read-only diagnostic

```sh
swiftc -swift-version 6 benchmarks/batch-state-diff/window-diagnostic.swift -o /tmp/peekaboo-window-diagnostic
/tmp/peekaboo-window-diagnostic CURRENT_DISCORD_PID
```

The diagnostic reports window identities and visibility/minimization flags, not
message histories. The live sending benchmark is separate and requires explicit
recipient/text arguments; see `benchmarks/batch-state-diff/discord.py`.
