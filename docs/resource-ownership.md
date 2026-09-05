# Native resource ownership: Phase 1.1 foundation

## Status and integration gate

`src/engine/ffi/ResourceTracker.luau` supplies a strict, runtime-independent
registry. `tests/resource_tracker.luau` exercises its contracts and real Zune GC.
This is **not yet wired into Instance destruction, frame safe points, or native
allocation sites**. Existing native allocations are not protected by this module.
Phase 1.1 remains incomplete; subsequent roadmap phases must not start yet.

The inspected checkout uses SDL3/Filament and an existing signal-based destruction
lifecycle in `src/environment/class/Instance.luau`. The installed Zune reports
0.5.9 / Luau 0.700, not the directive's kv1.10.4+. `sourcemap.json` is empty.
Baseline analysis of Instance and its signal dependency already fails, including
nullable child arrays and unresolved task globals. Strict-mode analysis exposes
additional legacy inference errors. Do not equate passing the isolated registry
checks below with a passing engine-wide type gate.

## API

Require `src/engine/ffi/ResourceTracker` and use `.shared` for engine ownership.
`.new()` returns an isolated registry for tests or an independently owned backend.
Pointer exclusivity applies within a registry, not across separate registries.

- `Track(owner, ptr, destructor)` takes ownership. Owners must be tables; pointers
  may be userdata, buffers, or positive integral addresses up to 2^53-1. Native
  adapters must reject null userdata pointers and supply a canonical identity;
  different wrappers for the same address cannot be detected here. Numeric zero
  is rejected as a null address, not treated as an opaque backend handle.
- Repeating the same owner/pointer/destructor registration is idempotent. Another
  owner or destructor for the same identity is rejected before registry mutation.
- `Untrack(owner)` transfers responsibility for **all** of that owner's resources
  to the caller without freeing them. The caller must destroy or re-register them.
- `Collect(owner)` calls destructors once, in reverse registration order, then
  removes the records. Repeated collection is harmless. A live owner can acquire
  new resources afterward; an owner with a truthy raw `Destroyed` flag cannot.
- `Sweep()` collects owners already cleared by GC. It does not force GC.
- `CollectAll()` drains live and unreachable owners before backend shutdown.
  Ordering between different owners is unspecified; arrange backend dependencies
  explicitly rather than depending on table iteration order.

Native values use `any` only at the opaque FFI boundary. Owner tables, records,
registry methods, and destructor signatures have explicit exported types.

## GC and failure contracts

Luau does not support script `__gc` finalizers or ephemeron tables; see
[Luau compatibility](https://luau.org/compatibility/). A weak-key owner map alone
would discard the only destructor reference when the owner disappears. This
registry retains resource groups separately and keeps only a weak owner reference
inside each group. Destructors and pointer wrappers must not capture or otherwise
retain their owner. Such a reference prevents collection; explicit `Collect`
still works.

Destructors run in a coroutine on the calling native thread. A yielding destructor
is closed and reported as a failure so it cannot strand the registry in its busy
state. Destructors must not schedule asynchronous work. They must retain any native
library/allocator context needed until cleanup. Do not combine tracker ownership
with an existing manual destructor or native auto-finalizer for the same resource.
Do not expose the shared registry to untrusted scripts.

Cleanup detaches selected groups before calling destructors. Recursive collection
of those owners is harmless. Registration, ownership transfer, and nested cleanup
of other owners during destruction are rejected. Destructor failures are collected
while remaining destructors run, then reported as one error. Failed calls are not
retried because they may have already freed their pointer. This guarantees at-most-
once invocation, **not successful release after a native failure**.

Integration must call `Collect` even if an Instance callback throws, without
freeing resources before callbacks that still use them. GC sweeping belongs at a
main-thread safe point with the backend alive; GPU resources must be drained before
device shutdown. A timer or a fake `__gc` metamethod is not a substitute. Neither
automatic sweeping nor an engine shutdown hook is installed by this foundation.

## Cost and verification

`Track` is O(1) expected/amortized, including duplicate registration. `Collect`
and `Untrack` are O(resources for owner). `Sweep` is O(active owners + released
resources); `CollectAll` is O(owners + resources). Storage is O(owners + resources).

From the repository root with the official Luau 0.700 analyzer on PATH:

```sh
luau-analyze src/engine/ffi/ResourceTracker.luau tests/resource_tracker.luau
zune run tests/resource_tracker.luau
zune run tests/rendering.luau
git diff --check
```

The test suite uses synthetic addresses/buffers and real weak-table GC, not real
native destructors or a GPU. Its runtime global is accessed through `getfenv` to
avoid injecting an untyped Zune global into standalone Luau analysis; the analyzer
reports that access as a deprecation warning, not a type error.
