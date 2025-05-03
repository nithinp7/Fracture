#include "FractureApp.h"

#include <Althea/Application.h>
#include <Althea/FrameContext.h>
#include <Althea/DefaultTextures.h>
#include <Althea/Utilities.h>

using namespace AltheaEngine;

namespace flr {
  extern Application* GApplication;
}

// TODO: move to Althea utils...

/*
  struct ImageFile {
    int width;
    int height;
    int channels;
    int bytesPerChannel;
    std::vector<std::byte> data;
  };*/
namespace TiffLoaderImpl {
  struct TiffParser {
    TiffParser(const char* filepath) 
      : m_buffer(Utilities::readFile(filepath))
      , m_offset(0) {}

    template <typename T> const T& parse() {
      const T& t = *reinterpret_cast<const T*>(&m_buffer[m_offset]);
      m_offset += sizeof(T);
      return t;
    }

    template <typename T> const T& peak() {
      return *reinterpret_cast<const T*>(&m_buffer[m_offset]);
    }

    void seek(uint32_t offset) { m_offset = offset; }

    struct ScopedSeek {
      ScopedSeek(TiffParser* p, uint32_t offset) 
        : m_parser(p)
        , m_prevOffset(p->m_offset) {
        m_parser->m_offset = offset;
      }

      ~ScopedSeek() {
        m_parser->m_offset = m_prevOffset;
      }

      TiffParser* m_parser;
      uint32_t m_prevOffset;
    };

    ScopedSeek pushSeek(uint32_t offset) {
      return ScopedSeek(this, offset);
    }

    std::vector<char> m_buffer;
    uint32_t m_offset;
  };

