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
  m_batchSize = *project->getConstUint("BATCH_SIZE");
  m_uploadBuffer = project->findBuffer("batchUploadBuffer");
  m_voxelBuffer = project->findBuffer("voxelBuffer");
  m_clearVoxelsCS = project->findComputeShader("CS_ClearBlocks");
  m_uploadVoxelsCS = project->findComputeShader("CS_UploadVoxels");

  // TODO: hook up windows open-file dialogue
  const char* folderPath = "C:/Users/nithi/Documents/Data/CT_Scans/Bison/SCAN/AMNH-Mammals-232575-000649595/AMNH-mammals-232575";
  char filePath[2048];

  m_curSlice = 0;
  m_cutoffLo = 0;
  m_cutoffHi = (1 << 16) - 1;

  uint32_t numSlices = 0;
  for (; numSlices < m_cellsDepth; numSlices++) {
    sprintf(filePath, "%s/AMNH-mammals-232575_%04d.tif", folderPath, numSlices);
    if (!Utilities::checkFileExists(filePath))
      break;
  }

  m_numSlices = numSlices;
}

void FractureApp::destroyRenderState() {
  m_slicesImageData.clear();
  m_volumeTexture = {};
}

void FractureApp::tick(flr::Project* project, const FrameContext& frame) {

}

void FractureApp::restreamBatch() {

  // TODO: hook up windows open-file dialogue
  const char* folderPath = "C:/Users/nithi/Documents/Data/CT_Scans/Bison/SCAN/AMNH-Mammals-232575-000649595/AMNH-mammals-232575";
  char filePath[2048];

  m_slicesImageData.resize(m_batchSize);

  for (uint32_t i = 0; i < m_batchSize; i++) {
    sprintf(filePath, "%s/AMNH-mammals-232575_%04d.tif", folderPath, m_curSlice + i);

    auto& imgResult = m_slicesImageData[i];
    Utilities::loadTiff(filePath, imgResult);
    m_sliceWidth = imgResult.width;
    m_sliceHeight = imgResult.height;
  }
}

void FractureApp::draw(flr::Project* project, VkCommandBuffer commandBuffer, const FrameContext& frame) {
  auto cutoffLo = project->getSliderUintValue("CUTOFF_LO");
  assert(cutoffLo);
  auto cutoffHi = project->getSliderUintValue("CUTOFF_HI");
  assert(cutoffHi);
  auto bStaggeredStreaming = project->getCheckBoxValue("ENABLE_STAGGERED_STREAMING");
  assert(bStaggeredStreaming);

  if (*cutoffLo != m_cutoffLo || *cutoffHi != m_cutoffHi) {
    m_cutoffLo = *cutoffLo;
    m_cutoffHi = *cutoffHi;
    m_curSlice = 0;
  }
  
  if (m_curSlice < m_numSlices) {
    BufferAllocation* uploadBuffer = project->getBufferAlloc(m_uploadBuffer);
    assert(uploadBuffer);

    for (; m_curSlice < m_numSlices; m_curSlice += m_batchSize)
    {
      restreamBatch();

      // TODO: double buffer the upload memory
      vkQueueWaitIdle(flr::GApplication->getGraphicsQueue());

      void* dst = uploadBuffer->mapMemory();
      uint32_t sliceByteSize = 2 * m_sliceWidth * m_sliceHeight;
      int i = 0;
      for (int offset = 0; i < m_batchSize && (m_curSlice + i) < m_numSlices; i++, offset += sliceByteSize)
        memcpy((char*)dst + offset, m_slicesImageData[i].data.data(), sliceByteSize);
      uploadBuffer->unmapMemory();

      project->setPushConstants(m_sliceWidth, m_sliceHeight, m_curSlice);
      project->dispatchThreads(m_uploadVoxelsCS, m_sliceWidth / 4, m_sliceHeight / 4, i / 4, commandBuffer, frame);
      project->barrierRW(m_voxelBuffer, commandBuffer);
      
      if (*bStaggeredStreaming) {
        m_curSlice += i;
        break;
      }
      else {
        flr::GApplication->partialSubmitWaitGpu(commandBuffer, frame);
      }
    }
  }
}