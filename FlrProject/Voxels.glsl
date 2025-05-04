#include <Misc/Sampling.glsl>
#include <Misc/Input.glsl>

vec3 computeDir(vec2 uv) {
	vec2 d = uv * 2.0 - 1.0;

	vec4 target = camera.inverseProjection * vec4(d, 1.0.xx);
	return (camera.inverseView * vec4(normalize(target.xyz), 0)).xyz;
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
  vec3 dims = vec3(CELLS_WIDTH, CELLS_HEIGHT, CELLS_DEPTH);
  vec3 aspectRatio = float(CELLS_DEPTH).xxx / dims;
  pos *= aspectRatio * dims * 0.999999;

  if (pos.x < 0.0 || pos.y < 0.0 || pos.z < 0.0 || 
      pos.x >= CELLS_WIDTH || pos.y >= CELLS_HEIGHT || pos.z >= CELLS_DEPTH) {
    return false;
  }

  globalId = uvec3(pos);
  
  uint blockIdx = getBlockIdx(globalId);
  uint localIdx = getLocalIdx(globalId);

  uint offsetBase128, offsetBase32, bitOffset;
  getLocalOffsets(localIdx, offsetBase128, offsetBase32, bitOffset);

  uint bit = (voxelBuffer[blockIdx].bitfield[offsetBase128][offsetBase32] >> bitOffset) & 1; 
  if (bit == 1) {
    uvec2 block = uvec2(
      voxelBuffer[blockIdx].bitfield[offsetBase128][offsetBase32 & ~1],
      voxelBuffer[blockIdx].bitfield[offsetBase128][offsetBase32 | 1]
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

bool sampleDensity(vec3 pos) {
  float h = AMPL * 0.5 * cos(FREQ_A * PI * pos.x + 10.0 * uniforms.time) * 0.5 * cos(FREQ_B * PI * pos.z) + OFFS;
  return pos.y < h;
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
    uint val = batchUploadBuffer[texelIdx >> 1].u;
    val >>= 16 * (texelIdx & 1); 
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
  
  voxelBuffer[blockIdx].bitfield[offsetBase128][offsetBase32Start] = outVec[0];
  voxelBuffer[blockIdx].bitfield[offsetBase128][offsetBase32Start+1] = outVec[1];
}

void CS_ClearBlocks() {
  uint blockIdx = gl_GlobalInvocationID.x;
  if (blockIdx >= BLOCKS_COUNT)
    return;
  
  voxelBuffer[blockIdx].bitfield[0] = uvec4(0);
  voxelBuffer[blockIdx].bitfield[1] = uvec4(0);
  voxelBuffer[blockIdx].bitfield[2] = uvec4(0);
  voxelBuffer[blockIdx].bitfield[3] = uvec4(0);
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
  
  voxelBuffer[blockIdx].bitfield[offsetBase128][offsetBase32Start] = outVec[0];
  voxelBuffer[blockIdx].bitfield[offsetBase128][offsetBase32Start+1] = outVec[1];
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
  uvec2 jitterSeed = uvec2(IN.uv * vec2(SCREEN_WIDTH, SCREEN_HEIGHT)) * uvec2(231, 232);
  if (ENABLE_JITTER) {
    IN.uv += (randVec2(jitterSeed) - 0.5.xx) / vec2(SCREEN_WIDTH, SCREEN_HEIGHT);
  }

  vec3 dir = computeDir(IN.uv);
  vec3 pos = camera.inverseView[3].xyz;
  if (ENABLE_JITTER) {
    pos += rng(jitterSeed) * dir * DT * 2.3;
  }

  // outDisplay = vec4(0.5 * dir + 0.5.xxx, 1.0);
  
  float f = dir.x + dir.y + dir.z;
  outDisplay = vec4(0.05 * max(round(fract(f * 2.0)), 0.2).xxx, 1.0);
  uvec3 globalId;
  float depth = 0.0;
  vec3 normal;
  int iter = 0;
  for (iter = 0; iter < ITERS; iter++) {
    depth += DT;
    vec3 curPos = pos + dir * depth;
    curPos.y *= -1.0;
    if (sampleBitField(0.4 * curPos, globalId, normal)) {
      if ((uniforms.inputMask & INPUT_BIT_SPACE) != 0) {
        // meshlet coloring
        uvec2 seed = globalId.xy ^ globalId.yz;
        outDisplay = vec4(randVec3(seed), 1.0);
      } else {
        // depth coloring
        // outDisplay = vec4(depth.xxx, 1.0);
        outDisplay = vec4(fract(2.5 * depth).xxx, 1.0);
      }
      break;
    }
  }

  if (iter < ITERS) {
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
  }

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
  }
}

#endif // IS_PIXEL_SHADER
