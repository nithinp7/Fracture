#include <Misc/Sampling.glsl>
#include <Misc/Input.glsl>

#extension GL_KHR_shader_subgroup_arithmetic : enable
#extension GL_KHR_shader_subgroup_ballot : enable
#extension GL_KHR_shader_subgroup_vote : enable

uvec2 seed;

// #define JITTER_COVERAGE
// #define ENABLE_DDA_CACHE
#include "HDDA.glsl"
#include "Bitfield.glsl"

// #define DISABLE_CACHED_LIGHTING
#include "Lighting.glsl"

vec3 getCellColor(ivec3 coord) {
  uvec2 meshletSeed = uvec2(coord.x ^ coord.z, coord.x ^ coord.y);
  return randVec3(meshletSeed);
}

vec3 transformToGrid(vec3 pos) {
  pos.y *= -1.0;
  pos *= 0.4;
  return pos;
}

vec3 computeDir(vec2 uv) {
	vec2 d = uv * 2.0 - 1.0;

	vec4 target = camera.inverseProjection * vec4(d, 1.0.xx);
	return normalize((camera.inverseView * vec4(normalize(target.xyz), 0)).xyz);
}

float getUploadTexel(uvec3 texelId) {
    uint texelIdx = texelId.z * SLICE_WIDTH * SLICE_HEIGHT + SLICE_WIDTH * texelId.y + texelId.x;

#if BYTES_PER_PIXEL == 1
    uint val = batchUploadBuffer(uniforms.frameCount&1)[texelIdx >> 2];
    val >>= 8 * ((texelIdx) & 3);
    val &= 0xFF;
#elif BYTES_PER_PIXEL == 2
    uint val = batchUploadBuffer(uniforms.frameCount&1)[texelIdx >> 1];
    val >>= 16 * ((texelIdx) & 1); 
    val &= 0xFFFF;
#else
    uint val = batchUploadBuffer(uniforms.frameCount&1)[texelIdx];
#endif

  float f = float(val) - float(CUTOFF_LO);
  f /= float(CUTOFF_HI - CUTOFF_LO);
  
  return f;
}

#ifdef IS_COMP_SHADER
uint allocateBlock() {
  uint offset = atomicAdd(blockAllocator[0].allocatedSlots, 1);
  if (offset >= L0_NUM_BLOCKS) {
    blockAllocator[0].failed = 1;
    return ~0;
  }
  return offset;
}

void CS_UploadVoxels() {
  uint tid = gl_SubgroupInvocationID;
  uint sliceOffset = push0;

  uint outVec = 0;
  bool bAnySet = false;

  uvec3 tileId = gl_WorkGroupID .xyz;
  if (tileId.x >= CELLS_WIDTH/8 || tileId.y >= CELLS_HEIGHT/8 ||
      tileId.x >= SLICE_WIDTH/8 || tileId.y >= SLICE_HEIGHT/8) {
    return;
  }

  uvec3 globalIdStart = 8 * tileId + uvec3(0, 0, sliceOffset);
  for (uint dwordIdx=0; dwordIdx<16; dwordIdx++)
  {
    uint threadBitIdx = (dwordIdx << 5) | tid;
    uvec3 localId = getLocalId(threadBitIdx);
    uvec3 globalId = globalIdStart + localId;
    uvec3 texelId = uvec3(globalId.xy, localId.z + 8 * tileId.z);
    float f = getUploadTexel(texelId);

    if (f < 0.0 || f > 1.0) {
      f = 0.0;
    }

    bool bDensity = f > 0.0;
    uint dword = subgroupBallot(bDensity).x;
    bAnySet = bAnySet || (dword != 0);
    if (dwordIdx == tid)
      outVec = dword;
  }
  
  bAnySet = subgroupBroadcastFirst(bAnySet);
  if (tid == 0 && bAnySet) {
    setParentsAtomic(globalIdStart);
  }

  VoxelAddr addr = constructVoxelAddr(0, globalIdStart);
#if ENABLE_SPARSE_L0
  if (!bAnySet)
    return;

  uint offset = ~0;
  if (tid == 0) {
    uint slot = hashCoords(ivec3(globalIdStart >> 3))%SPARSE_L0_SLOTS;
    uint prevValue = ~0;
    for (int attempt=0; attempt<SPARSE_L0_ALLOC_ATTEMPTS; attempt++) {
      prevValue = atomicCompSwap(blockOffsets[2*slot], 0, addr.blockIdx);
      if (prevValue == 0) {
        // found a free slot
        offset = allocateBlock();
        blockOffsets[2*slot+1] = offset;
        break;
      } else {
        // continue linear probing
        slot++;
      }
    }
  }

  addr.blockIdx = subgroupBroadcastFirst(offset);
  if (addr.blockIdx == ~0)
    return;
#endif
  if (tid < 16) {
    GetVoxelBlock(addr.blockIdx).bitfield[tid>>2][tid&3] = outVec;
  }
}

