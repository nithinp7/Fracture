#include "FractureApp.h"

#include <Althea/Application.h>
#include <Althea/FrameContext.h>
#include <Althea/DefaultTextures.h>

using namespace AltheaEngine;

namespace flr {
  extern Application* GApplication;
}


void FractureApp::setupDescriptorTable(DescriptorSetLayoutBuilder& builder) {
  //builder.addTextureBinding();
}

void FractureApp::createDescriptors(ResourcesAssignment& assignment) {
  //assignment.bindTexture(m_volumeTexture);
}

void FractureApp::createRenderState(flr::Project* project, SingleTimeCommandBuffer& commandBuffer) {
  // TODO: hook up windows open-file dialogue
  const char* folderPath = "C:/Users/nithi/Documents/Data/CT_Scans/Bison/SCAN/AMNH-Mammals-232575-000649595/AMNH-mammals-232575";
  char filePath[2048];

  m_slicesImageData.resize(500);

  int sliceWidth = 0;
  int sliceHeight = 0;
  int numSlices = 0;
  for (; numSlices < 500; numSlices++) {
    sprintf(filePath, "%s/AMNH-mammals-232575_%04d.tif", folderPath, numSlices);
    if (!Utilities::checkFileExists(filePath))
      break;

    int origChannels;
    int desiredChannels = 1;
    m_slicesImageData[numSlices] = stbi_load(filePath, &sliceWidth, &sliceHeight, &origChannels, desiredChannels);
  }

#if 0
  for (int sliceIdx = 0; sliceIdx < numSlices; sliceIdx++) {
    sprintf(filePath, "%s/AMNH-mammals-232575_%04d.tif", folderPath, sliceIdx);

    int origChannels;
    int desiredChannels = 1;
    stbi_uc* pImg = stbi_load(filePath, &sliceWidth, &sliceHeight, &origChannels, desiredChannels);

    if (sliceIdx == 0) {
      ImageOptions imgOptions{};
      imgOptions.imageType = VK_IMAGE_TYPE_3D;
      imgOptions.format = VK_FORMAT_R8_UNORM; // TODO: looks like CT-scan images are actually 16-bit channels, use full-precision 
      imgOptions.width = sliceWidth;
      imgOptions.height = sliceHeight;
      imgOptions.depth = numSlices;
      imgOptions.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
      m_volumeTexture.image = Image(*flr::GApplication, imgOptions);

      ImageViewOptions viewOptions{};
      viewOptions.format = imgOptions.format;
      viewOptions.layerCount = imgOptions.layerCount;
      viewOptions.type = VK_IMAGE_VIEW_TYPE_3D;
      m_volumeTexture.view = ImageView(*flr::GApplication, m_volumeTexture.image, viewOptions);

      SamplerOptions samplerOptions{};
      m_volumeTexture.sampler = Sampler(*flr::GApplication, samplerOptions);

      m_volumeTexture.image.transitionLayout(
        commandBuffer,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT);
    }

    {
      size_t sliceByteSize = sliceWidth * sliceHeight; // one 8-bit channel
      VkBuffer stagingBuffer = commandBuffer.createStagingBuffer(
        *flr::GApplication, 
        gsl::span<const std::byte>(
          reinterpret_cast<const std::byte*>(pImg), 
          sliceByteSize));

      VkBufferImageCopy region{};
      region.bufferOffset = 0;
      region.bufferRowLength = 0;
      region.bufferImageHeight = 0;

      region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      region.imageSubresource.mipLevel = 0;
      region.imageSubresource.baseArrayLayer = 0;
      region.imageSubresource.layerCount = 1;

      region.imageOffset = { 0, 0, sliceIdx };
      region.imageExtent = { (uint32_t)sliceWidth, (uint32_t)sliceHeight, 1 };

      vkCmdCopyBufferToImage(
        commandBuffer,
        stagingBuffer,
        m_volumeTexture.image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &region);
    }

    stbi_image_free(pImg);
  }

  m_volumeTexture.image.transitionLayout(
    commandBuffer, 
    VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, 
    VK_ACCESS_SHADER_READ_BIT, 
    VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
#endif 
}

void FractureApp::destroyRenderState() {
  for (stbi_uc* img : m_slicesImageData)
    stbi_image_free(img);

  m_volumeTexture = {};
}

void FractureApp::tick(flr::Project* project, const FrameContext& frame) {

}

void FractureApp::draw(flr::Project* project, VkCommandBuffer commandBuffer, const FrameContext& frame) {

}