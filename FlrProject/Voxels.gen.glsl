#version 460 core

#define NUM_VOLUMES 4
#define SLICE_WIDTH 1788
#define SLICE_HEIGHT 1336
#define BYTES_PER_PIXEL 2
#define MAX_CUTOFF 65535
#define SCREEN_WIDTH 1440
#define SCREEN_HEIGHT 1024
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
#define DEFAULT_CUTOFF_LO 21845
#define MAX_POSTFX_SAMPLES 25
#define VOXEL_SUB_BUFFER_COUNT 16
#define VOXEL_SUB_BUFFER_SIZE 16810049
#define BATCH_SIZE 8
#define UPLOAD_BATCH_SIZE_BASE32 9555072

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

struct IndirectDispatch {
  uint groupCountX;
  uint groupCountY;
  uint groupCountZ;
};

struct Block {
  uvec4 bitfield[4];
};

struct VertexOutput {
  vec2 uv;
};

layout(set=1,binding=1) buffer BUFFER_voxelBuffer {  Block _INNER_voxelBuffer[]; } _HEAP_voxelBuffer [16];
#define voxelBuffer(IDX) _HEAP_voxelBuffer[IDX]._INNER_voxelBuffer
layout(set=1,binding=2) buffer BUFFER_batchUploadBuffer {  uint _INNER_batchUploadBuffer[]; } _HEAP_batchUploadBuffer [2];
#define batchUploadBuffer(IDX) _HEAP_batchUploadBuffer[IDX]._INNER_batchUploadBuffer
layout(set=1,binding=3, rgba32f) uniform image2D RayMarchImage;
layout(set=1,binding=4) uniform sampler2D EnvironmentMap;
layout(set=1,binding=5) uniform sampler2D RayMarchTexture;

layout(set=1, binding=6) uniform _UserUniforms {
	vec4 SCATTER_COL;
	uint CUTOFF_LO;
	uint CUTOFF_HI;
	uint X_LO;
	uint X_HI;
	uint Y_LO;
	uint Y_HI;
	uint Z_LO;
	uint Z_HI;
	uint ITERS;
	uint LIGHT_ITERS;
	uint DDA_LEVEL;
	uint BACKGROUND;
	uint VOLUME_IDX;
	uint POSTFX_SAMPLES;
	float DENSITY_PARAM;
	float G;
	float TR_ROUGH;
	float LIGHT_DT;
	float ABSORB_PREPOST;
	float DOF_RAD;
	float DOF_DIST;
	float TEMPORAL_BLEND;
	float FAKE_AO;
	float LIGHT_INTENSITY;
	float LIGHT_THETA;
	float LIGHT_PHI;
	float SCENE_SCALE;
	float EXPOSURE;
	float POSTFX_R;
	float POSTFX_STDEV;
	float LOD_JITTER;
	float LOD_SCALE;
	float THR_CUT0;
	float THR_CUT1;
	float THR_CUT2;
	float THR_CUT3;
	bool ACCUMULATE;
	bool ENABLE_DOF;
	bool STEP_UP;
	bool STEP_DOWN;
	bool ENABLE_POSTFX;
	bool VARY_POSTFX_NOISE;
	bool LOD_CUTOFFS;
	bool THR_CUTOFFS;
	bool ENABLE_STAGGERED_STREAMING;
};

#include <FlrLib/Fluorescence.glsl>

layout(set=1, binding=7) uniform _CameraUniforms { PerspectiveCamera camera; };



#ifdef IS_PIXEL_SHADER
#if defined(_ENTRY_POINT_PS_RayMarchVoxels) && !defined(_ENTRY_POINT_PS_RayMarchVoxels_ATTACHMENTS)
#define _ENTRY_POINT_PS_RayMarchVoxels_ATTACHMENTS
layout(location = 0) out vec4 outDisplay;
#endif // _ENTRY_POINT_PS_RayMarchVoxels
#endif // IS_PIXEL_SHADER
#include "Voxels.glsl"

#ifdef IS_COMP_SHADER
#ifdef _ENTRY_POINT_CS_UploadVoxels
layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;
void main() { CS_UploadVoxels(); }
#endif // _ENTRY_POINT_CS_UploadVoxels
#ifdef _ENTRY_POINT_CS_ClearBlocks
layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;
void main() { CS_ClearBlocks(); }
#endif // _ENTRY_POINT_CS_ClearBlocks
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
