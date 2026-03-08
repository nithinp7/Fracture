#ifndef _BITFIELD_GLSL_
#define _BITFIELD_GLSL_

#define SPARSE_L0_ALLOC_ATTEMPTS 4

#define GetVoxelBlock(blockIdx) voxelBuffer(blockIdx/VOXEL_SUB_BUFFER_SIZE)[blockIdx%VOXEL_SUB_BUFFER_SIZE]

struct VoxelAddr {
  uint blockIdx;
  uint offsetBase128;
  uint offsetBase32;
  uint bitOffset;
};

uint hashCoords(ivec3 globalId) {
  uint hash = uint(abs((globalId.x * 92837111) ^ (globalId.y * 689287499) ^ (globalId.z * 283923481)));
  // return hash == 0 ? ~0 : hash;
  return hash;
}

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

// inverse of above routine
uvec3 getLocalId(uint localIdx) {
  uint offset64Idx = localIdx >> 6;
  uvec3 offset64Id = (offset64Idx.xxx >> uvec3(0, 1, 2)) & 1;
  uint bitIdx = localIdx & 63;
  uvec3 bitId = (bitIdx.xxx >> uvec3(0, 2, 4)) & 3;
  return (offset64Id << 2) | bitId;
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

#ifdef ENABLE_DDA_CACHE
uint cachedBlockIdx;
Block cachedBlock;
void initDdaCache() {cachedBlockIdx = ~0;}
#else // if !ENABLE_DDA_CACHE
void initDdaCache() {}
#endif // !ENABLE_DDA_CACHE
bool getBit(uint level, ivec3 globalId) {
  if (any(lessThan(globalId, ivec3(0))) ||
      any(greaterThanEqual(uvec3(globalId), getGridDims(level)))) 
    return false;
  
  VoxelAddr addr = constructVoxelAddr(level, uvec3(globalId));
#ifdef ENABLE_DDA_CACHE
  if (addr.blockIdx == cachedBlockIdx) {
    return bool((cachedBlock.bitfield[addr.offsetBase128][addr.offsetBase32] >> addr.bitOffset) & 1);
  }
  cachedBlockIdx = addr.blockIdx;
#endif
#if ENABLE_SPARSE_L0
  if (level == 0) {
    VoxelAddr parentBit = constructVoxelAddr(1, uvec3(globalId)>>BR_FACTOR_LOG2);
    if (!getBit(parentBit))
      return false;
    
    uint slot = hashCoords(globalId >> 3)%SPARSE_L0_SLOTS;
    bool bFound = false;
    for (int attempt=0; attempt<SPARSE_L0_ALLOC_ATTEMPTS; attempt++) {
      if (blockOffsets[2*slot] == addr.blockIdx) {
        bFound = true;
        addr.blockIdx = blockOffsets[2*slot+1];
        break;
      } else {
        slot++;
      }
    }

    if (!bFound || addr.blockIdx == ~0)
      return true;
  }
#endif
#ifdef ENABLE_DDA_CACHE
  cachedBlock = GetVoxelBlock(addr.blockIdx);
  return bool((cachedBlock.bitfield[addr.offsetBase128][addr.offsetBase32] >> addr.bitOffset) & 1);
#else
  return getBit(addr);
#endif
}

void setParentsAtomic(uvec3 globalId) {
  for (uint level = 1; level < NUM_LEVELS; level++) {
    VoxelAddr addr = constructVoxelAddr(level, globalId >> (BR_FACTOR_LOG2 * level));
    atomicOr(GetVoxelBlock(addr.blockIdx).bitfield[addr.offsetBase128][addr.offsetBase32], 1 << addr.bitOffset);
  }
}
#endif // _BITFIELD_GLSL_