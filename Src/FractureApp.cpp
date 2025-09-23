#include "FractureApp.h"

#include <Althea/Application.h>
#include <Althea/FrameContext.h>
#include <Althea/DefaultTextures.h>
#include <Althea/Utilities.h>

#include <Althea/Parser.h>
#include <fstream>
#include <iostream>

using namespace AltheaEngine;
namespace flr {
  extern Application* GApplication;
}

void FractureApp::setupDescriptorTable(DescriptorSetLayoutBuilder& builder) {
}

void FractureApp::createDescriptors(ResourcesAssignment& assignment) {
}

void FractureApp::setupParams(flr::FlrParams& params) {
  std::ifstream stream("../../Config/Config.ini");
  char linebuf[1024];
  while (stream.getline(linebuf, 1024)) {
    Parser p{ linebuf };
    p.parseWhitespace();
    if (auto folder = p.parseStringLiteral())
    {
      p.parseWhitespace();
      auto fileTemplate = p.parseStringLiteral();
      p.parseWhitespace();
      auto extension = p.parseStringLiteral();
      p.parseWhitespace();
      // format validation
      assert(p.c == 0);
      assert(folder && fileTemplate);
      std::string folderStr(*folder);
      std::string fileTemplateStr(*fileTemplate);
      std::string extStr(*extension);
      VolumeData& volume = m_volumes.emplace_back();
      volume.m_folderName = std::move(folderStr);
      volume.m_fileTemplate = std::move(fileTemplateStr);
      volume.m_ext = std::move(extStr);
    }
  }

  selectVolume(m_volumeIdx);

  // TODO add ability to inject string literal params as well, e.g., would allow binding environment maps, etc from config, 
  // instead of hardcoding into flr proj
  params.m_uintParams.push_back({ std::string("NUM_VOLUMES"), (uint32_t)m_volumes.size() });
  params.m_uintParams.push_back({ std::string("SLICE_WIDTH"), m_sliceWidth });
  params.m_uintParams.push_back({ std::string("SLICE_HEIGHT"), m_sliceHeight });
  params.m_uintParams.push_back({ std::string("BYTES_PER_PIXEL"), m_bytesPerPixel });
  uint32_t maxCutoff = static_cast<uint32_t>((1ull << (8 * m_bytesPerPixel)) - 1ull);
  params.m_uintParams.push_back({ std::string("MAX_CUTOFF"), maxCutoff });
}

void FractureApp::createRenderState(flr::Project* project, SingleTimeCommandBuffer& commandBuffer) {
  m_cellsWidth = *project->getConstUint("CELLS_WIDTH");
  m_cellsHeight = *project->getConstUint("CELLS_HEIGHT");
  m_cellsDepth = *project->getConstUint("CELLS_DEPTH");
  m_batchSize = *project->getConstUint("BATCH_SIZE");
  m_blockCountL0 = *project->getConstUint("L0_NUM_BLOCKS");
  m_totalBlockCount = *project->getConstUint("TOTAL_NUM_BLOCKS");
  // TODO add support for CPU defined buffers, that can be bound to slots declared from flr file...
  // would allow for sizes defined from the CPU side e.g.
  // Currently we would need to reload the entire project (including recompile all shaders)
  // just to change the size of the upload buffer (which is required if switching to a volume with different dimensions)
  m_uploadBuffer = project->findBuffer("batchUploadBuffer");
  m_voxelBuffer = project->findBuffer("voxelBuffer");
  m_clearVoxelsCS = project->findComputeShader("CS_ClearBlocks");
  m_uploadVoxelsCS = project->findComputeShader("CS_UploadVoxels");
  m_cutoffLoUi = project->getSliderUint("CUTOFF_LO");
  m_cutoffHiUi = project->getSliderUint("CUTOFF_HI");
  m_bStaggeredStreamingUi = project->getCheckBox("ENABLE_STAGGERED_STREAMING");
  m_volumeIdxUi = project->getSliderUint("VOLUME_IDX");
  m_volumeIdxUi.Store(m_volumeIdx);

  m_curStreamingSlice = 0u;
}

void FractureApp::destroyRenderState() {
  m_slicesImageData.clear();
  m_volumes.clear();
}

