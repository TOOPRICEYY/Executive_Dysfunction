cmake_minimum_required(VERSION 3.25)
project(HoldfastWindows VERSION 0.1.0 LANGUAGES CXX)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
if(WIN32)
    add_compile_definitions(NOMINMAX)
endif()

add_library(HoldfastCore core/Policy.cpp)
target_compile_features(HoldfastCore PUBLIC cxx_std_20)
target_include_directories(HoldfastCore PUBLIC core include)
if(MSVC)
    target_compile_options(HoldfastCore PRIVATE /W4 /permissive-)
else()
    target_compile_options(HoldfastCore PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()
include(CTest)
option(HOLDFAST_BUILD_SHARED_UI "Build the shared interface and trusted workspace backend" OFF)
if(HOLDFAST_BUILD_SHARED_UI)
    include(FetchContent)
    FetchContent_Declare(holdfast_json
        URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
        URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
    FetchContent_MakeAvailable(holdfast_json)
    add_library(HoldfastWorkspace core/Workspace.cpp)
    target_link_libraries(HoldfastWorkspace PUBLIC HoldfastCore nlohmann_json::nlohmann_json)
    target_compile_definitions(HoldfastWorkspace PRIVATE _SILENCE_CXX17_CODECVT_HEADER_DEPRECATION_WARNING)
    if(BUILD_TESTING)
        add_executable(HoldfastWorkspaceTests tests/WorkspaceTests.cpp)
        target_link_libraries(HoldfastWorkspaceTests PRIVATE HoldfastWorkspace)
        add_test(NAME HoldfastWorkspaceTests COMMAND HoldfastWorkspaceTests)
    endif()
endif()
if(BUILD_TESTING)
    add_executable(HoldfastCoreTests tests/PolicyTests.cpp)
    target_link_libraries(HoldfastCoreTests PRIVATE HoldfastCore)
    if(MSVC)
        target_link_options(HoldfastCoreTests PRIVATE /STACK:8388608)
    endif()
    add_test(NAME HoldfastCoreTests COMMAND HoldfastCoreTests)
endif()

if(NOT WIN32)
    message(STATUS "Building portable policy tests only; Windows enforcement is not available on this host.")
    return()
endif()
enable_language(RC)

add_executable(HoldfastService
    service/HoldfastService.cpp
    service/HoldfastService.rc
    service/WfpNetworkEnforcer.cpp
)
target_compile_features(HoldfastService PRIVATE cxx_std_20)
target_compile_definitions(HoldfastService PRIVATE UNICODE _UNICODE)
target_include_directories(HoldfastService PRIVATE service)
target_link_libraries(HoldfastService PRIVATE HoldfastCore advapi32 fwpuclnt rpcrt4)

add_executable(HoldfastCtl tools/HoldfastCtl.cpp)
target_compile_features(HoldfastCtl PRIVATE cxx_std_20)
target_compile_definitions(HoldfastCtl PRIVATE UNICODE _UNICODE)
target_link_libraries(HoldfastCtl PRIVATE HoldfastCore advapi32)
install(TARGETS HoldfastService HoldfastCtl RUNTIME DESTINATION .)
install(FILES scripts/Install.ps1 scripts/Uninstall.ps1 scripts/Test-Connectivity.ps1 scripts/Get-NativeArchitecture.ps1 DESTINATION scripts)
install(FILES README.md DESTINATION .)

if(HOLDFAST_BUILD_SHARED_UI)
    target_sources(HoldfastService PRIVATE service/WorkspaceService.cpp)
    target_compile_definitions(HoldfastService PRIVATE HOLDFAST_WORKSPACE=1 _SILENCE_CXX17_CODECVT_HEADER_DEPRECATION_WARNING)
    target_link_libraries(HoldfastService PRIVATE HoldfastWorkspace)
    add_subdirectory(ui)
endif()

# The kernel driver is intentionally built with the Windows Driver Kit in a
# Visual Studio "Kernel Mode Driver, Empty (KMDF)" project. Add driver/
# HoldfastGuard.c and include/guard_protocol.h to that project;
# CMake's normal MSVC toolchain does not provide the WDK signing pipeline.