void CS_ClearBlocks() {
  uint blockIdx = gl_GlobalInvocationID.x + L0_NUM_BLOCKS;
  if (blockIdx >= TOTAL_NUM_BLOCKS)
    return;
  
  GetVoxelBlock(blockIdx).bitfield[0] = uvec4(0);
  GetVoxelBlock(blockIdx).bitfield[1] = uvec4(0);
  GetVoxelBlock(blockIdx).bitfield[2] = uvec4(0);
  GetVoxelBlock(blockIdx).bitfield[3] = uvec4(0);
}

void CS_ClearSpatialHash() {
  uint gid = gl_GlobalInvocationID.x;
  if (gid >= MAP_CLEAR_THREADS)
    return;

  for (uint i=0; i<4; i++)
    blockOffsets[4*gid+i] = 0;

  if (gid == 0) {
    blockAllocator[0].allocatedSlots = 0;
    blockAllocator[0].failed = 0;
  }
}

#define IsMeshletView() ((uniforms.inputMask & INPUT_BIT_SPACE) != 0)
#define IsDepthView() ((uniforms.inputMask & INPUT_BIT_F) != 0)
#define IsIterHeatView() ((uniforms.inputMask & INPUT_BIT_I) != 0)
#define IsHashCollisionView() ((uniforms.inputMask & INPUT_BIT_H) != 0)

bool IsDebugRenderActive() {
  return IsMeshletView() || IsDepthView() || IsIterHeatView() || IsHashCollisionView();
}

vec3 debugColor(float t, ivec3 globalId, int iter) {
  vec3 color = 0.0.xxx;
  if (IsMeshletView()) {
    color = 2.0 * getCellColor(globalId);
  } else if (IsDepthView()) {
    color = fract(t * 0.01).xxx;
  } else if (IsIterHeatView()) {
    color = (float(iter)/ITERS).xxx;
  } else /*if (IsHashCollisionView())*/ {
    VoxelAddr addr = constructVoxelAddr(0, globalId);
    uint slot = hashCoords(globalId>>3)%SPARSE_L0_SLOTS;
    bool bFound = false;
    for (uint attempt=0; attempt<SPARSE_L0_ALLOC_ATTEMPTS; attempt++) {
      if (blockOffsets[2*slot] == addr.blockIdx) {
        bFound = true;
        addr.blockIdx = blockOffsets[2*slot+1];
        break;
      } else {
        slot++;
      }
    }
    color = (bFound && addr.blockIdx != ~0) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
  }
  return color;
}

bool shouldClearTemporalBlend() {
  return ACCUMULATE == ((uniforms.inputMask & INPUT_BIT_C) != 0) || IsDebugRenderActive();
}

