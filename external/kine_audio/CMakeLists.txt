cmake_minimum_required(VERSION 3.15)
project(kine_audio LANGUAGES C)

add_library(kine_audio STATIC
    src/kine_audio.c
    ../miniaudio/miniaudio.c
    ../miniaudio/extras/nodes/ma_reverb_node/ma_reverb_node.c
)

target_include_directories(kine_audio PUBLIC include PRIVATE ../miniaudio)
target_compile_definitions(kine_audio PRIVATE KINE_AUDIO_BUILD_EXPORTS)
set_target_properties(kine_audio PROPERTIES POSITION_INDEPENDENT_CODE ON)

if(WIN32)
    target_link_libraries(kine_audio PUBLIC ole32 winmm)
elseif(APPLE)
    target_link_libraries(kine_audio PUBLIC
        "-framework CoreAudio" "-framework AudioToolbox" "-framework AudioUnit")
elseif(UNIX)
    target_link_libraries(kine_audio PUBLIC dl pthread m)
endif()
