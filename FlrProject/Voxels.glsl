#include <Misc/Sampling.glsl>
#include <Misc/Input.glsl>
#include "HDDA.glsl"
#include "Bitfield.glsl"

uvec2 seed;

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
    val >>= 16 * ((texelIdx^1) & 1); 
    val &= 0xFFFF;
    float f = float(val) - float(CUTOFF_LO);
    f /= float(CUTOFF_HI - CUTOFF_LO);
    if (f < 0.0 || f > 1.0) {
      f = 0.0;
    } else if (f > 0.0) {
      outVec[i >> 5] |= 1 << (i & 31);
      setParentsAtomic(globalId + localId); // TODO - do this in a separate pass, for less atomic contention?
    }
  }

  VoxelAddr addr = constructVoxelAddr(0, globalIdStart);
  GetVoxelBlock(addr.blockIdx).bitfield[addr.offsetBase128][addr.offsetBase32] = outVec[0];
  GetVoxelBlock(addr.blockIdx).bitfield[addr.offsetBase128][addr.offsetBase32+1] = outVec[1];
}

void CS_GenAccelerationBuffer() {
  /*
  uint sliceOffset = push2;

  uvec3 tileId = gl_GlobalInvocationID.xyz;
  if (tileId.x >= BLOCKS_WIDTH/4 || tileId.y >= BLOCKS_HEIGHT/4) {
    return;
  }

  uvec3 blockIdStart = 4 * (tileId + uvec3(0, 0, sliceOffset/8/4));
  uvec2 outVec = uvec2(0);
  for (uint i = 0; i < 64; i++) {
    uvec3 localId = uvec3(i & 3, (i >> 2) & 3, i >> 4);
    uint blockIdx = flattenBlockId(blockIdStart + localId);
    Block block = GetVoxelBlock(blockIdx);
    if (block.bitfield[0] != uvec4(0) ||
        block.bitfield[1] != uvec4(0) ||
        block.bitfield[2] != uvec4(0) ||
        block.bitfield[3] != uvec4(0)) {
      outVec[i >> 5] |= 1 << (i & 31);
    }
  }

  uint accelBlockIdx = getAccelBlockIdx(blockIdStart);
  uint accelLocalIdx = getLocalIdx(blockIdStart);

  uint offsetBase128, offsetBase32Start, bitOffset_unused;
  getLocalOffsets(accelLocalIdx, offsetBase128, offsetBase32Start, bitOffset_unused);
  
  accelerationBuffer[accelBlockIdx].bitfield[offsetBase128][offsetBase32Start] = outVec[0];
  accelerationBuffer[accelBlockIdx].bitfield[offsetBase128][offsetBase32Start+1] = outVec[1];
  */
}

void CS_ClearBlocks() {
  uint blockIdx = gl_GlobalInvocationID.x;
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
  
  bool bMeshletView = (uniforms.inputMask & INPUT_BIT_SPACE) == 0;
  bool bDepthView = (uniforms.inputMask & INPUT_BIT_F) != 0;
  bool bDebugRender = bMeshletView || bDepthView;

  vec3 dir = computeDir(IN.uv);
  vec3 startPos = camera.inverseView[3].xyz;
  if (!bDebugRender)
    startPos += 0.25 * dir;
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

  // DDA dda = createDDA(curPos, dir, 0);
  float t = 0.0;

  if (RENDER_MODE == 0) {
    // Classical fixed-step raymarcher
    for (int iter=0; iter<ITERS; iter++) {
      // uint stepAxis;
      // stepDDA(dda, stepAxis);
      t += 100.0 * DT;
      vec3 pos = startPos + t * dir;
      ivec3 globalId = ivec3(pos) >> (BR_FACTOR_LOG2 * DDA_LEVEL);
      if (getBit(DDA_LEVEL, globalId)) {
        uvec2 meshletSeed = uvec2(globalId.x ^ globalId.z, globalId.x ^ globalId.y);
        // outDisplay = vec4(1.0, 0.0, 0.0, 1.0);
        outDisplay = vec4(fract(t/20.0).xxx, 1.0);
        if (bMeshletView)
          outDisplay = vec4(randVec3(meshletSeed), 1.0);
        return;
      }
    }
  } else if (RENDER_MODE == 1) {
    // DDA raymarcher - TODO
    // DDA dda = createDDA(startPos, dir, DDA_LEVEL);
    // for (int iter=0; iter<ITERS; iter++) {
      
    // }
  }
}


