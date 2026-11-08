cmake_minimum_required(VERSION 3.22.1)

project(arce_llama LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(LLAMA_SRC ${CMAKE_CURRENT_LIST_DIR}/../../../../../third_party/llama.cpp)

# Link llama.cpp statically into the one JNI library the app loads.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Only the libraries are needed: no tools, tests, server, or network client.
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)      # json_schema_to_grammar lives in llama-common
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)

if(ANDROID)
    if(ANDROID_ABI STREQUAL "arm64-v8a")
        set(GGML_CPU_KLEIDIAI ON CACHE BOOL "" FORCE)
        set(GGML_OPENMP ON CACHE BOOL "" FORCE)
    elseif(ANDROID_ABI STREQUAL "x86_64")
        # Emulator build: the emulator passes the host CPU through, and any PC able to run
        # Android Studio's emulator well has AVX2/FMA/F16C.
        set(GGML_AVX ON CACHE BOOL "" FORCE)
        set(GGML_AVX2 ON CACHE BOOL "" FORCE)
        set(GGML_FMA ON CACHE BOOL "" FORCE)
        set(GGML_F16C ON CACHE BOOL "" FORCE)
        set(GGML_OPENMP ON CACHE BOOL "" FORCE)
    endif()
    # Devices with 16 KB memory pages refuse libraries aligned to 4 KB.
    add_link_options("-Wl,-z,max-page-size=16384")
endif()

add_subdirectory(${LLAMA_SRC} llama-build)

add_library(arce_llama SHARED arce_llama.cpp)
target_include_directories(arce_llama PRIVATE ${LLAMA_SRC}/include ${LLAMA_SRC}/common)
target_link_libraries(arce_llama PRIVATE llama llama-common)

if(ANDROID)
    target_link_libraries(arce_llama PRIVATE android log)
else()
    # Host build, used only to compile-check the bridge against the JDK's jni.h.
    find_package(JNI REQUIRED)
    target_include_directories(arce_llama PRIVATE ${JNI_INCLUDE_DIRS})
endif()
