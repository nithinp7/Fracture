cmake_minimum_required(VERSION 3.24 FATAL_ERROR)

project(
    Fracture
    VERSION 0.1.0
    LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED True)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

include_directories(Include Src)

function(glob_files out_var_name regexes)
    set(files "")
    foreach(arg ${ARGV})
        list(APPEND regexes_only "${arg}")
    endforeach()
    list(POP_FRONT regexes_only)
    if (GLOB_USE_CONFIGURE_DEPENDS)
        file(GLOB_RECURSE files CONFIGURE_DEPENDS ${regexes_only})
    else()
        file(GLOB files ${regexes_only})
    endif()
    set(${ARGV0} "${files}" PARENT_SCOPE)
endfunction()

glob_files(SRC_FILES_LIST "Src/*.cpp" "Src/*/*.cpp")
add_executable(Fracture ${SRC_FILES_LIST})

set(BUILD_FLR_APP off)
add_subdirectory(../Fluorescence bin)

if (MSVC)
  add_compile_options(/MP)
  target_link_options(Fracture PRIVATE $<$<CONFIG:Debug>:/INCREMENTAL>)
  target_compile_options(Fracture PRIVATE $<$<CONFIG:Debug>:/ZI>)
endif()

target_link_libraries(${PROJECT_NAME} PUBLIC Fluorescence)