/*

void PS_RayMarchVoxels_OLD(VertexOutput IN) {
  seed = uvec2(IN.uv * vec2(SCREEN_WIDTH, SCREEN_HEIGHT)) * uvec2(231, 232);
  if (ENABLE_JITTER) {
    // IN.uv += (randVec2(seed) - 0.5.xx) / vec2(SCREEN_WIDTH, SCREEN_HEIGHT);
  }

  bool bMeshletView = (uniforms.inputMask & INPUT_BIT_SPACE) == 0;
  bool bDepthView = (uniforms.inputMask & INPUT_BIT_F) != 0;
  bool bDebugRender = bMeshletView || bDepthView;

  vec3 dir = computeDir(IN.uv);
  vec3 pos = camera.inverseView[3].xyz;
  if (!bDebugRender)
    pos += 0.25 * dir;
  if (!bMeshletView && ENABLE_JITTER) {
    pos += (rng(seed)) * dir * DT;
  }

  float f = dir.y;
  outDisplay = vec4(0.0.xxx, 1.0);//vec4(0.05 * max(round(fract(f * 2.0)), 0.2).xxx, 1.0);
  uvec3 globalId;
  float depth = 0.0;
  vec3 normal;
  int iter = 0;
  vec3 throughput = 1.0.xxx;
  vec3 color = 0.0.xxx;
  vec3 curPos = pos;
  float dt = DT;
  uint iters = ITERS;
  if (bMeshletView)
    dt *= 0.5;
  else
    iters *= 2;

  {
    vec3 dims = vec3(CELLS_WIDTH, CELLS_HEIGHT, CELLS_DEPTH);
    vec3 aspectRatio = float(CELLS_DEPTH).xxx / dims;
    curPos *= aspectRatio * dims;
    dir *= aspectRatio * dims;
    dir = normalize(dir);
  }

  DDA dda;
  if (ENABLE_DDA)
  {
    // if (DDA_LEVEL == 0)
    //   curPos /= 8.0;
    curPos /= DDA_SCALE;
    dda = createDDA(curPos, dir, 0);
  }

  vec3 startPos = curPos;

  bool bMultiLevel = false;
  bool bTestLevelSwitch = false;
  uint ddaLevel = DDA_LEVEL;
  for (iter = 0; iter < iters; iter++) {
    if (ENABLE_DDA) {
      {
        uint stepAxis;
        stepDDA(dda, stepAxis);
        curPos = vec3(dda.coord);
      }
    } else {
      depth += dt;
      curPos = pos + dir * depth;
    }
    vec3 lightDir = getLightDir(curPos);
    vec3 samplePos = curPos;
    if (ENABLE_DDA)
      samplePos = curPos * DDA_SCALE;
    bool bSampleResult = false;

    if (ddaLevel == 0) {
      bSampleResult = sampleAccelerationBitField(samplePos, globalId, normal);
    } else {
      bSampleResult = sampleBitField(samplePos, globalId, normal);
      if (RENDER_MODE == 1)
        globalId /= 8;
    }
    if (bSampleResult) {
      if (ENABLE_DDA) {
        outDisplay = vec4(1.0, 0.0, 0.0, 1.0);
        uvec2 meshletColorSeed = globalId.xy ^ globalId.yz;
        // outDisplay = vec4(fract(2.5 * depth) * randVec3(meshletColorSeed), 1.0);
        outDisplay = vec4(randVec3(meshletColorSeed), 1.0);
        // outDisplay = vec4(fract(0.01 * length(pos - curPos)).xxx, 1.0);
        return;
      }
      // if (bMeshletView) 
      if (ENABLE_DDA)
      {
        // meshlet coloring
        uvec2 meshletColorSeed = globalId.xy ^ globalId.yz;
        float depth = length(curPos - pos);
        outDisplay = vec4(fract(2.5 * depth) * randVec3(meshletColorSeed), 1.0);
        // outDisplay = vec4(randVec3(meshletColorSeed), 1.0);
        break;
      } else if (bDepthView) {
        // depth coloring
        // outDisplay = vec4(depth.xxx, 1.0);
        outDisplay = vec4(fract(2.5 * depth).xxx, 1.0);
        break;
      }
      
      float phase = phaseFunction(abs(dot(lightDir, dir)), G);
      vec3 Li = raymarchLight(curPos, true, LIGHT_ITERS, LIGHT_DT);
      color += throughput * Li * phase;
      throughput *= exp(-DENSITY * DT);
      if (dot(throughput, throughput) < 0.0001) {
        throughput = 0.0.xxx;
        break;
      }
    }

    // if (curPos.y <= -1.5) {
    //   float phase = max(lightDir.y, 0.0);
    //   vec3 Li = raymarchLight(curPos, false, 44, 0.045);
    //   color += FLOOR_REFL * throughput * Li * phase;
    //   throughput = 0.0.xxx;
    //   break;
    // }
  }

  if (ENABLE_DDA) {
    outDisplay = vec4(0.5 * dir + 0.5.xxx, 1.0);
    return;
  }

  if (!bDebugRender && curPos.y > -1.5 && dir.y < 0.0) {
    float u = (-1.5 - curPos.y)/dir.y;
    curPos += u * dir;
    vec3 lightDir = getLightDir(curPos);
    float phase = max(lightDir.y, 0.0);
    vec3 Li = raymarchLight(curPos, false, 44, 0.045);
    color += FLOOR_REFL * throughput * Li * phase;
    outDisplay.rgb = 0.0.xxx;
  }

  outDisplay.rgb *= throughput;
  outDisplay.rgb += color;

  /*
  if (iter < ITERS) 
  {
    float dx = dFdx(depth);
    float dy = dFdx(depth);
    globalId >>= 8;
    uvec2 seed = globalId.xz ^ globalId.zx;
    vec3 col = randVec3(seed);
    // col *= exp(-0.1 * depth * depth);
    // outDisplay = vec4(col, 1.0);
    // outDisplay = vec4(10.0 * sqrt(dx * dx + dy * dy).xxx, 1.0);
    vec3 lightDir = normalize(1.0.xxx);
    col *= max(dot(lightDir, normal), 0.0) + 0.1.xxx;
    outDisplay = vec4(col, 1.0);
  }* /

  /*
  if ((uniforms.inputMask & INPUT_BIT_T) != 0) 
  {
    uint curslice = 50;
    uvec2 texel = uvec2(vec2(1530, 1805) * IN.uv * 0.999);
    uint texelIdx = (1530 * 1805 * (curslice & 7) + texel.y * 1530 + texel.x);
    uint val = batchUploadBuffer[texelIdx >> 1].u;
    if (bool(texelIdx & 1))
      val >>= 16;
    else
      val &= 0xFFFF;
    float f = float(val) - float(CUTOFF_LO);
    f /= float(CUTOFF_HI - CUTOFF_LO);
    if (f > 1.0 || f < 0.0)
      f = 0.0;
    outDisplay = vec4(f.xxx, 1.0);
  }* /
}
*/

#endif // IS_PIXEL_SHADER
