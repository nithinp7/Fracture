#pragma once

#include <Fluorescence/Fluorescence.h>
#include <Fluorescence/Project.h>
#include <Fluorescence/Shared/CommonStructures.h>
#include <Althea/TransientUniforms.h>
#include <Althea/GlobalHeap.h>
#include <vulkan/vulkan.h>

#include <stb_image.h>

#include <vector>

using namespace AltheaEngine;

namespace AltheaEngine {
  struct FrameContext;
}
class FractureApp : public flr::IFlrProgram {
public:
  FractureApp() : m_volumeIdx(0u) {}
  void setupParams(flr::FlrParams& params) override;
  void setupDescriptorTable(DescriptorSetLayoutBuilder& builder) override;
  void createDescriptors(ResourcesAssignment& assignment) override;
  void createRenderState(flr::Project* project, SingleTimeCommandBuffer& commandBuffer) override;
  void destroyRenderState() override;

  void tick(flr::Project* project, const FrameContext& frame) override;
  void draw(
    flr::Project* project,
    VkCommandBuffer commandBuffer,
    const FrameContext& frame) override;

private:
  void restreamBatch();
  void createFileName(uint32_t volumeIdx, uint32_t sliceIdx, char* outBuf, size_t outBufSize) const;
  void selectVolume(uint32_t volumeIdx);

  struct VolumeData {
    std::string m_folderName;
    std::string m_fileTemplate;
    std::string m_ext;
  };
  std::vector<VolumeData> m_volumes;
  uint32_t m_volumeIdx;

  std::vector<Utilities::ImageFile> m_slicesImageData;
  uint32_t m_sliceWidth;
  uint32_t m_sliceHeight;
  uint32_t m_numSlices;
  uint32_t m_bytesPerPixel;

  flr::CachedFlrUiView<uint32_t> m_volumeIdxUi;
  flr::CachedFlrUiView<uint32_t> m_cutoffLoUi;
  flr::CachedFlrUiView<uint32_t> m_cutoffHiUi;
  
  flr::FlrUiView<bool> m_bStaggeredStreamingUi;
  
  uint32_t m_curStreamingSlice;
  uint32_t m_batchSize;
  uint32_t m_cellsWidth;
  uint32_t m_cellsHeight;
  uint32_t m_cellsDepth;

  uint32_t m_blockCountL0;
  uint32_t m_totalBlockCount;

  flr::BufferId m_uploadBuffer;
  flr::BufferId m_voxelBuffer;
  flr::ComputeShaderId m_clearVoxelsCS;
  flr::ComputeShaderId m_uploadVoxelsCS;
};