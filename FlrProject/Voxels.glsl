#include <Misc/Sampling.glsl>
#include <Misc/Input.glsl>
#include "HDDA.glsl"
#include "Bitfield.glsl"

uvec2 seed;

vec3 sampleEnv(vec3 dir) {
  if (BACKGROUND == 0) {
    float yaw = mod(atan(dir.z, dir.x) + LIGHT_THETA, 2.0 * PI) - PI;
    float pitch = -atan(dir.y, length(dir.xz));
    vec2 uv = vec2(0.5 * yaw, pitch) / PI + 0.5;

    return LIGHT_INTENSITY * textureLod(EnvironmentMap, uv, 0.0).rgb;
  } else if (BACKGROUND == 1) {
    float c = 5.0;
    vec3 n = 0.5 * normalize(dir) + 0.5.xxx;
    float cosphi = cos(LIGHT_PHI); float sinphi = sin(LIGHT_PHI);
    float costheta = cos(LIGHT_THETA); float sintheta = sin(LIGHT_THETA);
    float x = 0.5 + 0.5 * dot(dir, normalize(vec3(costheta * cosphi, sinphi, sintheta * cosphi)));
    // x = pow(x, 10.0) + 0.01;
    return LIGHT_INTENSITY * x * round(n * c) / c;
  } else {
    return LIGHT_INTENSITY.xxx;
  }
}

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

vec3 computeDir(vec2 uv) {
	vec2 d = uv * 2.0 - 1.0;

	vec4 target = camera.inverseProjection * vec4(d, 1.0.xx);
	return normalize((camera.inverseView * vec4(normalize(target.xyz), 0)).xyz);
}

vec3 raymarchLight(vec3 pos, vec3 viewDir, bool jitter, uint numIters, float lightDt) {
  vec3 lightThroughput = 1.0.xxx;
  vec3 lightDir = normalize(2.0 * randVec3(seed) - 1.0.xxx);
  float phase = phaseFunction(abs(dot(lightDir, viewDir)), G);
  pos += lightDir * lightDt * 2.0;
  for (int lightIter = 0; lightIter < numIters; lightIter++) {
    pos += lightDt * lightDir;
    if (getBit(0, ivec3(round(pos)))) {
      lightThroughput *= exp(-DENSITY * lightDt).xxx;
      if (dot(lightThroughput, lightThroughput) < 0.00001) {
        lightThroughput = 0.0.xxx;
        break;
      }
    }
  }

  return phase * sampleEnv(lightDir) * lightThroughput;
}

#if 0
// UNUSED DDA-based light ray impl 
vec3 raymarchLight(vec3 pos, bool jitter, uint numIters, float unused) {
  vec3 lightThroughput = 1.0.xxx;
  vec3 lightPos = getLightPos();
  vec3 lightDir = (lightPos - pos);
  float lightDist2 = dot(lightDir, lightDir);
  lightDir /= sqrt(lightDist2);
  float phase = phaseFunction(abs(dot(lightDir, dir)), G);
  // pos += SHADOW_SOFTNESS * (2.0 * randVec3(seed) - 1.0.xxx) * lightDt;
  // if (jitter)
    // pos += lightDir * lightDt * rng(seed);
  DDA dda = createDDA(pos, lightDir, 1);
  for (int lightIter = 0; lightIter < numIters; lightIter++) {
    uint stepAxis;
    float dt = stepDDA(dda, stepAxis);
    if (getBit(dda.level, dda.coord >> (BR_FACTOR_LOG2 * dda.level))) {
      lightThroughput *= exp(-DENSITY * dt).xxx;
      if (dot(lightThroughput, lightThroughput) < 0.001) {
        lightThroughput = 0.0.xxx;
        break;
      }
    }
  }

  vec3 LIGHT_COLOR = 1.0.xxx;
  return phase * 1000.0 * LIGHT_INTENSITY * LIGHT_COLOR * lightThroughput / lightDist2;
}
#endif

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

vec4 debugColor(float t, ivec3 globalId, int iter) {
  vec4 color = vec4(0.0.xxx, 1.0);
  if (IsMeshletView()) {
    color = vec4(getCellColor(globalId), 1.0);
  } else if (IsDepthView()) {
    color = vec4(fract(t * 0.01).xxx, 1.0);
  } else /*if (bIterHeatView)*/ {
    color = vec4((float(iter)/ITERS).xxx, 1.0);
  } 
  return color;
}

bool accumulateLight(vec3 pos, vec3 dir, float dt, inout vec3 color, inout vec3 throughput) {
  vec3 Li = raymarchLight(pos, dir, true, LIGHT_ITERS, LIGHT_DT);
  color += throughput * Li;
  throughput *= exp(-DENSITY * 1.0);
  if (dot(throughput, throughput) < 0.0001) 
  {
    throughput = 0.0.xxx;
    return false;
  }
  return true;
}

void CS_Update() {
  if (!ACCUMULATE || (uniforms.inputMask & INPUT_BIT_C) != 0) {
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
  
  bool bDebugRender = IsMeshletView() || IsDepthView() || IsIterHeatView();

  vec2 subpixJitter = JITTER_RAD * (randVec2(seed) - 0.5.xx);
  vec2 uv = (vec2(pixelCoord) + 0.5.xx + subpixJitter) / vec2(SCREEN_WIDTH, SCREEN_HEIGHT);
  vec3 dir = computeDir(uv);
  vec3 forwardJitter = rng(seed) * dir * 0.0;
  vec3 startPos = SCENE_SCALE * camera.inverseView[3].xyz + forwardJitter;

  if (!bDebugRender)
    startPos += 0.05 * dir;

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
          if (!accumulateLight(pos, dir, 100.0 * CLASSIC_RAYMARCH_DT, Li, throughput))
            break;
        }
      }
    }
  } else if (RENDER_MODE == 1) {
    // HDDA raymarcher

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
          // if (dda.level == 0)
          // stepDt = stepDDA(dda, stepAxis);
        } else {
          bHit = true;
        }

        if (bHit) {
          if (bDebugRender) {
            // TODO ...
            float dist = length(pos - startPos);
            // outDisplay = debugColor(dist, globalId, iter);
            return;
          } else {  
            if (accumulateLight(pos, dir, stepDt, Li, throughput))
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
  VertexOutput OUT;
  OUT.uv = VS_FullScreen();
  gl_Position = vec4(OUT.uv * 2.0 - 1.0, 0.0, 1.0);
  return OUT;
}
#endif // IS_VERTEX_SHADER

#ifdef IS_PIXEL_SHADER
void PS_RayMarchVoxels(VertexOutput IN) {
  vec3 color = texture(RayMarchTexture, IN.uv).rgb;

  color = vec3(1.0) - exp(-color * EXPOSURE);

  outDisplay = vec4(color, 1.0);
}
#endif // IS_PIXEL_SHADER
