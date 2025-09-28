#include <Misc/Sampling.glsl>
#include <Misc/Input.glsl>
#include "HDDA.glsl"
#include "Bitfield.glsl"

uvec2 seed;

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

#ifdef IS_COMP_SHADER
void CS_UploadVoxels() {
  uint sliceOffset = push0;

  uvec3 tileId = gl_GlobalInvocationID.xyz;
  if (tileId.x >= CELLS_WIDTH/4 || tileId.y >= CELLS_HEIGHT/4 ||
      tileId.x >= SLICE_WIDTH/4 || tileId.y >= SLICE_HEIGHT/4) {
    return;
  }

  uvec3 globalIdStart = 4 * tileId + uvec3(0, 0, sliceOffset);
  uvec2 outVec = uvec2(0);
  for (uint i = 0; i < 64; i++) {
    uvec3 localId = i.xxx >> uvec3(0, 2, 4) & 3;
    uvec3 globalId = globalIdStart + localId;
    uint texelIdx = (localId.z + 4 * tileId.z) * SLICE_WIDTH * SLICE_HEIGHT + SLICE_WIDTH * globalId.y + globalId.x;

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
    if (f < 0.0 || f > 1.0) {
      f = 0.0;
    }
    
    if (f > 0.0) {
      outVec[i >> 5] |= 1 << (i & 31);
      setParentsAtomic(globalId); // TODO - do this in a separate pass, for less atomic contention?
    }
  }
  
  VoxelAddr addr = constructVoxelAddr(0, globalIdStart);
  GetVoxelBlock(addr.blockIdx).bitfield[addr.offsetBase128][addr.offsetBase32] = outVec[0];
  GetVoxelBlock(addr.blockIdx).bitfield[addr.offsetBase128][addr.offsetBase32+1] = outVec[1];
}

void CS_ClearBlocks() {
  uint blockIdx = gl_GlobalInvocationID.x + push0;
  if (blockIdx >= TOTAL_NUM_BLOCKS)
    return;
  
  GetVoxelBlock(blockIdx).bitfield[0] = uvec4(0);
  GetVoxelBlock(blockIdx).bitfield[1] = uvec4(0);
  GetVoxelBlock(blockIdx).bitfield[2] = uvec4(0);
  GetVoxelBlock(blockIdx).bitfield[3] = uvec4(0);
}

#define IsMeshletView() ((uniforms.inputMask & INPUT_BIT_SPACE) != 0)
#define IsDepthView() ((uniforms.inputMask & INPUT_BIT_F) != 0)
#define IsIterHeatView() ((uniforms.inputMask & INPUT_BIT_I) != 0)

bool IsDebugRenderActive() {
  return IsMeshletView() || IsDepthView() || IsIterHeatView();
}

vec4 debugColor(float t, ivec3 globalId, int iter) {
  vec4 color = vec4(0.0.xxx, 1.0);
  if (IsMeshletView()) {
    color = vec4(2.0 * getCellColor(globalId), 1.0);
  } else if (IsDepthView()) {
    color = vec4(fract(t * 0.01).xxx, 1.0);
  } else /*if (bIterHeatView)*/ {
    color = vec4((float(iter)/ITERS).xxx, 1.0);
  } 
  return color;
}

void CS_Update() {
  if (ACCUMULATE == ((uniforms.inputMask & INPUT_BIT_C) != 0) || IsDebugRenderActive()) {
    globalState[0].accumFrames = 0;
  } else {
    globalState[0].accumFrames++;// = max(globalState[0].accumFrames + 1, 4);
  }
}