vec3 raymarch(vec3 startPos, vec3 dir, bool bDebugRender) {
  vec3 Li = 0.0.xxx;
  vec3 throughput = 1.0.xxx;

  {
    // HDDA raymarcher
    ivec3 crossSectionLo = ivec3(X_LO, Y_LO, Z_LO);
    ivec3 crossSectionHi = ivec3(X_HI, Y_HI, Z_HI);

    // TODO should also have iter-cutoffs
    float lodCutoffs[NUM_LEVELS] = { 1.0, 5.0, 24.0, 1000. };
    float throughputCutoffs[NUM_LEVELS] = {THR_CUT0, THR_CUT1, THR_CUT2, THR_CUT3 };
    // uint iterCutoffs[NUM_LEVELS] = { 0.0, 10.0, 100.0, 200.0 };

    uint lodClamp = 0;

    DDA dda = createDDA(startPos, dir, DDA_LEVEL);
    uint stepAxis = 0;
    float stepDt = 0.0;
    float prevDdaT = 0.0;
    // TODO - standardize lod-scale jitter...
    // if (LOD_JITTER >= 0.0)
    //   prevDdaT += LOD_JITTER * 100*rng(seed);
    for (int iter=0; iter<ITERS; iter++) {
      float t = prevDdaT + dda.globalT;
      if (LOD_CUTOFFS && t > lodCutoffs[lodClamp]*LOD_SCALE*1000 && lodClamp < NUM_LEVELS)
        lodClamp++;
      float tsum = dot(throughput, 1.0.xxx);
      if (THR_CUTOFFS && tsum < throughputCutoffs[lodClamp])
        lodClamp++;
      if (lodClamp >= NUM_LEVELS) {
        // throughput = 0.0.xxx;
        break;
      }
      // TODO impl cross sectional view properly, this approach screws up the HDDA raymarching
      bool bCulled = false;//dda.level == 0 && (any(lessThan(dda.coord, crossSectionLo)) || any(greaterThan(dda.coord, crossSectionHi)));
      ivec3 globalId = dda.coord >> (BR_FACTOR_LOG2 * dda.level);
      if (!bCulled && getBit(dda.level, globalId)) {
        bool bHit = false;
        vec3 pos = getCurrentPos(dda);
        if (dda.level <= lodClamp) {
          bHit = true;
        } else if (STEP_DOWN) {
          prevDdaT += dda.globalT;
          vec3 eps = 0.0.xxx;
          eps[stepAxis] = dda.sn[stepAxis] * 0.001;
          dda = createDDA(pos + eps, dir, dda.level-1);
          // if (dda.level == 0)
          // stepDt = stepDDA(dda, stepAxis);
        } else {
          bHit = true;
        }

        if (bHit) {
          if (bDebugRender) {
            float dist = length(pos - startPos);
            Li = debugColor(dist, globalId, iter);
            throughput = 0.0.xxx;
            break;
          } else {  
            if (accumulateLight(pos, dir, stepDt, Li, throughput, iter, dda.level))
              stepDt = stepDDA(dda, stepAxis);
            else
              break;
          }
        }
      } else if (
          STEP_UP &&
          dda.level < (NUM_LEVELS-1) &&
          !getBit(dda.level+1, globalId >> BR_FACTOR_LOG2)) {
        prevDdaT += dda.globalT;
        vec3 eps = 0.0.xxx;
        eps[stepAxis] = dda.sn[stepAxis] * 0.001;
        dda = createDDA(getCurrentPos(dda) + eps, dir, dda.level+1);
        // stepDt = stepDDA(dda, stepAxis); // ?? needed??
      } else {
        stepDt = stepDDA(dda, stepAxis);
      }
    }
  }

  float trSum = dot(1.0.xxx, throughput)/3.0;
  float deflection = clamp(1.0 - trSum, 0.0, 1.0);
  float rough = TR_ROUGH * deflection;
  vec3 trDir = normalize(dir + rough * (randVec3(seed) - 0.5.xxx));
  throughput *= phaseFunction(dot(dir, trDir), G);
  return Li + throughput * sampleEnv(trDir);
}

