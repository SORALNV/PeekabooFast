---
summary: 'Bounded MCP batches, explicit verification, and retained AX snapshot differences.'
read_when:
  - 'Reducing MCP round trips without bypassing execution authority'
  - 'Comparing retained Accessibility snapshots'
---

# Batches and AX state differences

`execute_steps` dispatches 1–64 calls sequentially. Each child uses
`MCPToolContext.execute`, retaining permission checks, target validation, execution
lanes, and snapshot invalidation. The batch is not a transaction: other sessions
can interleave between calls, and completed actions are not rolled back.

Only tools exposed in the same catalog selection can be called. Allow/deny lists
and input strategy filtering also apply to nested calls. Recursive batches,
`agent`, and `shell` are excluded. There is no JavaScript runtime or workflow DSL.

```json
{
  "steps": [
    {"tool": "inspect_ui", "arguments": {"app_target": "TextEdit"}},
    {"tool": "sleep", "arguments": {"duration": 100}},
    {"tool": "inspect_ui", "arguments": {"app_target": "TextEdit"}}
  ]
}
```

Use label queries with fresh observations between UI changes. An element ID is
valid only for the snapshot from which it was obtained. A batch never replaces a
stale ID with a later ID. Use `snapshot_from_step` to explicitly copy `snapshot_id` from a successful earlier
`inspect_ui` or `see` result into the child's `snapshot` argument. Indices are
zero-based. Forward references, non-observation sources, unsupported destination
arguments, and supplying both `arguments.snapshot` and a reference are refused
before the plan starts. Missing observation IDs stop before dependent input.
All normal ownership, exact-window, freshness, and execution-policy checks still
apply. This does not make an invalidated snapshot fresh again.

```json
{
  "steps": [
    {"tool": "inspect_ui", "arguments": {"app_target": "TextEdit", "window_id": 5678}},
    {"tool": "type", "arguments": {"text": "Example"}, "snapshot_from_step": 0}
  ]
}
```

Replace the example window ID with a current one. A fresh observation between
mutations is still required when the previous snapshot has been invalidated.
Other arguments, including element IDs, remain literal; there is no general
result interpolation or script execution.

## Explicit verification

A step can include `verify`, containing the normal `verify_state` arguments:

```json
{
  "steps": [{
    "tool": "click",
    "arguments": {"query": "Submit"},
    "verify": {
      "pid": 1234,
      "window_id": 5678,
      "predicates": [{
        "kind": "element_exists",
        "selector": {"label": "Ready", "role": "AXStaticText"},
        "expected": true
      }]
    }
  }]
}
```

Replace these example PID/window IDs with current IDs. Verification must return
`status=satisfied`; `unknown` and `unsatisfied` stop the batch even when the verifier
has no transport/tool error. A `dispatched_unverified` result can continue only
with explicit successful verification pinned to the dispatch's PID, process
generation, and window. Generic errors and targetless global actions stop. The
original response, canonical outcome metadata, and verifier response remain in
the result. Verification proves the requested predicates, not causation or every
possible side effect of the action. Each verification is an additional local tool
call, so 64 steps can dispatch up to 128 calls.

The response has `results`, `completed`, `total`, and `stopped_on_error`.
`completed` counts attempted steps, including a failing final step. Each result
preserves the original `is_error`, content, structured content, and metadata;
`step_failed` indicates whether explicit verification resolved an unverified
outcome. Cancellation propagates without retrying the action. On failure, inspect
the completed results and current UI before deciding whether to retry.

## Retained snapshot comparison

`get_state_diff` accepts `before_snapshot` and `after_snapshot`. Both must be
distinct retained AX snapshots belonging to the current owner and recorded for
the same process generation and explicit window. Take separate `inspect_ui`
observations and copy their returned snapshot IDs. Reusing one snapshot ID
would overwrite its history and is refused as a comparison.

The response contains `added`, `removed`, `changed` (before/after rows), and
`unchangedCount`. Only unique `(AX role, AXIdentifier)` pairs are matched. Local
IDs are ignored for equality; ambiguous or unidentified nodes are conservatively
reported as removed/added. Consequently apps exposing few AXIdentifiers may see
little reduction. Both observation truncation flags are returned in metadata:
these are differences of observed tables, not proof that the whole app was read.
No old snapshot or element ID becomes valid for mutation through this API.

This call does not capture a new AX tree or screenshot and does not automatically
shorten AX capture latency. See `benchmarks/batch-state-diff` for reproducible
transport and payload measurements; they exclude LLM inference and network time.