void CS_RayMarch() {
  ivec2 pixelCoord = ivec2(gl_GlobalInvocationID.xy);
  if (pixelCoord.x >= SCREEN_WIDTH || pixelCoord.y >= SCREEN_HEIGHT)
    return;

  float temporalBlend = 1.0 / (globalState[0].accumFrames + 1.0);
  vec3 prevColor = imageLoad(RayMarchImage, pixelCoord).rgb;

  seed = uvec2(pixelCoord) * uvec2(uniforms.frameCount, uniforms.frameCount+1);
  
  bool bDebugRender = IsDebugRenderActive();

  vec3 startPos = SCENE_SCALE * camera.inverseView[3].xyz;
  vec2 uv = (vec2(pixelCoord) + 0.5.xx) / vec2(SCREEN_WIDTH, SCREEN_HEIGHT);
  vec3 dir = computeDir(uv);
  
  if (ENABLE_DOF) {
    vec3 c = startPos + DOF_DIST * dir;
    startPos += DOF_RAD * (randVec3(seed) - 0.5.xxx) * 0.01;
    dir = normalize(c - startPos);
  }
  vec3 forwardJitter = rng(seed) * dir * 0.0;
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

  vec3 Li = 0.0.xxx;
  vec3 throughput = 1.0.xxx;

  if (RENDER_MODE == 0) {
    // Classical fixed-step raymarcher
    float t = 0.0;
    for (int iter=0; iter<ITERS; iter++) {
      t += 100.0 * CLASSIC_RAYMARCH_DT;
      vec3 pos = startPos + t * dir;
      ivec3 globalId = ivec3(pos) >> (BR_FACTOR_LOG2 * DDA_LEVEL);
      if (getBit(DDA_LEVEL, globalId)) {
        if (bDebugRender) {
          // TODO ..
          // outDisplay = debugColor(t, globalId, iter);
          return;
        } else {
          if (!accumulateLight(pos, dir, 100.0 * CLASSIC_RAYMARCH_DT, Li, throughput, iter))
            break;
        }
      }
    }
  } else if (RENDER_MODE == 1) {
    // HDDA raymarcher
    ivec3 crossSectionLo = ivec3(X_LO, Y_LO, Z_LO);
    ivec3 crossSectionHi = ivec3(X_HI, Y_HI, Z_HI);

    // TODO should also have iter-cutoffs
    float lodCutoffs[NUM_LEVELS] = { 1.0, 5.0, 24.0, 1000. };
    // uint iterCutoffs[NUM_LEVELS] = { 0.0, 10.0, 100.0, 200.0 };

    uint lodClamp = 0;

    DDA dda = createDDA(startPos, dir, DDA_LEVEL);
    uint stepAxis = 0;
    float stepDt = 0.0;
    float prevDdaT = 0.0;
    // TODO - standardize lod-scale jitter...
    if (LOD_JITTER)
      prevDdaT += 100*rng(seed);
    for (int iter=0; iter<ITERS; iter++) {
      float t = prevDdaT + dda.globalT;
      if (LOD_CUTOFFS && t > lodCutoffs[lodClamp]*LOD_SCALE*1000 && lodClamp < NUM_LEVELS)
        lodClamp++;
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
            Li = prevColor.rgb = debugColor(dist, globalId, iter).xyz;
            throughput = 0.0.xxx;
            break;
          } else {  
            if (accumulateLight(pos, dir, stepDt, Li, throughput, iter))
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

  vec3 color = Li + throughput * backgroundColor;
  color = mix(prevColor, color, temporalBlend);
  imageStore(RayMarchImage, pixelCoord, vec4(color, 1.0));
}

#endif // IS_COMP_SHADER

#ifdef IS_VERTEX_SHADER
VertexOutput VS_RayMarchVoxels() {
  return VertexOutput(VS_FullScreen());
}
#endif // IS_VERTEX_SHADER

#ifdef IS_PIXEL_SHADER
void PS_RayMarchVoxels(VertexOutput IN) {
  vec3 color = texture(RayMarchTexture, IN.uv).rgb;

  color = vec3(1.0) - exp(-color * EXPOSURE);

  outDisplay = vec4(color, 1.0);
}
#endif // IS_PIXEL_SHADER
