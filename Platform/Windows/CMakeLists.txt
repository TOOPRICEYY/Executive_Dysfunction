cmake_minimum_required(VERSION 3.25)
project(ExecutiveDysfunctionWindows LANGUAGES CXX)

add_executable(ExecutiveDysfunctionService
    service/ExecutiveDysfunctionService.cpp
    service/WfpNetworkEnforcer.cpp
)
target_compile_features(ExecutiveDysfunctionService PRIVATE cxx_std_20)
target_compile_definitions(ExecutiveDysfunctionService PRIVATE UNICODE _UNICODE)
target_link_libraries(ExecutiveDysfunctionService PRIVATE advapi32 fwpuclnt rpcrt4)

# The kernel driver is intentionally built with the Windows Driver Kit in a
# Visual Studio "Kernel Mode Driver, Empty (KMDF)" project. Add driver/
# ExecutiveDysfunctionGuard.c and include/guard_protocol.h to that project;
# CMake's normal MSVC toolchain does not provide the WDK signing pipeline.
