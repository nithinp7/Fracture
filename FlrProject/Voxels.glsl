#include <Misc/Sampling.glsl>
#include <Misc/Input.glsl>

#define GetVoxelBlock(blockIdx) voxelBuffer(blockIdx/VOXEL_SUB_BUFFER_SIZE)[blockIdx%VOXEL_SUB_BUFFER_SIZE]

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

uint getBlockIdx(uvec3 globalId) {
  // id of block
  uvec3 blockId = globalId >> 3;
  return (blockId.z * BLOCKS_HEIGHT + blockId.y) * BLOCKS_WIDTH + blockId.x;
}

uint getLocalIdx(uvec3 globalId) {
  // localId within 8x8x8 block (0-511)
  uvec3 offset64Id = (globalId >> 2) & 1;
  uint offset64Idx = (offset64Id.z << 2) | (offset64Id.y << 1) | offset64Id.x; 

  // bits within u32x2 block (4x4x4=64)
  uvec3 bitId = globalId & 3;
  uint bitIdx = (bitId.z << 4) | (bitId.y << 2) | bitId.x;
  
  return (offset64Idx << 6) | bitIdx;
}

void getLocalOffsets(uint localIdx, out uint offsetBase128, out uint offsetBase32, out uint bitOffset) {
  // offset in base 128 (i.e. in terms of uvec4s) relative to block
  offsetBase128 = localIdx >> 7;
  // offset in base 32 (i.e. in terms of uints) relative to uvec4
  offsetBase32 = (localIdx >> 5) & 3;
  // bit offset, relative to above uint
  bitOffset = localIdx & 31;
}

bool sampleBitField(vec3 pos, out uvec3 globalId, out vec3 normal) {
  
  if (!ENABLE_DDA) { /*
    pos = transformToGrid(pos);
    if (pos.z < CROSS_SECTION_START || pos.z > CROSS_SECTION_END)
      return false;
    vec3 dims = vec3(CELLS_WIDTH, CELLS_HEIGHT, CELLS_DEPTH);
    vec3 aspectRatio = float(CELLS_DEPTH).xxx / dims;
    pos *= aspectRatio * dims;*/
  }

  // if (ENABLE_DDA) {
  //   ivec3 id = abs(ivec3(pos));
  //   // return (abs(id.x + id.y + id.z) & 1) == 1;
  //   globalId = uvec3(id); 
  //   uint sideLen = 100;
  //   return id.x < sideLen && id.y < sideLen && id.z < sideLen;//(abs(id.x + id.y + id.z) & 1) == 1;
    
  // }

  if (pos.x < 0.0 || pos.y < 0.0 || pos.z < 0.0 || 
      pos.x >= CELLS_WIDTH || pos.y >= CELLS_HEIGHT || pos.z >= CELLS_DEPTH) {
    return false;
  }
  globalId = uvec3(pos);

  uint blockIdx = getBlockIdx(globalId);
  uint localIdx = getLocalIdx(globalId);

  uint offsetBase128, offsetBase32, bitOffset;
  getLocalOffsets(localIdx, offsetBase128, offsetBase32, bitOffset);

  uint bit = (GetVoxelBlock(blockIdx).bitfield[offsetBase128][offsetBase32] >> bitOffset) & 1; 
  if (bit == 1) {
    uvec2 block = uvec2(
      GetVoxelBlock(blockIdx).bitfield[offsetBase128][offsetBase32 & ~1],
      GetVoxelBlock(blockIdx).bitfield[offsetBase128][offsetBase32 | 1]
    );

    normal = vec3(0.0);
    for (uint i = 0; i < 64; i++) {
      uvec3 localId = uvec3(i & 3, (i >> 2) & 3, i >> 4);
      if ((block[i >> 5] & (1 << (i & 31))) != 0) {
        normal += vec3(localId) - 1.5.xxx;
      }
    }
    normal = normalize(normal);
    return true;
  }

  return false;
}

bool sampleBitField(vec3 pos, out vec3 normal) {
  uvec3 globalId_unused;
  return sampleBitField(pos, globalId_unused, normal);
}

bool sampleBitField(vec3 pos) {
  uvec3 globalId_unused;
  vec3 normal_unused;
  return sampleBitField(pos, globalId_unused, normal_unused);
}

bool sampleDensity(vec3 pos) {
  float h = AMPL * 0.5 * cos(FREQ_A * PI * pos.x + 10.0 * uniforms.time) * 0.5 * cos(FREQ_B * PI * pos.z) + OFFS;
  return pos.y < h;
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
    if (sampleBitField(pos)) {
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
    if (f < 0.0 || f > 1.0)
      f = 0.0;
    if (f > 0.0)
      outVec[i >> 5] |= 1 << (i & 31);
  }

  uint blockIdx = getBlockIdx(globalIdStart);
  uint localIdx = getLocalIdx(globalIdStart);

  uint offsetBase128, offsetBase32Start, bitOffset_unused;
  getLocalOffsets(localIdx, offsetBase128, offsetBase32Start, bitOffset_unused);
  
  GetVoxelBlock(blockIdx).bitfield[offsetBase128][offsetBase32Start] = outVec[0];
  GetVoxelBlock(blockIdx).bitfield[offsetBase128][offsetBase32Start+1] = outVec[1];
}

