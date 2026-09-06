# Kinemium Architectural Roadmap

Tracking file for the 7-phase roadmap. Status values: `PENDING` | `IN_PROGRESS` | `DONE` | `BLOCKED` | `PARTIAL`.

Legend for **Planned path** vs **Actual path**: roadmap targets predate the current tree. Where the
planned file does not exist, the actual implementation/integration point is listed instead.

| # | Phase | Status | Planned path | Actual path |
|---|-------|--------|--------------|-------------|
| 1 | Bulk physics FFI marshaling | DONE (Luau+header; native build pending CI) | `src/engine/physics/JoltBridge.luau`, `external/kine_jolt/` | `src/environment/game/services/JoltPhysicsService/JoltPhysicsService.luau`, `external/kine_jolt/include/jph_api.h`, `external/kine_jolt/src/jolt_wrapper.cpp`, `src/external/jolt/funcs.luau` |
| 2.1 | Instanced primitive pipeline | DONE | `src/services/KinemiumRaylib.luau`, `src/engine/rendering/BatchRenderer.luau` | Filament instance batches in `src/renderer/init.luau`, `filamentlib.luau`, `Workspace.luau`, and `kine_filament_shim.cpp` |
| 2.2 | Octree + frustum culling | DONE | `src/engine/spatial/Octree.luau`, `src/engine/rendering/Frustum.luau` | `src/environment/datatypes/Octree.luau`, `Frustum.luau`, `Workspace.luau`, native visible-index compaction |
| 3.1 | Kilang→Luau transpiler | PENDING | `src/kilang/Compiler.luau`, `src/kilang/Parser.luau` | `src/kilang/Transpiler.luau`, `src/kilang/superset/kilang.luau` |
| 3.2 | Sandbox capability isolation | PENDING | `src/engine/sandbox/SandboxEnvironment.luau` | `src/sandboxed/offline_bootstrap.luau`, `src/sandboxed/runner.luau` |
| 4.1 | HistoryService undo/redo | PENDING | `src/services/HistoryService.luau` | not found |
| 4.2 | Context menu + subcategorization | PENDING | `src/editor/components/ContextMenu.luau`, `ObjectMenu.luau` | not found |
| 5.1 | Transport abstraction | PENDING | `src/engine/network/Transport.luau` | `src/libs/KiNet/TCPServer.luau`, `TCPClient.luau` |
| 5.2 | Bit-packed delta replication | PENDING | `src/engine/network/Replicator.luau` | `src/environment/game/services/ReplicatorService/ReplicatorService.luau` |
| 6 | CSTMOD + Zstd serialization | PENDING | `src/engine/formats/CSTMOD.luau` | not found |
| 7.1 | Type defs + `--!strict` | PENDING | `k.d.luau`, `zune.d.luau` | both exist; strict not enforced repo-wide |
| 7.2 | Headless test runner + CI | PENDING | `tests/run_tests.luau`, `.github/workflows/ci.yml` | `tests/*.luau` (5 files, no runner), no CI workflow |

---

## Phase 1 — Bulk Physics Transform Marshaling over FFI — DONE (Luau + native source)

**Goal.** Eliminate per-body FFI (`GetPosition()`, `GetRotation()`). One flat buffer of active bodies
`[BodyID:u32, Px:f32, Py:f32, Pz:f32, Qx:f32, Qy:f32, Qz:f32, Qw:f32] * N` (32-byte stride), unpacked in
Luau with `buffer.readf32` in a batch pass.

**Shipped**
- `external/kine_jolt/include/jph_api.h:434` — `JPH_BodyInterface_GetBulkTransforms(ids, count, out, cap)` → `u32` written
- `external/kine_jolt/src/jolt_wrapper.cpp:1071` — impl, `GetPositionAndRotation` per body into rows, `memcpy`, null guards
- `src/external/jolt/funcs.luau:272,462` — FFI signature `{ptr,ptr,u32,ptr,u32}→u32` + export
- `JoltPhysicsService.luau` — `ensureBulkCapacity`, `bulkTransformToCFrame`, bulk-first sync loop,
  `buffer.readu32/readf32` unpack, velocity fetch only when transform moved, per-body fallback preserved

**Verification**
- Auditor PASS
- `JoltWrapper.dll` rebuild NOT yet run locally (Jolt fetched via CMake `FetchContent` → deferred to CI)
- Action: add `GetBulkTransforms` to the FFI symbol-validation list in CI (Phase 7.2)

