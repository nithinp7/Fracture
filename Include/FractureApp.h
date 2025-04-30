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
  ImageResource m_volumeTexture;
  flr::Project* m_pProject;
  std::vector<stbi_uc*> m_slicesImageData;
  uint32_t m_sliceWidth;
  uint32_t m_sliceHeight;
  uint32_t m_numSlices;

  uint32_t m_curSlice;
};