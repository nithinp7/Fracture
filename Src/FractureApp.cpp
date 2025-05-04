#include "FractureApp.h"

#include <Althea/Application.h>
#include <Althea/FrameContext.h>
#include <Althea/DefaultTextures.h>
#include <Althea/Utilities.h>

using namespace AltheaEngine;

namespace flr {
  extern Application* GApplication;
}

void FractureApp::setupDescriptorTable(DescriptorSetLayoutBuilder& builder) {
}

void FractureApp::createDescriptors(ResourcesAssignment& assignment) {
}

void FractureApp::createRenderState(flr::Project* project, SingleTimeCommandBuffer& commandBuffer) {
  m_blockCount = *project->getConstUint("BLOCKS_COUNT");
  m_cellsCount = *project->getConstUint("CELLS_COUNT");
  m_cellsDepth = *project->getConstUint("CELLS_DEPTH");
  m_uploadBuffer = project->findBuffer("batchUploadBuffer");
  m_voxelBuffer = project->findBuffer("voxelBuffer");
  m_clearVoxelsCS = project->findComputeShader("CS_ClearBlocks");
  m_uploadVoxelsCS = project->findComputeShader("CS_UploadVoxels");

  // TODO: hook up windows open-file dialogue
  const char* folderPath = "C:/Users/nithi/Documents/Data/CT_Scans/Bison/SCAN/AMNH-Mammals-232575-000649595/AMNH-mammals-232575";
  char filePath[2048];

  m_curSlice = 5000;
  m_cutoffLo = 0;
  m_cutoffHi = (1 << 16) - 1;

  uint32_t MAX_SLICE_COUNT = 1600;
  m_slicesImageData.reserve(MAX_SLICE_COUNT);

  uint32_t numSlices = 0;
  for (; numSlices < MAX_SLICE_COUNT; numSlices++) {
    sprintf(filePath, "%s/AMNH-mammals-232575_%04d.tif", folderPath, numSlices);
    if (!Utilities::checkFileExists(filePath))
      break;

    auto& imgResult = m_slicesImageData.emplace_back();
    Utilities::loadTiff(filePath, imgResult);
    m_sliceWidth = imgResult.width;
    m_sliceHeight = imgResult.height;
  }

  m_numSlices = numSlices;
}

void FractureApp::destroyRenderState() {
  m_slicesImageData.clear();
  m_volumeTexture = {};
}

void FractureApp::tick(flr::Project* project, const FrameContext& frame) {

}

void FractureApp::draw(flr::Project* project, VkCommandBuffer commandBuffer, const FrameContext& frame) {
  auto cutoffLo = project->getSliderUintValue("CUTOFF_LO");
  assert(cutoffLo);
  auto cutoffHi = project->getSliderUintValue("CUTOFF_HI");
  assert(cutoffHi);

  if (*cutoffLo != m_cutoffLo || *cutoffHi != m_cutoffHi) {
    m_cutoffLo = *cutoffLo;
    m_cutoffHi = *cutoffHi;

    BufferAllocation* uploadBuffer = project->getBufferAlloc(m_uploadBuffer);
    assert(uploadBuffer);

    const int BATCH_SIZE = 8;
    for (uint32_t batch = 0; batch < m_slicesImageData.size() / BATCH_SIZE; batch++)
    {
      if (batch * BATCH_SIZE + (BATCH_SIZE - 1) > m_cellsDepth)
        break;
      void* dst = uploadBuffer->mapMemory();
      uint32_t sliceByteSize = 2 * m_sliceWidth * m_sliceHeight;
      for (int i = 0, offset = 0; i < BATCH_SIZE; i++, offset += sliceByteSize)
        memcpy((char*)dst + offset, m_slicesImageData[batch* BATCH_SIZE + i].data.data(), sliceByteSize);
      uploadBuffer->unmapMemory();

      project->setPushConstants(m_sliceWidth, m_sliceHeight, batch * BATCH_SIZE);
      project->dispatchThreads(m_uploadVoxelsCS, m_sliceWidth / 4, m_sliceHeight / 4, 2, commandBuffer, frame);
      project->barrierRW(m_voxelBuffer, commandBuffer);
      
      flr::GApplication->partialSubmitWaitGpu(commandBuffer, frame);
    }
  }
}