**Known gaps**
- Bulk path writes positions as `f32` (was `f64`) — acceptable for rendering, verify for large worlds
- Culling of inactive bodies still happens on the Luau side; a native active-body query would remove
  the remaining `IsActive`-shaped work

---

## Phase 2.1 — Instanced Primitive Rendering Pipeline — DONE

**Goal.** Group instances by `(MeshType, MaterialShader, TextureID)`, upload contiguous matrix/color
buffers in one call per batch.

**Shipped**
- Persistent Filament instance batches with dense, contiguous transform storage and coalesced dirty updates.
- Cube, sphere, cylinder, and wedge native meshes; `Workspace` selects the correct mesh from `Part.Shape`.
- Batches share `(mesh, material shader, texture)` and also split on material-instance uniforms such as color,
  roughness, metallic, transparency, tiling, and shadow flags. This extra compatibility split is required because
  Filament applies those values per renderable, not per transform instance.
- FFI draw descriptors pack each 16-float matrix and RGB material values contiguously before native creation.

**Verification**
- `zune test tests/rendering.luau` → `Rendering regressions: 20 passed, 0 failed`
- `python tests/rendering_native.py` in an MSVC developer environment → native primitive, bounds,
  chunk-coalescing, visible-index, invalid-index, and retained-recovery checks passed

---

## Phase 2.2 — Loose Octree & Frustum Culling — DONE

**Goal.** Dynamic loose octree for `BasePart` AABBs + 6-plane camera frustum updated on `RenderStepped`,
culling before batch submission.

**Shipped**
- `src/environment/datatypes/Frustum.luau` NEW — `--!strict`
  - `Frustum.fromBasis(pos, fwd, up, right, fovYDeg, aspect, near, far)` → 6 inward-facing planes
  - `Frustum.fromCFrame(camCF, ...)` — `pcall`-wrapped, returns `nil` on malformed camera (fail-open)
  - `Frustum.TestAABB(frustum, center, halfSize)` — center+radius plane test
  - `Frustum.TestSphere(frustum, center, radius)`
- `tests/frustum.luau` NEW — 10 assertions, `zune test tests/frustum.luau` → `DONE frustum tests passed=10`
  (ahead visible, behind culled, right-edge culled, beyond-far culled, pre-near culled, straddling visible,
  grazing visible, sphere both directions, broad-phase bounds, `fromCFrame` rejects `nil`/`{}`)
- Frustums expose a conservative world AABB for octree broad-phase queries.
- `Workspace` inserts every renderable part into the loose octree, updates moving-part bounds, and keeps
  out-of-root objects in a fail-open overflow set.
- Each `Renderstep` queries the octree, runs the six-plane AABB test per candidate, and submits zero-based
  visible indices per material batch. Missing/malformed cameras remain fail-open.
- `Kine_Filament_SetInstanceBatchVisibility` compacts selected transforms into retained GPU instance buffers;
  an empty visible set removes the batch entities, so fully culled batches issue no draw.
- Loose-node queries use loose bounds during traversal, preventing false negatives near child boundaries.
- `Workspace.GetFrustumCullStats()` reports tested/culled groups and tested/visible/culled parts.

**Verification**
- `zune test tests/frustum.luau` → `DONE frustum tests passed=10`
- `zune test tests/octree.luau` → `DONE octree tests passed=6`
- `zune test tests/phase2_benchmark.luau` → 5,000-part octree + six-plane culling remains inside a 16.67 ms CPU frame budget
- Rendering and native regression commands from Phase 2.1 pass

---

## Phase 3.1 — Kilang→Luau Transpiler — IN PROGRESS

**Planned** `src/kilang/Compiler.luau`, `src/kilang/Parser.luau`.
**Actual** `src/kilang/Transpiler.luau`, `src/kilang/superset/kilang.luau`, `src/kilang/_worker.luau`.
Replace string/regex substitution with AST → Luau via `luau.compile()`, preserving line/column for diagnostics.

Worker prerequisite fixed: compile the transpiler's output, not the original Kilang
source. Catch compiler exceptions and return them with the request ID so a syntax
error does not terminate the worker. Regression check: `zune test tests/kilang_worker.luau`.
The test executes the real worker with a mock transport/transpiler and the real Zune
compiler; it covers transformed output, transpiler failure, compiler failure, empty
source, and recovery. It does not validate native thread transport or language syntax.
AST lowering and original-source diagnostic mapping remain outstanding; this is not
Phase 3 completion.

## Phase 3.2 — Sandbox Capability Isolation — IN PROGRESS

