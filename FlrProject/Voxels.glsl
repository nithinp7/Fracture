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

bool sampleBitField(vec3 pos, out uvec3 globalId) {
  if (pos.x < 0.0 || pos.y < 0.0 || pos.z < 0.0 || 
      pos.x > 1.0 || pos.y > 1.0 || pos.z > 1.0) {
    return false;
  }

  pos *= vec3(CELLS_WIDTH, CELLS_HEIGHT, CELLS_DEPTH) * 0.999999;
  globalId = uvec3(pos);
  
  uint blockIdx = getBlockIdx(globalId);
  uint localIdx = getLocalIdx(globalId);

  uint offsetBase128, offsetBase32, bitOffset;
  getLocalOffsets(localIdx, offsetBase128, offsetBase32, bitOffset);

  uint bit = (voxelBuffer[blockIdx].bitfield[offsetBase128][offsetBase32] >> bitOffset) & 1; 
  return bit == 1;
}

bool sampleBitField(vec3 pos) {
  uvec3 globalId_unused;
  return sampleBitField(pos, globalId_unused);
}

bool sampleDensity(vec3 pos) {
  float h = AMPL * 0.5 * cos(FREQ_A * PI * pos.x + 10.0 * uniforms.time) * 0.5 * cos(FREQ_B * PI * pos.z) + OFFS;
  return pos.y < h;
}

#ifdef IS_COMP_SHADER
void CS_UploadVoxels() {
  uint sliceWidth = push0;
  uint sliceHeight = push1;

  uvec2 tileId = gl_GlobalInvocationID.xy;
  if (tileId.x >= sliceWidth/8 || tileId.y >= sliceHeight/8) {
    return;
  }

  uvec3 globalIdStart = 8*uvec3(tileId, CUR_SLICE);
  uvec2 outVec = uvec2(0);
  for (uint i = 0; i < 64; i++) {
    uvec3 localId = uvec3(i & 3, (i >> 2) & 3, i >> 4);
    uvec3 globalId = globalIdStart + localId;
    uint texelIdx = localId.z * sliceWidth * sliceHeight + sliceWidth * globalId.y + globalId.x;
    uint val = batchUploadBuffer[texelIdx >> 1].u;
    val >>= 16 * (texelIdx & 1); // TODO endianness check...
    val &= 0xFFFF;
    val = clamp(val, CUTOFF_LO, CUTOFF_HI);
    if (val != 0)
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
  vec3 dir = computeDir(IN.uv);
  vec3 pos = camera.inverseView[3].xyz;

  // jitter
  {
    uvec2 seed = uvec2(IN.uv * vec2(SCREEN_WIDTH, SCREEN_HEIGHT)) * uvec2(231, 232);
    pos += rng(seed) * dir * DT;
  }

  outDisplay = vec4(IN.uv, 0.0, 1.0);
  float depth = 0.0;
  for (int i = 0; i < ITERS; i++) {
    depth += DT;
    vec3 curPos = pos + dir * depth;
    uvec3 globalId;
    if (sampleBitField(0.6 * curPos, globalId)) {
      if ((uniforms.inputMask & INPUT_BIT_SPACE) != 0) {
        // meshlet coloring
        uvec2 seed = globalId.xy ^ globalId.yz;
        outDisplay = vec4(randVec3(seed), 1.0);
      } else {
        // depth coloring
        outDisplay = vec4(depth.xxx, 1.0);
      }
      break;
    }
  }

  if ((uniforms.inputMask & INPUT_BIT_T) != 0) {
    uvec2 texel = uvec2(vec2(1530, 1805) * IN.uv * 0.999);
    uint val = batchUploadBuffer[(1530 * 1805 * (CUR_SLICE & 7) + texel.y * 1530 + texel.x) / 2].u;
    outDisplay = val != 0 ? 1.0.xxxx : vec4(0.0.xxx, 1.0);
  }
}

#endif // IS_PIXEL_SHADER
