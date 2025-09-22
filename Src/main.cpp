#include "FractureApp.h"

#include <Fluorescence/Fluorescence.h>

#include <Althea/Application.h>

#include <iostream>
#include <filesystem>
#include <Windows.h>

using namespace AltheaEngine;

int main(int argc, char* argv[]) {
  char exePathStr[512];
  GetModuleFileNameA(nullptr, exePathStr, 512);
  std::filesystem::path exeDir(exePathStr);
  exeDir.remove_filename();
  std::filesystem::current_path(exeDir);

  Application::CreateOptions options{};
  options.width = 1440;
  options.height = 1024;
  options.frameRateLimit = 30;
  Application app("Fracture", "../../../Fluorescence", "../../../Fluorescence/Extern/Althea", &options);
  flr::Fluorescence* game = app.createGame<flr::Fluorescence>();
  {
    game->setStartupProject("../../FlrProject/Voxels.flr");
  }
  FractureApp* fractureApp = game->registerProgram<FractureApp>();

  try {
    app.run();
  } catch (const std::exception& e) {
    std::cerr << e.what() << std::endl;
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}