  Utilities::ImageFile loadTiff(const char* filepath) {
    Utilities::ImageFile res;

    TiffParser p(filepath);

    uint32_t pStripOffsets = 0;
    uint32_t stripOffsetStride = 0;
    uint32_t pStripByteSizes = 0;
    uint32_t stripByteSizeStride = 0;
    uint32_t rowsPerStrip = 0;
    uint32_t stripCount = 0;
    bool bPackBits = false;

    // IFH
    struct IFH {
      uint16_t byteOrder;
      uint16_t magic;
      uint32_t ifdOffset;
    };
    const IFH& header = p.parse<IFH>();
    assert(header.byteOrder == 0x4949); // little-endian
    assert(header.magic == 42);

    enum TagType : uint16_t {
      ImageWidth = 0x100,
      ImageLength = 0x101,
      BitsPerSample = 0x102,
      Compression = 0x103,
      PhotometricInterpretation = 0x106,
      StripOffsets = 0x111,
      SamplesPerPixel = 0x115, // ??
      RowsPerStrip = 0x116,
      StripByteCounts = 0x117,
      XResolution = 0x11a, // ??
      YResolution = 0x11b, // ??
      PlanarConfiguration = 0x11c,
      ResolutionUnit = 0x128,
      SampleFormat = 0x153
      // TODO: expand support as needed...
    };

    enum FieldType : uint16_t {
      BYTE = 1,
      ASCII = 2,
      SHORT = 3,
      LONG = 4,
      RATIONAL = 5,
      SBYTE = 6,
      UNDEFINED = 7,
      SSHORT = 8,
      SLONG = 9,
      SRATIONAL = 10,
      FLOAT = 11,
      DOUBLE = 12
    };

    // IFD
    struct IFDEntry {
      TagType tag;
      FieldType fieldType;
      uint32_t count;
      uint32_t valueOffset;
    };

    uint32_t nextIfdOffset = header.ifdOffset;
    while (nextIfdOffset != 0) {
      p.seek(nextIfdOffset);
      uint16_t numEntries = p.parse<uint16_t>();

      // TODO:
      for (int i = 0; i < numEntries; i++) {
        const IFDEntry& entry = p.parse<IFDEntry>();

        //printf("IFD ENTRY - tag: %u, fieldType: %u, count: %u, valueOffset: %u\n", entry.tag, entry.fieldType, entry.count, entry.valueOffset);

        switch (entry.tag)
        {
        case ImageWidth: {
          res.width = entry.valueOffset;
          break;
        };
        case ImageLength: {
          res.height = entry.valueOffset;
          break;
        };
        case BitsPerSample: {
          assert((entry.valueOffset & 7) == 0);
          res.bytesPerChannel = entry.valueOffset >> 3;
          break;
        };
        case Compression: {
          // TODO support other types of compression as needed
          assert(entry.valueOffset == 32773); // PackBits
          // ...
          bPackBits = true;
          break;
        };
        case StripOffsets: {
          pStripOffsets = entry.valueOffset;
          assert(stripCount == 0 || stripCount == entry.count);
          stripCount = entry.count;
          stripOffsetStride = (entry.fieldType == SHORT) ? 2 : 4;
          break;
        };
        case SamplesPerPixel: {
          res.channels = entry.valueOffset;
          break;
        };
        case RowsPerStrip: {
          rowsPerStrip = entry.valueOffset;
          break;
        };
        case StripByteCounts: {
          pStripByteSizes = entry.valueOffset;
          assert(stripCount == 0 || stripCount == entry.count);
          stripCount = entry.count;
          stripByteSizeStride = (entry.fieldType == SHORT) ? 2 : 4;
          break;
        };
        default:
          continue;
        }
      }

      nextIfdOffset = p.parse<uint32_t>();
    }

    uint32_t outputImgSize = res.width * res.height * res.channels * res.bytesPerChannel;
    res.data.resize(outputImgSize);
    uint32_t dstOffset = 0;
    assert(stripCount != 0);
    for (uint32_t stripIdx = 0; stripIdx < stripCount; stripIdx++)
    {
      p.seek(pStripByteSizes + stripIdx * stripByteSizeStride);
      uint32_t byteCount = (stripByteSizeStride == 2) ? p.parse<uint16_t>() : p.parse<uint32_t>();
      p.seek(pStripOffsets + stripIdx * stripOffsetStride);
      uint32_t stripOffset = (stripOffsetStride == 2) ? p.parse<uint16_t>() : p.parse<uint32_t>();
      
      if (bPackBits)
      {
        for (uint32_t byteOffset = 0; byteOffset < byteCount;) {
          assert(dstOffset < outputImgSize);
          p.seek(stripOffset + byteOffset);
          char n = p.parse<char>();
          byteOffset++;
          if (n == -128) {
            // just padding, skip
          }
          else if (n < 0) {
            // next byte copied 1-n times
            uint32_t repeatedRunCount = 1 - (int)n;
            memset(&res.data[dstOffset], p.parse<uint8_t>(), repeatedRunCount);
            dstOffset += repeatedRunCount;
            byteOffset++;
          }
          else {
            // literal run of n+1 bytes
            uint32_t literalRunCount = n + 1;
            memcpy(&res.data[dstOffset], &p.peak<uint8_t>(), literalRunCount);
            dstOffset += literalRunCount;
            byteOffset += literalRunCount;
          }
        }
      }
      else {
        memcpy(&res.data[dstOffset], &p.peak<uint8_t>(), byteCount);
        dstOffset += byteCount;
      }
    }

    assert(dstOffset == outputImgSize);

    return res;
    // image datas
  }

} // namespace
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

  m_curSlice = 5000;

  m_slicesImageData.reserve(500);

  uint32_t numSlices = 0;
  for (; numSlices < 500; numSlices++) {
    sprintf(filePath, "%s/AMNH-mammals-232575_%04d.tif", folderPath, numSlices + 500);
    if (!Utilities::checkFileExists(filePath))
      break;

    m_slicesImageData.emplace_back(TiffLoaderImpl::loadTiff(filePath));
    m_sliceWidth = m_slicesImageData.back().width;
    m_sliceHeight = m_slicesImageData.back().height;
  }

  m_numSlices = numSlices;

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
  m_slicesImageData.clear();
  m_volumeTexture = {};
}

void FractureApp::tick(flr::Project* project, const FrameContext& frame) {

}

void FractureApp::draw(flr::Project* project, VkCommandBuffer commandBuffer, const FrameContext& frame) {
  auto curSlice = project->getSliderUintValue("CUR_SLICE");
  assert(curSlice);

  if (*curSlice != m_curSlice) {
    m_curSlice = *curSlice;

    BufferAllocation* uploadBuffer = project->getBufferByName("batchUploadBuffer");
    assert(uploadBuffer);

    void* dst = uploadBuffer->mapMemory();
    uint32_t sliceByteSize = 2 * m_sliceWidth * m_sliceHeight;
    int batchSize = 8;       
    for (int i = m_curSlice, offset = 0; i < (m_curSlice + batchSize) && i < m_slicesImageData.size(); i++, offset += sliceByteSize)
      memcpy((char*)dst + offset, m_slicesImageData[i].data.data(), sliceByteSize);
    uploadBuffer->unmapMemory();

    flr::TaskBlockId uploadVoxelsTaskId = project->findTaskBlock("UPLOAD_VOXELS");
    assert(uploadVoxelsTaskId.isValid());

    project->setPushConstants(m_sliceWidth, m_sliceHeight);
    project->executeTaskBlock(uploadVoxelsTaskId, commandBuffer, frame);
  }
}