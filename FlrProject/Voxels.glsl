#include <Misc/Sampling.glsl>
#include <Misc/Input.glsl>
#include "HDDA.glsl"
#include "Bitfield.glsl"

uvec2 seed;

vec3 getCellColor(ivec3 coord) {
  uvec2 meshletSeed = uvec2(coord.x ^ coord.z, coord.x ^ coord.y);
  return randVec3(meshletSeed);
}

float phaseFunction(float cosTheta, float g) {
  float g2 = g * g;
  return  
      3.0 * (1.0 - g2) * (1.0 + cosTheta * cosTheta) / 
      (8 * PI * (2.0 + g2) * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5));
}

vec3 transformToGrid(vec3 pos) {
  pos.y *= -1.0;
  pos *= 0.4;
  return pos;
}

vec3 getLightPos() {
  float theta = LIGHT_THETA;
  if (LIGHT_ANIM)
    theta += uniforms.time;
  float phi = LIGHT_PHI;
  float cosphi = cos(phi); float sinphi = sin(phi);
  float costheta = cos(theta); float sintheta = sin(theta);
  vec3 lpos = vec3(0.5.xx, 1.0) + 50.0 * (vec3(costheta * cosphi, sinphi, sintheta * cosphi));
  lpos *= 100.0;
  vec3 dims = vec3(CELLS_WIDTH, CELLS_HEIGHT, CELLS_DEPTH);
  vec3 aspectRatio = float(CELLS_DEPTH).xxx / dims;
  lpos *= aspectRatio * dims;
  return lpos;
}

vec3 getLightDir(vec3 pos) {
  return normalize(getLightPos() - pos);
}

vec3 computeDir(vec2 uv) {
	vec2 d = uv * 2.0 - 1.0;

	vec4 target = camera.inverseProjection * vec4(d, 1.0.xx);
	return normalize((camera.inverseView * vec4(normalize(target.xyz), 0)).xyz);
}

vec3 raymarchLight(vec3 pos, bool jitter, uint numIters, float lightDt) {
  vec3 lightThroughput = 1.0.xxx;
  vec3 lightPos = getLightPos();
  vec3 lightDir = lightPos - pos;
  float lightDist2 = dot(lightDir, lightDir);
  lightDir /= sqrt(lightDist2);
  pos += lightDir * lightDt * 2.0;
  pos += SHADOW_SOFTNESS * (2.0 * randVec3(seed) - 1.0.xxx) * lightDt;
  if (jitter)
    pos += lightDir * lightDt * rng(seed);
  for (int lightIter = 0; lightIter < numIters; lightIter++) {
    pos += lightDt * lightDir;
    if (getBit(0, ivec3(pos))) {
      lightThroughput *= exp(-0.5 * DENSITY * lightDt).xxx;
      if (dot(lightThroughput, lightThroughput) < 0.00001) {
        lightThroughput = 0.0.xxx;
        break;
      }
    }
  }

  vec3 LIGHT_COLOR = 1.0.xxx;
  return 1000.0 * LIGHT_INTENSITY * LIGHT_COLOR * lightThroughput / lightDist2;
}

