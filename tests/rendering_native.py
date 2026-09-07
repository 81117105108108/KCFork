"""Compile and execute the actual native batching functions with a fake GPU API.

Run in a C++20 compiler environment: python tests/rendering_native.py
Set CXX to cl, clang++, or g++. No SDK, network, or graphics device is needed.
This is a CPU logic regression test, not a full Filament build or GPU test.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile


def function(source: str, signature: str) -> str:
    """Extract one complete function; these functions have no braced strings."""
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
        cursor += 1
    return source[start:cursor]


PRELUDE = r"""
#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#define KINE_API
namespace math {
struct float3 { float x{}, y{}, z{}; };
float3 operator+(float3 a, float3 b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
float3 operator-(float3 a, float3 b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
float3 operator*(float3 a, float s) { return {a.x*s,a.y*s,a.z*s}; }
struct float4 { float x{}, y{}, z{}, w{}; };
struct mat4f {
    std::array<float4, 4> cols;
    mat4f(float4 a={1,0,0,0}, float4 b={0,1,0,0},
          float4 c={0,0,1,0}, float4 d={0,0,0,1}) : cols{a,b,c,d} {}
};
}
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
struct Box {
    math::float3 center, halfExtent;
    void unionSelf(const Box& b) {
        auto lo = center-halfExtent, hi = center+halfExtent;
        auto blo = b.center-b.halfExtent, bhi = b.center+b.halfExtent;
        lo={std::min(lo.x,blo.x),std::min(lo.y,blo.y),std::min(lo.z,blo.z)};
        hi={std::max(hi.x,bhi.x),std::max(hi.y,bhi.y),std::max(hi.z,bhi.z)};
        center=(lo+hi)*0.5f; halfExtent=(hi-lo)*0.5f;
    }
};
Box rigidTransform(Box b, const math::mat4f& m) {
    const auto& c=m.cols;
    return {{c[0].x*b.center.x+c[1].x*b.center.y+c[2].x*b.center.z+c[3].x,
             c[0].y*b.center.x+c[1].y*b.center.y+c[2].y*b.center.z+c[3].y,
             c[0].z*b.center.x+c[1].z*b.center.y+c[2].z*b.center.z+c[3].z},
            {std::abs(c[0].x)*b.halfExtent.x+std::abs(c[1].x)*b.halfExtent.y+std::abs(c[2].x)*b.halfExtent.z,
             std::abs(c[0].y)*b.halfExtent.x+std::abs(c[1].y)*b.halfExtent.y+std::abs(c[2].y)*b.halfExtent.z,
             std::abs(c[0].z)*b.halfExtent.x+std::abs(c[1].z)*b.halfExtent.y+std::abs(c[2].z)*b.halfExtent.z}};
}
struct KineVertex { float px,py,pz,nx,ny,nz,u,v; };
struct KineMesh {
    Box localBounds{{0,0,0},{1,2,3}};
    std::vector<KineVertex> vertices;
    std::vector<uint16_t> indices;
    uint32_t indexCount=0;
};
struct InstanceBuffer {
    std::vector<std::array<size_t,2>> writes;
    void setLocalTransforms(const math::mat4f*, size_t count, size_t offset) { writes.push_back({count,offset}); }
};
struct RenderableManager {
    struct Instance { size_t id; bool isValid() const { return true; } };
    std::unordered_map<size_t,Box> bounds;
    std::unordered_map<size_t,size_t> updates;
    Instance getInstance(size_t entity) { return {entity}; }
    void setAxisAlignedBoundingBox(Instance i, const Box& b) { bounds[i.id]=b; ++updates[i.id]; }
};
struct Engine {
    size_t maxInstances=4;
    RenderableManager manager;
    size_t getMaxAutomaticInstances() { return maxInstances; }
    RenderableManager& getRenderableManager() { return manager; }
};
struct KineBatchKey {
    KineMesh* mesh=nullptr;
    bool operator==(const KineBatchKey& b) const { return mesh==b.mesh; }
};
struct KineBatchKeyHash { size_t operator()(const KineBatchKey& k) const { return std::hash<void*>{}(k.mesh); } };
struct KineBuiltBatch { size_t entity=0; InstanceBuffer* instanceBuffer=nullptr; size_t instanceCount=0; };
struct KinePersistentBatch { uint64_t lastUsedFrame=0; };
struct KinePendingBatch { uint64_t lastQueuedFrame=0; };
struct KineRetainedListState { uint64_t version=0; bool initialized=false; std::vector<KineBatchKey> keys; };
struct KineFilamentContext {
    Engine* engine=nullptr;
    uint64_t batchFrame=0;
    std::unordered_map<uint64_t,KineRetainedListState> retainedLists;
    std::unordered_map<KineBatchKey,KinePersistentBatch,KineBatchKeyHash> builtBatches;
    std::unordered_map<KineBatchKey,KinePendingBatch,KineBatchKeyHash> pendingBatches;
};
struct KineFilamentInstanceBatch {
    KineFilamentContext* ctx=nullptr;
    KineBatchKey key;
    std::vector<math::mat4f> transforms;
    std::vector<uint32_t> visibleIndices;
    std::vector<math::mat4f> visibleTransforms;
    std::vector<int32_t> visibleSlots;
    std::vector<KineBuiltBatch> chunks;
    std::vector<uint32_t> dirtyIndices;
};
int visibilityRebuilds=0;
bool kine_rebuild_instance_batch(KineFilamentInstanceBatch*) { ++visibilityRebuilds; return true; }
struct KineFilamentShader {};
struct KineFilamentDrawItem {
    KineMesh* mesh=nullptr; int materialKind=0;
    float r=0,g=0,b=0,param1=0,param2=0,param3=0,transmission=0;
    float transform[16]{};
    uint32_t flags=0; void* tex=nullptr;
    KineFilamentShader* shader=nullptr;
};
constexpr uint32_t KINE_FILAMENT_DRAW_CAST_SHADOWS=1, KINE_FILAMENT_DRAW_RECEIVE_SHADOWS=2, KINE_FILAMENT_DRAW_CULLING=4;
KineFilamentShader* queuedShader=nullptr;
void kine_queue_mesh(KineFilamentContext* ctx,KineMesh* mesh,int,float,float,float,float,float,float,float,
    const float*,bool,bool,bool,void*,KineFilamentShader* shader,uint64_t,float,KineBatchKey* key) {
    queuedShader=shader;
    key->mesh=mesh; ctx->pendingBatches[*key].lastQueuedFrame=ctx->batchFrame;
}
"""

TESTS = r"""
int main() {
    auto* cylinder=buildCylinder();
    assert(cylinder->vertices.size()==100 && cylinder->indices.size()==288);
    delete cylinder;
    auto* wedge=buildWedge();
    assert(wedge->vertices.size()==24 && wedge->indices.size()==24);
    delete wedge;
    Engine engine;
    KineFilamentContext ctx; ctx.engine=&engine;
    KineMesh mesh;
    InstanceBuffer first, second;
    KineFilamentInstanceBatch batch;
    batch.ctx=&ctx; batch.key.mesh=&mesh; batch.transforms.resize(8);
    batch.visibleIndices={0,1,2,3,4,5,6,7};
    batch.visibleTransforms=batch.transforms;
    batch.visibleSlots={0,1,2,3,4,5,6,7};
    batch.chunks={{0,&first,4},{1,&second,4}};
    const uint32_t indices[]={6,0,2,2,999};
    float matrices[5*16]{};
    for (size_t i=0;i<5;++i) {
        matrices[i*16]=2; matrices[i*16+5]=3; matrices[i*16+10]=4; matrices[i*16+15]=1;
        matrices[i*16+3]=float(i+1)*1000;
    }
    Kine_Filament_UpdateInstanceTransforms(&batch,indices,matrices,5);
    assert(batch.transforms[2].cols[3].x==4000); // duplicate index: last update wins
    assert(first.writes.size()==2 && second.writes.size()==1);
    assert(engine.manager.updates[0]==1 && engine.manager.updates[1]==1);
    const auto b0=engine.manager.bounds[0], b1=engine.manager.bounds[1];
    assert(b0.center.x+b0.halfExtent.x>=4002); // beyond the original 64-unit cell
    assert(b0.center.x-b0.halfExtent.x<=-1); // unchanged instances retained
    assert(b1.center.x+b1.halfExtent.x>=1002);
    assert(b1.center.z+b1.halfExtent.z>=12); // nonuniform scale included
    assert(b0.center.x+b0.halfExtent.x<5000); // out-of-range update ignored
    Kine_Filament_UpdateInstanceTransforms(nullptr,indices,matrices,5);
    Kine_Filament_UpdateInstanceTransforms(&batch,nullptr,matrices,5);
    Kine_Filament_UpdateInstanceTransforms(&batch,indices,matrices,0);
    assert(engine.manager.updates[0]==1);
    const uint32_t contiguous[]={0,1,2,3,4};
    first.writes.clear(); second.writes.clear();
    Kine_Filament_UpdateInstanceTransforms(&batch,contiguous,matrices,5);
    assert(first.writes.size()==1 && first.writes[0][0]==4);
    assert(second.writes.size()==1 && second.writes[0][0]==1);
    assert(engine.manager.updates[0]==2 && engine.manager.updates[1]==2);
    const uint32_t visible[]={7,2,2,999};
    Kine_Filament_SetInstanceBatchVisibility(&batch,visible,4);
    assert((batch.visibleIndices==std::vector<uint32_t>{2,7}));
    assert(visibilityRebuilds==1);
    const uint32_t sameVisible[]={7,2};
    Kine_Filament_SetInstanceBatchVisibility(&batch,sameVisible,2);
    assert(visibilityRebuilds==1);
    Kine_Filament_SetInstanceBatchVisibility(&batch,nullptr,0);
    assert(batch.visibleIndices.empty() && visibilityRebuilds==2);
    // Retained data recovers if a failed compositor frame prevented GPU build.
    ctx.batchFrame=9;
    KineFilamentDrawItem item; item.mesh=&mesh;
    Kine_Filament_DrawMeshListVersioned(&ctx,&item,1,7,1);
    assert(queuedShader==nullptr);
    ctx.batchFrame=10;
    Kine_Filament_DrawMeshListVersioned(&ctx,nullptr,0,7,1);
    assert(ctx.pendingBatches[batch.key].lastQueuedFrame==10);
    ctx.builtBatches[batch.key]={10}; ctx.batchFrame=11;
    Kine_Filament_DrawMeshListVersioned(&ctx,nullptr,0,7,1);
    assert(ctx.builtBatches[batch.key].lastUsedFrame==11);
    assert(ctx.pendingBatches[batch.key].lastQueuedFrame==10); // no redundant upload
    KineFilamentShader shader;
    item.shader=&shader;
    Kine_Filament_DrawMeshListVersioned(&ctx,&item,1,7,2);
    assert(queuedShader==&shader);
    std::cout << "PASS native bounds, chunk coalescing, duplicate/invalid indices, visibility, retained recovery, shader forwarding\n";
}
"""


def main() -> None:
    root = Path(os.environ.get("KINE_RENDER_TEST_ROOT", Path(__file__).resolve().parents[1]))
    source = (root / "external/kine_render_shim/src/kine_filament_shim.cpp").read_text(encoding="utf-8")
    signatures = [
        "static KineMesh* buildCylinder(",
        "static KineMesh* buildWedge(",
        "static Box kine_compute_batch_bounds(",
        "static Box kine_compute_dynamic_batch_bounds(",
        "KINE_API void Kine_Filament_UpdateInstanceTransforms(",
        "KINE_API void Kine_Filament_SetInstanceBatchVisibility(",
        "KINE_API void Kine_Filament_DrawMeshListVersioned(",
    ]
    compiler = os.environ.get("CXX") or next((p for name in ("cl", "clang++", "g++") if (p := shutil.which(name))), None)
    if not compiler:
        raise SystemExit("C++ compiler missing: use a Visual Studio developer shell or set CXX")
    with tempfile.TemporaryDirectory(prefix="kinemium-render-tests-") as directory:
        work = Path(directory)
        cpp = work / "rendering_native.cpp"
        cpp.write_text(PRELUDE + "\n".join(function(source, s) for s in signatures) + TESTS, encoding="utf-8")
        binary = work / ("rendering_native.exe" if os.name == "nt" else "rendering_native")
        if Path(compiler).stem.lower() == "cl":
            command = [compiler, "/nologo", "/std:c++20", "/EHsc", "/W4", str(cpp), f"/Fe:{binary}"]
        else:
            command = [compiler, "-std=c++20", "-Wall", "-Wextra", str(cpp), "-o", str(binary)]
        subprocess.run(command, cwd=work, check=True, timeout=120)
        subprocess.run([str(binary)], cwd=work, check=True, timeout=30)


if __name__ == "__main__":
    main()