void CS_ClearBlocks() {
  uint blockIdx = gl_GlobalInvocationID.x;
  if (blockIdx >= BLOCKS_COUNT)
    return;
  
  GetVoxelBlock(blockIdx).bitfield[0] = uvec4(0);
  GetVoxelBlock(blockIdx).bitfield[1] = uvec4(0);
  GetVoxelBlock(blockIdx).bitfield[2] = uvec4(0);
  GetVoxelBlock(blockIdx).bitfield[3] = uvec4(0);
}

void CS_GenVoxelsTest() {
  uvec3 globalIdStart = 4 * gl_GlobalInvocationID.xyz;
  if (globalIdStart.x >= CELLS_WIDTH || globalIdStart.y >= CELLS_HEIGHT || globalIdStart.z >= CELLS_DEPTH) 
    return;
  
  uvec2 outVec = uvec2(0, 0);
  for (uint i = 0; i < 64; i++) {
    uvec3 globalId = globalIdStart + uvec3(i & 3, (i >> 2) & 3, i >> 4);
    vec3 pos = vec3(globalId) / vec3(CELLS_WIDTH, CELLS_HEIGHT, CELLS_DEPTH);
    if (sampleDensity(pos))
      outVec[i >> 5] |= 1 << (i & 31);
  }

  uint blockIdx = getBlockIdx(globalIdStart);
  uint localIdx = getLocalIdx(globalIdStart);

  uint offsetBase128, offsetBase32Start, bitOffset_unused;
  getLocalOffsets(localIdx, offsetBase128, offsetBase32Start, bitOffset_unused);
  
  GetVoxelBlock(blockIdx).bitfield[offsetBase128][offsetBase32Start] = outVec[0];
  GetVoxelBlock(blockIdx).bitfield[offsetBase128][offsetBase32Start+1] = outVec[1];
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

  // dda specific vars
  ivec3 dda_mapPos = ivec3(0, 0, 0);
  ivec3 dda_rayStep = ivec3(0, 0, 0);
  vec3 dda_sideDist = 0.0.xxx;
  vec3 dda_deltaDist = 0.0.xxx;
  if (ENABLE_DDA)
  {
    curPos /= DDA_SCALE;
    dda_mapPos = ivec3(floor(curPos));
    dda_rayStep = ivec3(sign(dir));
    
    dda_deltaDist = abs(length(dir).xxx / dir);

    dda_sideDist = (sign(dir) * (vec3(dda_mapPos) - curPos) + (sign(dir) * 0.5) + 0.5) * dda_deltaDist;
    outDisplay = vec4(abs(dda_sideDist), 1.0);
    // outDisplay = vec4(0.1 * abs(dda_rayUnitStepSize), 1.0);
    // outDisplay = vec4(0.1 * abs(dda_rayLength), 1.0);
    // return;
  }

  for (iter = 0; iter < iters; iter++) {
    if (ENABLE_DDA) {
      /*
      if (all(lessThan(dda_rayLength.xx, dda_rayLength.yz))) {
        curPos.x += dda_step.x;
        dda_rayLength.x += dda_rayUnitStepSize.x;
      } else if (all(lessThan(dda_rayLength.yy, dda_rayLength.xz))) {
        curPos.y += dda_step.y;
        dda_rayLength.y += dda_rayUnitStepSize.y;
      } else {
        curPos.z += dda_step.z;
        dda_rayLength.z += dda_rayUnitStepSize.z;
      }
      */
      /**/
      bvec3 mask = lessThanEqual(dda_sideDist.xyz, min(dda_sideDist.yzx, dda_sideDist.zxy));
			dda_sideDist += vec3(mask) * dda_deltaDist;
      dda_mapPos += ivec3(vec3(mask)) * dda_rayStep;/**/

      curPos = vec3(dda_mapPos);
      // curPos += dir;
    } else {
      depth += dt;
      curPos = pos + dir * depth;
    }
    vec3 lightDir = getLightDir(curPos);
    vec3 samplePos = curPos;
    if (ENABLE_DDA)
      samplePos = curPos * DDA_SCALE;
    if (sampleBitField(samplePos, globalId, normal)) {
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
        // outDisplay = vec4(fract(2.5 * depth) * randVec3(meshletColorSeed), 1.0);
        outDisplay = vec4(randVec3(meshletColorSeed), 1.0);
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
  }*/

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
  }*/
}

#endif // IS_PIXEL_SHADER