#ifdef IS_COMP_SHADER
void CS_UploadVoxels() {
  uint sliceWidth = push0;
  uint sliceHeight = push1;
  uint sliceOffset = push2;

  uvec3 tileId = gl_GlobalInvocationID.xyz;
  if (tileId.x >= CELLS_WIDTH/4 || tileId.y >= CELLS_HEIGHT/4 ||
      tileId.x >= sliceWidth/4 || tileId.y >= sliceHeight/4) {
    return;
  }

  uvec3 globalIdStart = 4 * tileId + uvec3(0, 0, sliceOffset);
  uvec2 outVec = uvec2(0);
  for (uint i = 0; i < 64; i++) {
    uvec3 localId = uvec3(i & 3, (i >> 2) & 3, i >> 4);
    uvec3 globalId = globalIdStart + localId;
    uint texelIdx = (localId.z + 4 * tileId.z) * sliceWidth * sliceHeight + sliceWidth * globalId.y + globalId.x;
    uint val = batchUploadBuffer(uniforms.frameCount&1)[texelIdx >> 1].u;
    val >>= 16 * ((texelIdx) & 1); 
    val &= 0xFFFF;
    float f = float(val) - float(CUTOFF_LO);
    f /= float(CUTOFF_HI - CUTOFF_LO);
    if (f < 0.0 || f > 1.0) {
      f = 0.0;
    }
    
    if (f > 0.0) {
      outVec[i >> 5] |= 1 << (i & 31);
      setParentsAtomic(globalId + localId); // TODO - do this in a separate pass, for less atomic contention?
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
#endif // IS_COMP_SHADER

#ifdef IS_VERTEX_SHADER
VertexOutput VS_RayMarchVoxels() {
  VertexOutput OUT;
  OUT.uv = VS_FullScreen();
  gl_Position = vec4(OUT.uv * 2.0 - 1.0, 0.0, 1.0);
  return OUT;
}
#endif // IS_VERTEX_SHADER

#ifdef IS_PIXEL_SHADER

void PS_RayMarchVoxels(VertexOutput IN) {
  seed = uvec2(IN.uv * vec2(SCREEN_WIDTH, SCREEN_HEIGHT)) * uvec2(231, 232);
  
  bool bMeshletView = (uniforms.inputMask & INPUT_BIT_SPACE) != 0;
  bool bDepthView = (uniforms.inputMask & INPUT_BIT_F) != 0;
  bool bIterHeatView = (uniforms.inputMask & INPUT_BIT_I) != 0;
  // bool bDebugRender = bMeshletView || bDepthView;

  float SCALE = 0.01;

  vec3 dir = computeDir(IN.uv);
  vec3 startPos = SCALE * camera.inverseView[3].xyz;

  // if (!bDebugRender)
    // startPos += 0.25 * dir;
  if (!bMeshletView && ENABLE_JITTER) {
    startPos += (rng(seed)) * dir * DT;
  }

  float f = dir.y;
  outDisplay = vec4(0.05 * max(round(fract(f * 2.0)), 0.2).xxx, 1.0);
  
  {
    vec3 dims = vec3(CELLS_WIDTH, CELLS_HEIGHT, CELLS_DEPTH);
    vec3 aspectRatio = float(CELLS_DEPTH).xxx / dims;
    startPos *= aspectRatio * dims;
    dir *= aspectRatio * dims;
    dir = normalize(dir);
  }

  if (RENDER_MODE == 0) {
    // Classical fixed-step raymarcher
    float t = 0.0;
    for (int iter=0; iter<ITERS; iter++) {
      t += 100.0 * DT;
      vec3 pos = startPos + t * dir;
      ivec3 globalId = ivec3(pos) >> (BR_FACTOR_LOG2 * DDA_LEVEL);
      if (getBit(DDA_LEVEL, globalId)) {
        if (bMeshletView) {
          outDisplay = vec4(getCellColor(globalId), 1.0);
        } else if (bDepthView) {            
          outDisplay = vec4(fract(t * 0.01).xxx, 1.0);
        } else /*if (bIterHeatView)*/ {
          outDisplay = vec4((float(iter)/ITERS).xxx, 1.0);
        } 
        return;
      }
    }
  } else if (RENDER_MODE == 1) {
    // HDDA raymarcher

    float lodCutoffs[NUM_LEVELS] = { 1.0, 5.0, 24.0, 1000. };
    // uint iterCutoffs[NUM_LEVELS] = { 0.0, 10.0, 100.0, 200.0 };

    // TODO - step-up logic not working   
    uint lodClamp = 0;

    DDA dda = createDDA(startPos, dir, DDA_LEVEL);
    uint stepAxis = 0;
    float prevDdaT = 0.0;
    // TODO - standardize lod-scale jitter...
    if (LOD_JITTER)
      prevDdaT += 100*rng(seed);
    for (int iter=0; iter<ITERS; iter++) {
      float t = prevDdaT + dda.globalT;
      if (LOD_CUTOFFS && t > lodCutoffs[lodClamp]*LOD_SCALE*1000 && lodClamp < NUM_LEVELS)
        lodClamp++;

      ivec3 globalId = dda.coord >> (BR_FACTOR_LOG2 * dda.level);
      if (getBit(dda.level, globalId)) {
        bool bHit = false;
        vec3 pos = getCurrentPos(dda);
        if (dda.level <= lodClamp) {
          bHit = true;
        } else if (STEP_DOWN) {
          prevDdaT += dda.globalT;
          vec3 eps = 0.0.xxx;
          eps[stepAxis] = dda.sn[stepAxis] * 0.001;
          dda = createDDA(pos + eps, dir, dda.level-1);
        } else {
          bHit = true;
        }

        if (bHit) {
          float dist = length(pos - startPos);
          if (bMeshletView) {
            outDisplay = vec4(getCellColor(globalId), 1.0);
          } else if (bDepthView) {
            outDisplay = vec4(fract(dist * 0.01).xxx, 1.0);
          } else /*if (bIterHeatView)*/ {
            outDisplay = vec4((float(iter)/ITERS).xxx, 1.0);
          } 

          return;
        }
      } else if (
          STEP_UP &&
          dda.level < (NUM_LEVELS-1) &&
          !getBit(dda.level+1, globalId >> BR_FACTOR_LOG2)) {
        prevDdaT += dda.globalT;
        vec3 eps = 0.0.xxx;
        eps[stepAxis] = dda.sn[stepAxis] * 0.001;
        dda = createDDA(getCurrentPos(dda) + eps, dir, dda.level+1);
      } else {
        stepDDA(dda, stepAxis);
      }
    }
  }
}
#endif // IS_PIXEL_SHADER
