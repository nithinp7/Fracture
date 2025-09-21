#version 460 core

#define SCREEN_WIDTH 2560
#define SCREEN_HEIGHT 1334
#define NUM_LEVELS 4
#define BR_FACTOR_LOG2 3
#define BR_FACTOR 8
#define L3_BLOCKS_DIM_X 1
#define L3_BLOCKS_DIM_Y 1
#define L3_BLOCKS_DIM_Z 2
#define L2_BLOCKS_DIM_X 8
#define L2_BLOCKS_DIM_Y 8
#define L2_BLOCKS_DIM_Z 16
#define L1_BLOCKS_DIM_X 64
#define L1_BLOCKS_DIM_Y 64
#define L1_BLOCKS_DIM_Z 128
#define L0_BLOCKS_DIM_X 512
#define L0_BLOCKS_DIM_Y 512
#define L0_BLOCKS_DIM_Z 1024
#define L3_NUM_BLOCKS 2
#define L2_NUM_BLOCKS 1024
#define L1_NUM_BLOCKS 524288
#define L0_NUM_BLOCKS 268435456
#define TOTAL_NUM_BLOCKS 268960770
#define CELLS_WIDTH 4096
#define CELLS_HEIGHT 4096
#define CELLS_DEPTH 8192
#define BITS_PER_BLOCK 256
#define VOXEL_SUB_BUFFER_COUNT 16
#define VOXEL_SUB_BUFFER_SIZE 16810049
#define BATCH_SIZE 8
#define UPLOAD_BATCH_SIZE_BASE32 16744464

struct IndexedIndirectArgs {
  uint indexCount;
  uint instanceCount;
  uint firstIndex;
  uint vertexOffset;
  uint firstInstance;
};

struct IndirectArgs {
  uint vertexCount;
  uint instanceCount;
  uint firstVertex;
  uint firstInstance;
};

struct Block {
  uvec4 bitfield[4];
};

struct GlobalState {
  uint accumFrames;
};

struct Uint {
  uint u;
};

struct VertexOutput {
  vec2 uv;
};

layout(set=1,binding=1) buffer BUFFER_voxelBuffer {  Block _INNER_voxelBuffer[]; } _HEAP_voxelBuffer [16];
#define voxelBuffer(IDX) _HEAP_voxelBuffer[IDX]._INNER_voxelBuffer
layout(set=1,binding=2) buffer BUFFER_globalState {  GlobalState globalState[]; };
layout(set=1,binding=3) buffer BUFFER_batchUploadBuffer {  Uint _INNER_batchUploadBuffer[]; } _HEAP_batchUploadBuffer [2];
#define batchUploadBuffer(IDX) _HEAP_batchUploadBuffer[IDX]._INNER_batchUploadBuffer
layout(set=1,binding=4, rgba32f) uniform image2D RayMarchImage;
layout(set=1,binding=5) uniform sampler2D EnvironmentMap;
layout(set=1,binding=6) uniform sampler2D RayMarchTexture;

layout(set=1, binding=7) uniform _UserUniforms {
	uint CUTOFF_LO;
	uint CUTOFF_HI;
	uint ITERS;
	uint LIGHT_ITERS;
	uint DDA_LEVEL;
	uint BACKGROUND;
	uint RENDER_MODE;
	float DENSITY;
	float G;
	float LIGHT_DT;
	float JITTER_RAD;
	float LIGHT_INTENSITY;
	float LIGHT_THETA;
	float LIGHT_PHI;
	float SCENE_SCALE;
	float EXPOSURE;
	float LOD_SCALE;
	float CLASSIC_RAYMARCH_DT;
	bool ACCUMULATE;
	bool STEP_UP;
	bool STEP_DOWN;
	bool LOD_CUTOFFS;
	bool LOD_JITTER;
	bool ENABLE_STAGGERED_STREAMING;
};

#include <FlrLib/Fluorescence.glsl>

layout(set=1, binding=8) uniform _CameraUniforms { PerspectiveCamera camera; };



#ifdef IS_PIXEL_SHADER
#if defined(_ENTRY_POINT_PS_RayMarchVoxels) && !defined(_ENTRY_POINT_PS_RayMarchVoxels_ATTACHMENTS)
#define _ENTRY_POINT_PS_RayMarchVoxels_ATTACHMENTS
layout(location = 0) out vec4 outDisplay;
#endif // _ENTRY_POINT_PS_RayMarchVoxels
#endif // IS_PIXEL_SHADER
#include "Voxels.glsl"

#ifdef IS_COMP_SHADER
#ifdef _ENTRY_POINT_CS_UploadVoxels
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
void main() { CS_UploadVoxels(); }
#endif // _ENTRY_POINT_CS_UploadVoxels
#ifdef _ENTRY_POINT_CS_ClearBlocks
layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;
void main() { CS_ClearBlocks(); }
#endif // _ENTRY_POINT_CS_ClearBlocks
#ifdef _ENTRY_POINT_CS_Update
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
void main() { CS_Update(); }
#endif // _ENTRY_POINT_CS_Update
#ifdef _ENTRY_POINT_CS_RayMarch
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
void main() { CS_RayMarch(); }
#endif // _ENTRY_POINT_CS_RayMarch
#endif // IS_COMP_SHADER


#ifdef IS_VERTEX_SHADER
#ifdef _ENTRY_POINT_VS_RayMarchVoxels
layout(location = 0) out VertexOutput _VERTEX_OUTPUT;
void main() { _VERTEX_OUTPUT = VS_RayMarchVoxels(); }
#endif // _ENTRY_POINT_VS_RayMarchVoxels
#endif // IS_VERTEX_SHADER


#ifdef IS_PIXEL_SHADER
#if defined(_ENTRY_POINT_PS_RayMarchVoxels) && !defined(_ENTRY_POINT_PS_RayMarchVoxels_INTERPOLANTS)
#define _ENTRY_POINT_PS_RayMarchVoxels_INTERPOLANTS
layout(location = 0) in VertexOutput _VERTEX_INPUT;
void main() { PS_RayMarchVoxels(_VERTEX_INPUT); }
#endif // _ENTRY_POINT_PS_RayMarchVoxels
#endif // IS_PIXEL_SHADER
