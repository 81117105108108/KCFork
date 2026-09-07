# Kinemium Architectural Roadmap

## Latest local verification

- Windows/MSVC: `zune run tests/run_tests.luau` completed with **12 test files, 0 failed** after the integration repairs.
- Rendering now passes **21 cases**, including production-adapter camera-up forwarding (not just the renderer mock). Lifecycle passes 8; physics correctness passes 10; resource tracking passes 16.
- Native rendering harness compiles and passes extracted-function tests; this is not a full Filament/GPU build.
- Runner regression tests deliberately launch failing children and verify nonzero exit propagation. Their expected error output is not a suite failure.
- CI functional tests now precede artifact upload. Remote CI/Linux results remain unverified; these latest changes are local and uncommitted.
- Phase 1 runtime fixes now have production-sync and real Zune/Jolt DLL coverage; full-game and large-world validation remain separate.


Tracking file for the 7-phase roadmap. Status values: `PENDING` | `IN_PROGRESS` | `DONE` | `BLOCKED` | `PARTIAL`.

Legend for **Planned path** vs **Actual path**: roadmap targets predate the current tree. Where the
planned file does not exist, the actual implementation/integration point is listed instead.

| # | Phase | Status | Planned path | Actual path |
|---|-------|--------|--------------|-------------|
| 1 | Bulk physics FFI marshaling | DONE (local runtime tests; full-game smoke pending) | `src/engine/physics/JoltBridge.luau`, `external/kine_jolt/` | `src/environment/game/services/JoltPhysicsService/JoltPhysicsService.luau`, `external/kine_jolt/include/jph_api.h`, `external/kine_jolt/src/jolt_wrapper.cpp`, `src/external/jolt/funcs.luau`, `src/external/jolt/wrapper.luau` |
| 2.1 | Instanced primitive pipeline | DONE | `src/services/KinemiumRaylib.luau`, `src/engine/rendering/BatchRenderer.luau` | Filament instance batches in `src/renderer/init.luau`, `filamentlib.luau`, `Workspace.luau`, and `kine_filament_shim.cpp` |
| 2.2 | Octree + frustum culling | DONE | `src/engine/spatial/Octree.luau`, `src/engine/rendering/Frustum.luau` | `src/environment/datatypes/Octree.luau`, `Frustum.luau`, `Workspace.luau`, native visible-index compaction |
| 3.1 | Kilang→Luau transpiler | IN_PROGRESS | `src/kilang/Compiler.luau`, `src/kilang/Parser.luau` | `src/kilang/Transpiler.luau`, `src/kilang/superset/kilang.luau` |
| 3.2 | Sandbox capability isolation | IN_PROGRESS | `src/engine/sandbox/SandboxEnvironment.luau` | `src/kilang/SandboxEnvironment.luau`, `src/sandboxed/offline_bootstrap.luau`, `src/sandboxed/runner.luau` |
| 4.1 | HistoryService undo/redo | PENDING | `src/services/HistoryService.luau` | not found |
| 4.2 | Context menu + subcategorization | PENDING | `src/editor/components/ContextMenu.luau`, `ObjectMenu.luau` | not found |
| 5.1 | Transport abstraction | PENDING | `src/engine/network/Transport.luau` | `src/libs/KiNet/TCPServer.luau`, `TCPClient.luau` |
| 5.2 | Bit-packed delta replication | PENDING | `src/engine/network/Replicator.luau` | `src/environment/game/services/ReplicatorService/ReplicatorService.luau` |
| 6 | CSTMOD + Zstd serialization | PENDING | `src/engine/formats/CSTMOD.luau` | not found |
| 7.1 | Type defs + `--!strict` | PENDING | `k.d.luau`, `zune.d.luau` | both exist; strict not enforced repo-wide |
| — | Upstream sync | DONE (merge and fork restoration verified locally; remote CI unrun) | — | merged 3 `quadigen/Kinemium-Canary` commits; fork rendering fixes restored in working tree, including production-adapter camera-up forwarding |
| 7.2 | Headless test runner + CI | PARTIAL (local Windows pass; remote CI unrun) | `tests/run_tests.luau`, `.github/workflows/ci.yml` | `tests/run_tests.luau`, `.github/workflows/main.yml`, `tests/runner_regression.py`, `tests/verify_ffi_symbols.py` |

---

## Phase 1 — Bulk Physics Transform Marshaling over FFI — DONE (Local Runtime)

