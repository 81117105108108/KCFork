# kine_render_shim

Minimal SDL3-backed C library scaffold meant to be loaded through Luau FFI.
The public `kine_render_shim` target no longer includes, fetches, or links
raylib.

## Build

```bash
mkdir build && cd build
cmake ..
cmake --build . --config Release
```

The compiled library lands in `build/bin/` (`kine_render_shim.dll` on Windows,
`.so` on Linux, `.dylib` on macOS). SDL3 is downloaded with CMake
`FetchContent` and linked by the shim.

## Extending

1. Declare the function in `include/kine_render_shim.h`, prefixed with
   `KINE_API` so it exports correctly on all platforms.
2. Implement it in `src/kine_render_shim.c`.
3. Rebuild.
4. Load `kine_render_shim.dll`/`.so`/`.dylib` from Luau FFI and call the
   exported `Kine_*` functions.

Small smoke-test function:

```lua
local ffi = require("ffi")
local lib = ffi.load("./build/bin/kine_render_shim.dll")
print(lib.Kine_GetVersion())
```

## Filament integration (`kine_filament_shim`)

The `kine_filament_shim` target bridges Google Filament into the Vulkan compositor
or an existing OpenGL host context. It keeps Filament C++ objects (`Engine`, `Scene`,
`View`, `Camera`, ...) behind opaque handles so Luau never touches C++ object
layouts.

Texture import uses `KineGLTextureInfo`:

```c
typedef struct KineGLTextureInfo {
    unsigned int id;
    int width;
    int height;
    int mipmaps;
    int format;
} KineGLTextureInfo;
```

That layout intentionally matches the existing engine texture descriptor, but
the API is not tied to a raylib header or CMake target.

Build with Filament enabled:

```bash
cmake .. -DKINE_WITH_FILAMENT=ON
cmake --build . --target kine_filament_shim --config Release
```

If `FILAMENT_DIR` is not provided, the CMake file downloads the matching
prebuilt Filament SDK and uses its `matc`/`resgen` tools to compile embedded
materials.

The standalone shim configuration defaults to `KINE_WITH_FILAMENT=ON` and
`KINE_FILAMENT_BACKEND=VULKAN`; Vulkan builds require the Vulkan SDK.
For an OpenGL compatibility build, explicitly select
`-DKINE_FILAMENT_BACKEND=OPENGL`. The OpenGL texture import example above applies
to that backend. Vulkan readback is disabled by default; enabling it is a debugging
option, not the normal presentation path.

## Engine build and regression tests

The full engine uses `external/CMakeLists.txt`, which combines the native
dependencies into `KinemiumLibs` and selects the unified Vulkan path. Populate
the repository's submodules before configuring:

```powershell
git submodule update --init --recursive
cmake -S external -B external/build -A x64
cmake --build external/build --config Release
```

These commands run from the repository root on Windows with Visual Studio and
the Vulkan SDK installed. On other platforms, omit `-A x64` and use the
appropriate CMake generator. Configuration downloads dependencies that are not
already available; the complete build includes Skia and other native libraries.
Use an existing configured build tree when one is available.

CPU regression tests can run without those dependencies:

```powershell
zune run tests/rendering.luau
python tests/rendering_native.py
```

The second command requires a C++20 compiler (a Visual Studio developer shell on
Windows, or `CXX` pointing to a configured compiler). It compiles actual batching
functions with graphics test doubles, so passing it does not establish that a
full Filament build or GPU rendering works. Changes to the native shim require
rebuilding the runtime native library; Luau-only changes do not update a DLL.

See [rendering architecture and validation](../../docs/rendering.md) for frame
ordering, camera behavior, draw-list versions, instance indices, FFI layout,
buffer ownership, profiling limits, and the visual integration checklist.
