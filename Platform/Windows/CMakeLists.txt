cmake_minimum_required(VERSION 3.25)
project(HoldfastWindows LANGUAGES CXX RC)

add_executable(HoldfastService
    service/HoldfastService.cpp
    service/HoldfastService.rc
    service/WfpNetworkEnforcer.cpp
)
target_compile_features(HoldfastService PRIVATE cxx_std_20)
target_compile_definitions(HoldfastService PRIVATE UNICODE _UNICODE)
target_link_libraries(HoldfastService PRIVATE advapi32 fwpuclnt rpcrt4)

# The kernel driver is intentionally built with the Windows Driver Kit in a
# Visual Studio "Kernel Mode Driver, Empty (KMDF)" project. Add driver/
# HoldfastGuard.c and include/guard_protocol.h to that project;
# CMake's normal MSVC toolchain does not provide the WDK signing pipeline.
