#version 460 core

#define SCREEN_WIDTH 1440
#define SCREEN_HEIGHT 1280
#define BLOCKS_WIDTH 200
#define BLOCKS_HEIGHT 200
#define BLOCKS_DEPTH 400
#define BLOCKS_COUNT 16000000
#define CELLS_WIDTH 1600
#define CELLS_HEIGHT 1600
#define CELLS_DEPTH 3200
#define CELLS_COUNT 3897032704
#define VOXEL_SUB_BUFFER_COUNT 8
#define VOXEL_SUB_BUFFER_SIZE 2000000
#define BATCH_SIZE 8
#define UPLOAD_BATCH_SIZE_BASE32 16744464

struct Block {
  uvec4 bitfield[4];
};

struct Uint {
  uint u;
};

struct VertexOutput {
  vec2 uv;
};

layout(set=1,binding=1) buffer BUFFER_voxelBuffer {  Block _INNER_voxelBuffer[]; } _HEAP_voxelBuffer [8];
#define voxelBuffer(IDX) _HEAP_voxelBuffer[IDX]._INNER_voxelBuffer
layout(set=1,binding=2) buffer BUFFER_batchUploadBuffer {  Uint _INNER_batchUploadBuffer[]; } _HEAP_batchUploadBuffer [2];
#define batchUploadBuffer(IDX) _HEAP_batchUploadBuffer[IDX]._INNER_batchUploadBuffer

layout(set=1, binding=3) uniform _UserUniforms {
	uint CUTOFF_LO;
	uint CUTOFF_HI;
	uint ITERS;
	uint LIGHT_ITERS;
	float DENSITY;
	float CROSS_SECTION_START;
	float CROSS_SECTION_END;
	float G;
	float FLOOR_REFL;
	float LIGHT_INTENSITY;
	float LIGHT_THETA;
	float LIGHT_PHI;
	float SHADOW_SOFTNESS;
	float DT;
	float LIGHT_DT;
	float DDA_SCALE;
	float FREQ_A;
	float FREQ_B;
	float AMPL;
	float OFFS;
	bool LIGHT_ANIM;
	bool ENABLE_JITTER;
	bool ENABLE_DDA;
	bool ENABLE_STAGGERED_STREAMING;
};

#include <Fluorescence.glsl>

layout(set=1, binding=4) uniform _CameraUniforms { PerspectiveCamera camera; };



#ifdef IS_PIXEL_SHADER
#ifdef _ENTRY_POINT_PS_RayMarchVoxels
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
#ifdef _ENTRY_POINT_CS_GenVoxelsTest
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
void main() { CS_GenVoxelsTest(); }
#endif // _ENTRY_POINT_CS_GenVoxelsTest
#endif // IS_COMP_SHADER


#ifdef IS_VERTEX_SHADER
#ifdef _ENTRY_POINT_VS_RayMarchVoxels
layout(location = 0) out VertexOutput _VERTEX_OUTPUT;
void main() { _VERTEX_OUTPUT = VS_RayMarchVoxels(); }
#endif // _ENTRY_POINT_VS_RayMarchVoxels
#endif // IS_VERTEX_SHADER


#ifdef IS_PIXEL_SHADER
#ifdef _ENTRY_POINT_PS_RayMarchVoxels
layout(location = 0) in VertexOutput _VERTEX_INPUT;
void main() { PS_RayMarchVoxels(_VERTEX_INPUT); }
#endif // _ENTRY_POINT_PS_RayMarchVoxels
#endif // IS_PIXEL_SHADER