**Goal.** Eliminate per-body FFI (`GetPosition()`, `GetRotation()`). One flat buffer of active bodies
`[BodyID:u32, Px:f32, Py:f32, Pz:f32, Qx:f32, Qy:f32, Qz:f32, Qw:f32] * N` (32-byte stride), unpacked in
Luau in a batch pass.

**Implemented**
- Native bulk reads valid, live caller-selected IDs and compacts active bodies into exact 32-byte rows.
  Null/zero/sub-record capacity guards and whole-record bounds are retained; inactive IDs do not consume capacity.
  Call between updates without concurrent body mutation/destruction; this is not an arbitrary-ID validation API.
- `JoltPhysicsService.luau` preserves locally authoritative dynamic-body selection, maps compacted rows by BodyID,
  validates counts and row membership/duplicates before applying, and uses reusable geometrically grown `ffi.pointer` storage.
- One shared apply path synchronizes both velocities independently of transform differences. Active bulk rows do not
  re-fetch transforms. First-seen sleepers and observed sleep transitions fetch one final pose and publish zero velocities;
  subsequent sleeping syncs make no per-body native calls on the bulk path. `UpdatePart`'s helper call remains compatible.
- `funcs.luau` retains `{ptr,ptr,u32,ptr,u32}->u32`. `wrapper.luau` retries eager `ffi.dlopen` without only the optional
  bulk symbol for older libraries; missing required symbols still fail. Per-body sync remains the fallback.

**Verification (Windows, local)**
- `cmake --build C:\Users\Bubba\AppData\Local\Temp\joltbuild --config Release --target JoltWrapper` rebuilt the changed source successfully.
- `zune run tests/physics_bulk.luau C:\Users\Bubba\AppData\Local\Temp\joltbuild\Release\JoltWrapper.dll` exercises production
  decoder/helper/render-sync source with real Zune pointers and CFrame/Vector3 types, plus the actual newly built DLL.
  Coverage includes reordered/compacted IDs, quaternion normalization, velocity-only changes/stops, dirty flags,
  ownership selection, first-seen sleepers, sleep/wake, geometric reuse, invalid counts/rows, and fallback call counts.
- Native execution covers null/zero/sub-record capacity, output canaries, active compaction after a sleeping input,
  actual velocity reads/writes, and a real Jolt update-to-sleep transition. This is runtime evidence, not export lookup alone.
- Loader tests execute the production wrapper with real eager `dlopen`; missing optional/required symbols are induced
  through test definitions against the current DLL, not a separately archived older binary.
- `zune run tests/physics_service.luau`: 10 existing correctness cases pass. Without a DLL argument, the new focused
  test runs headless cases and explicitly skips native/loader coverage; CI must pass a built DLL to establish native coverage.
- Focused run: 7 groups passed, exit 0. Full `zune run tests/run_tests.luau` under Visual Studio's x64 developer
  environment: 12 files, 0 failed, exit 0. The ordinary-shell run first failed only because the native rendering test
  could not find its compiler; no renderer/CI test edits were needed for the successful rerun.

**Remaining Validation**
- Tests compile the complete service but execute bounded production source slices with injected dependencies, not a
  complete game/renderer session or network ownership handoff. Linux/remote CI and performance budgets remain unverified.
- The fixed ABI still narrows positions from `f64` to `f32`; large-world precision is unchanged and unverified.

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
- `zune test tests/rendering.luau` → `Rendering regressions: 21 passed, 0 failed`
- `python tests/rendering_native.py` in an MSVC developer environment → native primitive, bounds,
  chunk-coalescing, visible-index, invalid-index, and retained-recovery checks passed
- Current independent `zune run tests/rendering.luau`: 21 passed, 0 failed. These use graphics/FFI doubles.
  The parent MSVC-enabled full runner also passed the extracted native C++ tests, including shader forwarding.
- Full Filament GPU build and visual/runtime rendering are not tested. `DONE` here describes the implemented
  pipeline with headless evidence, not full GPU acceptance. Camera-up forwarding is covered by renderer and
  production-adapter regressions.

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
- Historical `zune test tests/phase2_benchmark.luau` result: 5,000-part octree + six-plane culling inside a
  16.67 ms CPU frame budget. Not rerun by current QA; benchmarks are excluded from the default runner.
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

## Phase 7.2 — Headless Test Runner & CI — PARTIAL

**Planned** `tests/run_tests.luau` + `.github/workflows/ci.yml`.
**Actual implementation in the working tree**
- `tests/run_tests.luau` discovers and sorts immediate `.luau`/`.py` test files, excluding itself,
  the explicit-path symbol validator, and benchmark-named files by default. `--benchmarks` includes benchmark files.
