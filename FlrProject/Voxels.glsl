

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
  uvec3 localId = globalId & 7;
  return (localId.z << 6) | (localId.y << 3) | localId.x;
}

void getLocalOffsets(uint localIdx, out uint offsetBase128, out uint offsetBase32, out uint bitOffset) {
  // offset in base 128 (i.e. in terms of uvec4s) relative to block
  offsetBase128 = localIdx >> 7;
  // offset in base 32 (i.e. in terms of uints) relative to uvec4
  offsetBase32 = (localIdx >> 5) & 3;
  // bit offset, relative to above uint
  bitOffset = localIdx & 0x1F;
}

bool sampleBitField(vec3 pos, out uvec3 globalId) {
  if (pos.x < 0.0 || pos.y < 0.0 || pos.z < 0.0 || 
      pos.x > 1.0 || pos.y > 1.0 || pos.z > 1.0) {
    return false;
  }

  pos *= vec3(CELLS_WIDTH, CELLS_HEIGHT, CELLS_DEPTH) * 0.9999;
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
void CS_GenVoxelsTest() {
  uvec3 globalIdStart = 4 * gl_GlobalInvocationID.xyz;
  if (globalIdStart.x >= CELLS_WIDTH || globalIdStart.y >= CELLS_HEIGHT || globalIdStart.z >= CELLS_DEPTH) 
    return;
  
  uvec2 outVec = uvec2(0, 0);
  for (uint i = 0; i < 64; i++) {
    uvec3 globalId = globalIdStart + uvec3(i >> 4, (i >> 2) & 3, i & 3);
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

  outDisplay = vec4(IN.uv, 0.0, 1.0);
  float depth = 0.0;
  for (int i = 0; i < ITERS; i++) {
    depth += DT;
    vec3 curPos = pos + dir * depth;
    if (sampleBitField(curPos)) {
      outDisplay = vec4(depth.xxx, 1.0);
      break;
    }
  }
}

#endif // IS_PIXEL_SHADER