void CS_RayMarch() {
  initDdaCache();

  ivec2 pixelCoord = ivec2(gl_GlobalInvocationID.xy);
  if (pixelCoord.x >= SCREEN_WIDTH || pixelCoord.y >= SCREEN_HEIGHT)
    return;

  vec4 prevColor = imageLoad(RayMarchImage, pixelCoord);
  if (shouldClearTemporalBlend())
    prevColor.a = 0.0;
  
  {
    seed = uvec2(pixelCoord) * uvec2(uniforms.frameCount, uniforms.frameCount+1);
  }
  bool bDebugRender = IsDebugRenderActive();

  vec3 startPos = SCENE_SCALE * camera.inverseView[3].xyz;
  vec2 uv = (vec2(pixelCoord) + 0.5.xx) / vec2(SCREEN_WIDTH, SCREEN_HEIGHT);
  vec3 dir = computeDir(uv);
  
  if (ENABLE_DOF) {
    vec3 c = startPos + DOF_DIST * dir;
    startPos += DOF_RAD * (randVec3(seed) - 0.5.xxx) * 0.01;
    dir = normalize(c - startPos);
  }

  vec3 forwardJitter = rng(seed) * dir * LOD_JITTER * 0.001;//.0;
  startPos += forwardJitter;

  if (!bDebugRender)
    startPos += 0.001 * dir;

  vec3 backgroundColor = sampleEnv(dir);
  
  {
    vec3 dims = vec3(CELLS_WIDTH, CELLS_HEIGHT, CELLS_DEPTH);
    vec3 aspectRatio = float(CELLS_DEPTH).xxx / dims;
    startPos *= aspectRatio * dims;
    dir *= aspectRatio * dims;
    dir = normalize(dir);
  }

  vec3 color = raymarch(startPos, dir, bDebugRender);
  if (prevColor.a > 0.0)
    color = mix(prevColor.rgb, color, max(1.0/(prevColor.a+1.0), TEMPORAL_BLEND));
  imageStore(RayMarchImage, pixelCoord, vec4(color, prevColor.a+1.0));
}

#endif // IS_COMP_SHADER

#ifdef IS_VERTEX_SHADER
VertexOutput VS_RayMarchVoxels() {
  return VertexOutput(VS_FullScreen());
}
#endif // IS_VERTEX_SHADER

#ifdef IS_PIXEL_SHADER
vec3 linearToSdr(vec3 color) {
  return vec3(1.0) - exp(-color * EXPOSURE);
}

void PS_RayMarchVoxels(VertexOutput IN) {
  float sliceDisplayWidth = 0.2;
  if (push0 != 0 && IN.uv.x < sliceDisplayWidth && IN.uv.y < sliceDisplayWidth) {
    vec2 uv = IN.uv / sliceDisplayWidth;
    uvec3 texelId = uvec3(uvec2(uv * vec2(SLICE_WIDTH, SLICE_HEIGHT)), 0);
    float f = getUploadTexel(texelId);
    outDisplay = vec4(f.xxx, 1.0);
    return;
  }

  if (!ENABLE_POSTFX) {
    vec3 col = texture(RayMarchTexture, IN.uv).rgb;
    outDisplay = vec4(linearToSdr(col), 1.0);
    return;
  }

  vec2 dims = vec2(SCREEN_WIDTH, SCREEN_HEIGHT);
  uvec2 seed = uvec2(IN.uv * dims);
  if (VARY_POSTFX_NOISE) 
    seed *= uvec2(uniforms.frameCount, uniforms.frameCount + 1);
  else
    seed *= uvec2(23, 27);

  uint postFxSampleCount = min(POSTFX_SAMPLES, MAX_POSTFX_SAMPLES);

  vec3 col = 0.0.xxx;
  for (int i=0; i<postFxSampleCount; i++) {
    float R = POSTFX_R;
    vec2 x = randVec2(seed);
    vec2 r = R * (x - 0.5.xx);
    float invStdDev = 1.0 / POSTFX_STDEV;
    float pdf = R * R * invStdDev * exp(-0.5 * dot(r, r) * invStdDev * invStdDev) / sqrt(2.0 * PI); // todo correct ??
    // TODO importance sample...
    vec2 uv = IN.uv + (r + 0.5.xx) / dims;
    col += texture(RayMarchTexture, uv).rgb / pdf / postFxSampleCount;
  }

  outDisplay = vec4(linearToSdr(col), 1.0);
}
#endif // IS_PIXEL_SHADER
