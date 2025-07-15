cmake_minimum_required(VERSION 3.18.1)

project(yuv_converter)

add_library(yuv_converter SHARED
        ../../../../../native/yuv_converter.c
)

# Enable optimizations
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O3 -ffast-math")

# Enable NEON for ARM processors
if(${ANDROID_ABI} STREQUAL "arm64-v8a" OR ${ANDROID_ABI} STREQUAL "armeabi-v7a")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -mfpu=neon")
endif()

target_link_libraries(yuv_converter)