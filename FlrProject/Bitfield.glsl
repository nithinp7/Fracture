#ifndef _BITFIELD_GLSL_
#define _BITFIELD_GLSL_

#define GetVoxelBlock(blockIdx) voxelBuffer(blockIdx/VOXEL_SUB_BUFFER_SIZE)[blockIdx%VOXEL_SUB_BUFFER_SIZE]

struct VoxelAddr {
  uint blockIdx;
  uint offsetBase128;
  uint offsetBase32;
  uint bitOffset;
};

uint getBlockOffset(uint level) {
  return
    ((level > 0) ? L0_NUM_BLOCKS : 0) +
    ((level > 1) ? L1_NUM_BLOCKS : 0) +
    ((level > 2) ? L2_NUM_BLOCKS : 0) +
    ((level > 3) ? L3_NUM_BLOCKS : 0);
}

uvec3 getBlockDims(uint level) {
  return uvec3(L0_BLOCKS_DIM_X, L0_BLOCKS_DIM_Y, L0_BLOCKS_DIM_Z) >> (BR_FACTOR_LOG2 * level);
}

uvec3 getGridDims(uint level) {
  return getBlockDims(level) << 3;
}

uint flattenBlockIdx(uvec3 id, uvec3 dims) {
  return (id.z * dims.y + id.y) * dims.x + id.x;
}

// TODO - idea... during DDA explicitly cache the last loaded block, and only
// issue a new load if the block changes during traversal...
uint getLocalIdx(uvec3 id) {
  // this is an alternative to full flattening, this preserves cache locality for 
  // the various cells within a single block

  // localId within 8x8x8 block (0-511)
  uvec3 offset64Id = (id >> 2) & 1;
  uint offset64Idx = (offset64Id.z << 2) | (offset64Id.y << 1) | offset64Id.x; 

  // bits within u32x2 block (4x4x4=64)
  uvec3 bitId = id & 3;
  uint bitIdx = (bitId.z << 4) | (bitId.y << 2) | bitId.x;
  
  return (offset64Idx << 6) | bitIdx;
}

VoxelAddr constructVoxelAddr(uint blockIdx, uint localIdx) {
  VoxelAddr addr;
  addr.blockIdx = blockIdx;
  // offset in base 128 (i.e. in terms of uvec4s) relative to block
  addr.offsetBase128 = localIdx >> 7;
  // offset in base 32 (i.e. in terms of uints) relative to uvec4
  addr.offsetBase32 = (localIdx >> 5) & 3;
  // bit offset, relative to above uint
  addr.bitOffset = localIdx & 31;
  return addr;
}

VoxelAddr constructVoxelAddr(uint level, uvec3 globalId) {
  uvec3 blockId = globalId >> 3;
  uvec3 localId = globalId & 7;

  uint blockIdx = getBlockOffset(level) + flattenBlockIdx(blockId, getBlockDims(level));
  uint flatLocalIdx = getLocalIdx(localId);
  
  return constructVoxelAddr(blockIdx, flatLocalIdx);
}

bool getBit(VoxelAddr addr) {
  return bool((GetVoxelBlock(addr.blockIdx).bitfield[addr.offsetBase128][addr.offsetBase32] >> addr.bitOffset) & 1);
}

bool getBit(uint level, ivec3 globalId) {
  if (any(lessThan(globalId, ivec3(0))) ||
      any(greaterThanEqual(uvec3(globalId), getGridDims(level)))) 
    return false;
  
  VoxelAddr addr = constructVoxelAddr(level, uvec3(globalId));
  return getBit(addr);
}

void setParentsAtomic(uvec3 globalId) {
  uvec3 gridDims = getGridDims(0);
  uvec3 blockDims = getBlockDims(0);

  for (uint level = 1; level < NUM_LEVELS; level++) {
    VoxelAddr addr = constructVoxelAddr(level, globalId >> (BR_FACTOR_LOG2 * level));
    atomicOr(GetVoxelBlock(addr.blockIdx).bitfield[addr.offsetBase128][addr.offsetBase32], 1 << addr.bitOffset);
  }
}
#endif // _BITFIELD_GLSL_