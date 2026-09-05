# Rendering architecture and maintenance

Kinemium's active renderer is `src/renderer/init.luau`. It schedules scene and UI
callbacks, submits geometry through Argon, and presents through either the Vulkan
compositor or the OpenGL compatibility path. Filament handles 3D shading, shadows,
materials, instancing, and post-processing; Skia handles UI drawing.

## Source map

| Layer | Files | Responsibility |
| --- | --- | --- |
| Frame orchestration | `src/renderer/init.luau` | Pools, hooks, camera, submission, profiling, composition |
| Mesh generation | `src/renderer/meshgen.luau` | Procedural vertices, indices, mesh uploads |
| Platform adapter | `src/modules/Argon/adapters/sdl3/lib.luau` | SDL events/windows, graphics contexts, compositor integration |
| Filament adapter | `src/modules/Argon/adapters/sdl3/filamentlib.luau` | FFI packing, retained streams, instance updates, camera, readback |
| Native 3D implementation | `external/kine_render_shim/src/kine_filament_shim.cpp` | Native resources, GPU batches, bounds, Filament rendering |
| Vulkan compositor | `external/kine_vulkan_compositor/` | Shared Vulkan presentation and Skia/Filament coordination |
| Native UI implementation | `external/kine_skia/` | Raster/GPU Skia drawing |
| Runtime events | `src/environment/game/services/RunService/RunService.luau` | Render bindings, simulation callbacks, rollback |
| Headless facade | `src/renderer/dummy.luau` | Separate nonvisual runtime implementation |

The headless facade is separate: changes described below apply to the active
renderer. Its compatibility stubs should not be mistaken for implemented GPU APIs.

## Frame ordering

1. Poll SDL events and apply a valid resize.
2. Begin the graphics frame and clear the UI surfaces.
3. Run renderer `Renderstep` hooks, then emit `PreRender` and `RenderStepped`.
4. Update the active camera and render the sorted 3D pools, mesh submissions,
   gizmos, and 3D hooks.
5. Draw the base UI and ask Filament to render the submitted scene.
6. Composite the 3D result and overlay UI, then present.
7. Emit `Heartbeat` and run `Afterstep` hooks.

Render callbacks now run **before** scene submission. Camera changes and replicated
interpolation therefore affect the current frame instead of the next frame.
Callbacks that need completed presentation should use `Afterstep`.
Render callbacks must not yield if their result must be visible in the same frame.

The camera submits position, target, and `CFrame:GetUpVector()` in one call.
This preserves roll and avoids forcing world-up or resetting the camera to a
hardcoded position each frame. Adapter callers may omit the up vector to retain
the world-up default `(0, 1, 0)`.

On OpenGL, layer order is base UI, the 3D texture, then overlay UI. The Vulkan
path draws its overlay on the compositor's current surface after the 3D pass.

## Pool ordering and mutation

`Pool.new(kind, callback, priority)` accepts `2d`, `3d`, `2da`, and `gizmo`.
Lower priorities render first; equal priorities preserve registration order.
IDs are monotonic and unique across the four pools within a renderer instance.
Treat IDs as opaque, renderer-local handles rather than bounded random numbers.

Sorted arrays are cached until registration, destruction, or a priority change.
An unchanged pool takes O(n) callback traversal without rebuilding wrapper tables
or sorting every frame. Rebuilding a changed pool costs O(n log n) time and O(n)
space. `SetPriority` includes the overlay pool.

Traversal uses a snapshot: registrations and priority changes during a traversal
take effect on its next traversal. Entries destroyed before their turn are
skipped even if they remain in the current snapshot. Mutate pools through their
public API so cache invalidation remains correct.

## Mesh submission

Individual `MeshPool.DrawMesh` descriptors are collected into contiguous draw
lists and passed through the same FFI packing code as `DrawMeshList`.
`Begin` and `End` callbacks form submission boundaries: preceding items are flushed
before a begin callback, and an item's submission is flushed before its end
callback. Wrapper callbacks take precedence over descriptor callbacks.
Callbacks bracket CPU submission, not completion of GPU execution.

Descriptors support a mesh handle, color, raw matrix or CFrame/scale, material
parameters, texture, and the following flags:

- `CastShadow`: enabled unless explicitly false.
- `ReceiveShadow`: enabled unless explicitly false; the legacy misspelling
  `RecieveShadow` remains supported. The correctly spelled property wins if both
  are supplied.
- `Culling`: enabled only when explicitly true.

Do not assume one descriptor equals one GPU draw: native batching groups compatible
material/mesh states and splits them at Filament's automatic-instancing limit.

### Retained lists

Supply a positive `streamId` and a caller-controlled `version` to reuse a draw list
without repacking it on every frame. Bump the version whenever its count, geometry,
transform, texture, flags, or material properties change. Submit a stream once per
frame; use distinct IDs for independent lists. Stream zero uses immediate submission.

The adapter translates caller versions into monotonically increasing native
revisions. After an omitted rendered frame, the adapter resubmits the full list
with a fresh native revision, even if the caller's version did not change. This
recovers native batches that were evicted while hidden. Mesh/texture destruction
and shader changes also invalidate the adapter cache. Empty lists can clear a
stream when submitted with a new caller version.

