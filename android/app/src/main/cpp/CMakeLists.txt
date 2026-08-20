cmake_minimum_required(VERSION 3.22.1)
project(ghostty_connect LANGUAGES C CXX)

add_library(ghostty-vt STATIC IMPORTED)
set_target_properties(ghostty-vt PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/lib/${ANDROID_ABI}/libghostty-vt.a")

add_library(ghostty_android SHARED ghostty_jni.cpp)
target_compile_features(ghostty_android PRIVATE cxx_std_20)
target_compile_definitions(ghostty_android PRIVATE GHOSTTY_STATIC)
target_link_options(ghostty_android PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,-z,common-page-size=16384")
target_include_directories(ghostty_android PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/ghostty/include")
target_link_libraries(ghostty_android PRIVATE ghostty-vt android log m)
