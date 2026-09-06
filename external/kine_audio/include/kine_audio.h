#pragma once

#include <stdint.h>

#if defined(_WIN32)
#  if defined(KINE_AUDIO_BUILD_EXPORTS)
#    define KINE_AUDIO_API __declspec(dllexport)
#  else
#    define KINE_AUDIO_API __declspec(dllimport)
#  endif
#else
#  define KINE_AUDIO_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KineAudioSound KineAudioSound;

KINE_AUDIO_API int Kine_Audio_Init(void);
KINE_AUDIO_API void Kine_Audio_Shutdown(void);
KINE_AUDIO_API void Kine_Audio_SetMasterVolume(float volume);
KINE_AUDIO_API void Kine_Audio_SetListener(
    float px, float py, float pz,
    float fx, float fy, float fz,
    float ux, float uy, float uz,
    float vx, float vy, float vz);

KINE_AUDIO_API KineAudioSound* Kine_Audio_LoadSound(const char* path, int stream);
KINE_AUDIO_API void Kine_Audio_DestroySound(KineAudioSound* sound);
KINE_AUDIO_API int Kine_Audio_Play(KineAudioSound* sound);
KINE_AUDIO_API void Kine_Audio_Stop(KineAudioSound* sound);
KINE_AUDIO_API void Kine_Audio_Pause(KineAudioSound* sound);
KINE_AUDIO_API int Kine_Audio_IsPlaying(KineAudioSound* sound);
KINE_AUDIO_API int Kine_Audio_IsAtEnd(KineAudioSound* sound);
KINE_AUDIO_API void Kine_Audio_Seek(KineAudioSound* sound, float seconds);
KINE_AUDIO_API float Kine_Audio_GetTime(KineAudioSound* sound);
KINE_AUDIO_API float Kine_Audio_GetDuration(KineAudioSound* sound);
KINE_AUDIO_API void Kine_Audio_SetVolume(KineAudioSound* sound, float volume);
KINE_AUDIO_API void Kine_Audio_SetPitch(KineAudioSound* sound, float pitch);
KINE_AUDIO_API void Kine_Audio_SetLooping(KineAudioSound* sound, int looping);
KINE_AUDIO_API void Kine_Audio_SetSpatial(KineAudioSound* sound, int enabled);
KINE_AUDIO_API void Kine_Audio_SetPosition(KineAudioSound* sound, float x, float y, float z);
KINE_AUDIO_API void Kine_Audio_SetVelocity(KineAudioSound* sound, float x, float y, float z);
KINE_AUDIO_API void Kine_Audio_SetDirection(KineAudioSound* sound, float x, float y, float z);
KINE_AUDIO_API void Kine_Audio_SetDistance(KineAudioSound* sound, float minDistance, float maxDistance, int rolloffMode);

/* effectType: 0=reverb, 1=echo, 2=equalizer, 3=low-pass, 4=high-pass. */
KINE_AUDIO_API int Kine_Audio_SetEffect(
    KineAudioSound* sound, int effectType, int enabled,
    float a, float b, float c, float d, float e);

#ifdef __cplusplus
}
#endif