The native retained fast path requeues pending transforms when GPU batches are
missing, allowing recovery after a failed compositor preparation. Native pending
transforms currently age out after 120 frames; this retry is not a replacement for
the adapter's full resubmission after a submission gap or resource invalidation.

### Persistent instance updates

`CreateInstanceBatch` requires compatible descriptors in a dense array. If an
entry cannot be packed, creation returns nil rather than silently shifting later
indices. Callers should use their non-instanced fallback when creation fails.

`UpdateInstanceTransforms` uses **zero-based** indices. Fractional, negative,
nonfinite, and out-of-uint32-range indices are skipped in Luau; indices beyond the
actual batch size are skipped natively. Duplicate indices use the final supplied
transform. Sorted adjacent updates coalesce into uploads without crossing chunk
boundaries. Native dirty-index scratch storage is reused between updates.

Each touched chunk's culling box is recomputed once from **all** its instances,
including unchanged ones, after all CPU transforms have been updated. The bounds
retain the existing conservative 64-unit snapping. This prevents moving objects
and their shadows from disappearing outside their original bounding box.
For d dirty updates and t instances in touched chunks, update work is
O(d log d + t), with O(d) reusable scratch space. This is a correctness tradeoff:
accurate bounds require inspecting the touched chunks, not only dirty transforms.

## FFI layout and ownership

`KineFilamentDrawItem` is 120 bytes on the supported ABI. The adapter asserts this
size. Its transform begins at byte 16; material kind at 108 and flags at 112.
Transform data consists of four affine rows; the C++ shim explicitly gathers
those entries into Filament column vectors. Keep these layouts paired to avoid a
double transpose. Instance updates use the same transform convention.

Draw-list, index, transform, and readback buffers belong to their window.
Buffers grow geometrically; replacements are allocated and checked before the old
allocation is freed. Allocation failure raises an error while preserving the old
buffer for cleanup. Readback pointers are borrowed until resize, growth, or shutdown.

OpenGL readback is allocated lazily. Vulkan does not allocate a CPU readback buffer
through this adapter. At 3840 x 2160, avoiding one RGBA8 buffer saves at least
33,177,600 bytes (about 31.6 MiB), independently of other graphics allocations.
Multiple windows cannot overwrite or free one another's readback storage.

Shutdown releases draw/index/transform/readback buffers, the renderer's three
textures, and its owned raster surfaces. It must not destroy a borrowed Vulkan
compositor frame surface. Shutdown is idempotent. The existing renderer process-exit
behavior remains; the tests replace it with a recorder. Call shutdown explicitly:
weak cache keys alone do not release native allocations.

## Profiling and verification

`PerfStats` reports CPU durations such as `render3d_update_ms`, `call3d_ms`,
`filament_ms`, and compositor waits. `gui_roots` includes both UI layers, and
`Frametime` tracks the latest `Step` interval. `mesh_calls` and `batches_3d` remain
submission counters, not authoritative GPU draw-call counts. A smaller pool time
does not by itself establish a higher in-game FPS.

Run from the repository root:

```powershell
zune run tests/rendering.luau
```

This runs the production Luau modules against deterministic graphics/FFI doubles.
It covers event order, camera roll, pool ordering/mutation/ID collisions, batched
submissions and callback boundaries, compositing, retained versions, affine layout,
indices, buffer isolation, cleanup, and allocation failure.

Run the native CPU regression in a Visual Studio developer shell or a shell with
clang++/g++ available:

```powershell
python tests/rendering_native.py
```

Set `CXX` to the compiler executable if necessary. The test extracts and compiles
the actual native bounds, instance-update, and retained-list functions with a
minimal fake GPU API. It verifies chunk bounds/coalescing, scaled and translated
instances, duplicate and invalid indices, and retry of retained uploads. It does
not link Filament or verify driver behavior.

Optional CPU benchmark:

```powershell
$env:KINE_RENDER_BENCHMARK = '1'
zune run tests/rendering.luau
Remove-Item Env:KINE_RENDER_BENCHMARK
```

An observed development run over 100 passes with 10,000 unchanged callbacks took
about 1,103 ms before pool caching and 78 ms afterward. This isolated mocked test
is not an end-to-end GPU benchmark; timings vary by host and runtime.

The Luau regressions were also run against the original renderer and reproduced
the bugs. The original checkout lacks native DLLs, populated external dependencies,
and a Filament SDK/build cache. An offline CMake configuration recognized MSVC
successfully, then stopped because SDL3's dependency sources were not populated;
a complete native build and visual GPU run were not performed. Before release,
build the native libraries and run
these integration checks on both supported backends:

1. Roll the camera and look vertically; confirm stable scene orientation.
2. Move scaled instances across their original bounds and a camera/shadow frustum.
3. Hide/show a retained mesh list without changing its source version; repeat after
   shader replacement and repeated window resizing.
4. Confirm overlay controls remain above the 3D viewport, with transparent base UI.
5. Open, resize, and close windows repeatedly; inspect CPU/native memory and GPU
   validation output for leaks or invalid surface access.

See [native build instructions](../external/kine_render_shim/README.md).