void FractureApp::tick(flr::Project* project, const FrameContext& frame) {
  if (m_volumeIdxUi.IsDirty())
  {
    m_volumeIdx = m_volumeIdxUi.Fetch();
    // TODO - trigger project recreation on FLR game
    // may be better to add a "ShouldRecreateProject" virtual func to IFlrProgram
  }
}

void FractureApp::restreamBatch() {
  char filePath[2048];

  m_slicesImageData.resize(m_batchSize);

  for (uint32_t i = 0; i < m_batchSize && (m_curStreamingSlice + i) < m_numSlices; i++) {
    createFileName(m_volumeIdx, m_curStreamingSlice + i, filePath, 2048);
    auto& imgResult = m_slicesImageData[i];
    Utilities::loadTiff(filePath, imgResult);
    m_sliceWidth = imgResult.width;
    m_sliceHeight = imgResult.height;
  }
}

void FractureApp::createFileName(uint32_t volumeIdx, uint32_t sliceIdx, char* outBuf, size_t bufSize) const {
  snprintf(outBuf, bufSize, "%s/%s%04d%s", m_volumes[volumeIdx].m_folderName.c_str(), m_volumes[volumeIdx].m_fileTemplate.c_str(), sliceIdx, m_volumes[volumeIdx].m_ext.c_str());
}

void FractureApp::selectVolume(uint32_t volumeIdx) {
  assert(volumeIdx < m_volumes.size());

  char filePath[2048];
  createFileName(volumeIdx, 0, filePath, 2048);
  assert(Utilities::checkFileExists(filePath));
  Utilities::ImageFile tmpImg;
  Utilities::loadTiff(filePath, tmpImg);
  m_bytesPerPixel = tmpImg.bytesPerChannel * tmpImg.channels;
  m_sliceWidth = tmpImg.width;
  m_sliceHeight = tmpImg.height;

  uint32_t numSlices = 1;
  for (; numSlices < m_cellsDepth; numSlices++) {
    createFileName(volumeIdx, numSlices, filePath, 2048);
    if (!Utilities::checkFileExists(filePath))
      break;
  }

  m_numSlices = numSlices;
}

void FractureApp::draw(flr::Project* project, VkCommandBuffer commandBuffer, const FrameContext& frame) {
  if (m_cutoffLoUi.IsDirty() || m_cutoffHiUi.IsDirty()) {
    m_cutoffLoUi.Fetch(); m_cutoffHiUi.Fetch();

    // TODO actually handle volume changes by reverse triggering project reload on flr game...
    m_curStreamingSlice = 0;

    project->setPushConstants(m_blockCountL0);
    project->dispatchThreads(m_clearVoxelsCS, m_totalBlockCount - m_blockCountL0, 1, 1, commandBuffer, frame);
    project->barrierRW(m_voxelBuffer, commandBuffer);
  }

  if (m_curStreamingSlice < m_numSlices) {
    BufferAllocation* uploadBuffer = project->getBufferAlloc(m_uploadBuffer, flr::Fluorescence::getFrameCount() & 1);
    assert(uploadBuffer);

    for (; m_curStreamingSlice < m_numSlices; m_curStreamingSlice += m_batchSize)
    {
      restreamBatch();

      void* dst = uploadBuffer->mapMemory();
      uint32_t sliceByteSize = m_bytesPerPixel * m_sliceWidth * m_sliceHeight;
      int i = 0;
      for (int offset = 0; i < m_batchSize && (m_curStreamingSlice + i) < m_numSlices; i++, offset += sliceByteSize)
        memcpy((char*)dst + offset, m_slicesImageData[i].data.data(), sliceByteSize);
      uploadBuffer->unmapMemory();

      project->setPushConstants(m_curStreamingSlice);
      uint32_t threadsX = min(m_cellsWidth, m_sliceWidth) / 4;
      uint32_t threadsY = min(m_cellsHeight, m_sliceHeight) / 4;
      project->dispatchThreads(m_uploadVoxelsCS, threadsX, threadsY, i / 4, commandBuffer, frame);
      project->barrierRW(m_voxelBuffer, commandBuffer);

      if (*m_bStaggeredStreamingUi) {
        m_curStreamingSlice += i;
        break;
      }
      else {
        flr::GApplication->partialSubmitWaitGpu(commandBuffer, frame);
      }
    }
  }
}