**Planned** `src/engine/sandbox/SandboxEnvironment.luau`.
**Actual** `src/sandboxed/offline_bootstrap.luau`, `src/sandboxed/runner.luau`, `src/sandboxed/blobloader.luau`.
Strip `debug`, `ffi`, `fs`, `process`, raw sockets; proxy `HttpService` with domain allowlist + timeout.

Implemented global isolation in `src/kilang/SandboxEnvironment.luau`, used by the
Kilang execution path for all non-Internals scripts. No host-global fallback is
installed. Dangerous runtime, environment-reflection, filesystem, process, dynamic
loading, and raw-network globals are removed, including values in caller bindings.
Standard-library tables are frozen copies; `os` exposes only clock/date/time/difftime.
String `require` is denied before invoking the supplied loader; ModuleScript table
requests still delegate to it. This intentionally disables host-path, `@kine/`, and
plugin-name string imports for non-Internals scripts. Trusted Internals execution
retains host access. Untrusted execution disables native code generation and
explicitly installs the isolated environment: the tested Zune native loader exposes
host globals despite its `env` option. Compilation/loading exceptions now complete the execution
result instead of leaving callers waiting forever.

Checks: `zune test tests/sandbox_environment.luau` and
`zune test tests/kilang_runtime.luau`.

**Not yet a complete security boundary:** supplied engine objects and ModuleScript
loaders are not capability-safe proxies. HTTP allowlisting/configuration, service
access restrictions, and preemption of non-yielding scripts remain outstanding.
Do not run hostile mods on the assumption that Phase 3.2 is finished.

## Phase 4.1 — HistoryService — PENDING

**Planned** `src/services/HistoryService.luau` — reversible undo/redo for property mutation, hierarchy,
create/delete; Ctrl+Z / Ctrl+Y. Not found in-tree; greenfield.

## Phase 4.2 — Context Menu & Object Subcategorization — PENDING

**Planned** `src/editor/components/ContextMenu.luau`, `ObjectMenu.luau` — floating menus, submenus,
keyboard nav, Insert Object catalog split into Geometry/Constraints/Logic/Interaction. Not found in-tree.

## Phase 5.1 — Transport Abstraction — PENDING

**Planned** `src/engine/network/Transport.luau` — reliable/unreliable UDP, TCP fallback, WebSockets,
heartbeat, auto-reconnect. **Actual** `src/libs/KiNet/TCPServer.luau` (length-prefix framing, 130 clients,
heartbeat 15s), `TCPClient.luau`. UDP/WS + unified interface missing.

## Phase 5.2 — Bit-Packed Delta Replication — PENDING

**Planned** `src/engine/network/Replicator.luau` — `[PacketType:u8][ServerTick:u32][InstanceId:u32][PropertyBitmask:u16][Payload...]`,
smallest-three quaternion `u32`. **Actual** `src/environment/game/services/ReplicatorService/ReplicatorService.luau`.

## Phase 6 — CSTMOD + Zstd — PENDING

**Planned** `src/engine/formats/CSTMOD.luau` — chunked binary (`CSTM` magic, String Table, Instance Hierarchy,
Property Table, Raw Vertex Data), Zstd + legacy uncompressed fallback. Not found in-tree.

## Phase 7.1 — Type Definitions & `--!strict` — PENDING

`k.d.luau` and `zune.d.luau` exist. Expose engine APIs/structs across both; enforce `--!strict` on all
engine scripts. New files created this roadmap pass are `--!strict`.

## Phase 7.2 — Headless Test Runner & CI — PENDING

**Planned** `tests/run_tests.luau` + `.github/workflows/ci.yml`.
**Actual** `tests/instance_lifecycle.luau`, `tests/physics_service.luau`, `tests/rendering.luau`,
`tests/resource_tracker.luau`, `tests/rendering_native.py`, plus `tests/frustum.luau` NEW.
No single runner, no CI workflow, no FFI symbol validation.
CI must: build `JoltWrapper` (CMake + Jolt `FetchContent`), run all `tests/*.luau` on Linux + Windows,
and validate exported FFI symbols incl. `JPH_BodyInterface_GetBulkTransforms`.

---

## Conventions used when extending this file

- Update the summary table **and** the phase section in the same edit.
- Keep `Planned path` verbatim from the roadmap; put reality under `Actual path`.
- Every `DONE` needs a verification line (command or test count).
- Every `BLOCKED` needs the blocker and the unblock condition.
- Do not delete completed phases — they document what shipped and what was skipped.