- Each test runs in a child process. Spawn/wait failures and nonzero exit status fail the suite; output text
  is not a success criterion. The runner continues after failed children, rejects empty discovery, and exits 1 on failure.
- `tests/runner_regression.py` exercises the real runner with temporary suites: empty discovery, exclusions,
  opt-in benchmarks, exit 7 despite PASS text, uncaught Luau errors, and continuation into a Python child.
- `.github/workflows/main.yml` sets up Python, validates `JPH_BodyInterface_GetBulkTransforms` after native
  build on Windows/macOS/Ubuntu, and runs the headless suite on Windows/Ubuntu with a ten-minute step timeout.
- Validator paths are `external/build/bin/KinemiumLibs.{dll,so,dylib}` for the corresponding OS. They match
  `external/CMakeLists.txt:171-177` (`PREFIX ""`, output directory `bin`) with the workflow's Ninja generator.
  Validation loads only the supplied resolved path, with no vendor/prebuilt fallback; load/export errors return 1.

**Verification**
- Parent full local Windows/MSVC-enabled run: `zune run tests/run_tests.luau` passed **11 test files, 0 failed**,
  including `rendering_native.py` and runner failure injection. This is supplied parent-run evidence, not a second full run.
- Independent QA reran `python tests/runner_regression.py` (PASS), `zune run tests/rendering.luau`
  (20 passed, 0 failed), `zune run tests/instance_lifecycle.luau` (8 passed), and both Kilang worker/runtime tests (PASS).
- Kilang tests contain real assertions: worker bytecode executes to 42, error responses and recovery are checked;
  runtime isolation, trusted access, syntax/runtime failure completion, and recovery are checked. They are not print-only smoke tests.
- Symbol validator: existing local Jolt DLL passed; nonexistent path and `C:\Windows\System32\kernel32.dll`
  (missing required export) both correctly failed with exit 1.
- `git diff --check` passed; Git emitted only LF/CRLF conversion warnings.
- Remote Linux/Windows CI has not run for these changes. No full Filament GPU build or visual runtime test was performed.

**Corrected regression history**
- The 17 rendering failures followed the previous `--theirs` merge resolution dropping fork fixes, not unrelated
  pre-existing failures. Comparing merge `405cff7` with its first parent confirms the removed fixes. Current changes
  restore those tested behaviors; all 20 rendering checks now pass, but the adapter camera gap below remains.
- Lifecycle failure was the test's custom mocked import table missing `@EnumMap` and its Enum dependencies.
  Those imports are now supplied. This was not a Zune `.luaurc` alias-resolution issue.
- The 1,000-body physics test now asserts transform/interpolation correctness. The 1.5 ms wall-clock budget is
  opt-in through `KINEMIUM_PHYSICS_BENCHMARK=1`, not a default correctness gate or a verified performance claim.
- Source diff review retains upstream 2D-only/Vulkan setup, input dispatch, camera perspective, viewport APIs,
  lights, post-process shaders, and the 128-byte draw descriptor with its shader pointer. This is source-level
  preservation evidence, not GPU execution coverage.

**Independent QA: FAIL for complete restoration/runtime acceptance**
- Important: `filamentlib.luau:399-413` still accepts only position/target and forwards fixed up `(0, 1, 0)`.
  `src/renderer/init.luau:782` now supplies camera up, but the adapter discards it. The camera test at
  `tests/rendering.luau:95-106` checks a mock adapter only. Restore optional-up forwarding and add a real-adapter
  packing assertion before claiming camera-roll restoration complete. Code intentionally unchanged by this docs-only review.
- CI ordering risk: artifact upload (`main.yml:239-243`) precedes functional tests (`245-248`). Failures make
  the job fail, but an artifact can already be published. Move tests before upload if artifacts must be test-gated.
- Phase 1 has local runtime coverage as listed above; full-game, large-world, and remote CI validation remain outstanding.
- Graph project/generation and index coverage could not be obtained through this session's callable MCP interface;
  review used direct diffs, bounded source reads, merge comparison, and executable checks instead. No exhaustive graph-audit claim.

---

## Conventions used when extending this file

- Update the summary table **and** the phase section in the same edit.
- Keep `Planned path` verbatim from the roadmap; put reality under `Actual path`.
- Every `DONE` needs a verification line (command or test count).
- Every `BLOCKED` needs the blocker and the unblock condition.
- Do not delete completed phases — they document what shipped and what was skipped.
