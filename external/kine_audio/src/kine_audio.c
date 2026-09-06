#include "kine_audio.h"

#include "miniaudio.h"
#include "extras/nodes/ma_reverb_node/ma_reverb_node.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

struct KineAudioSound {
    ma_sound sound;
    ma_reverb_node reverb;
    ma_delay_node echo;
    ma_peak_node eqLow;
    ma_peak_node eqMid;
    ma_peak_node eqHigh;
    ma_lpf_node lowPass;
    ma_hpf_node highPass;
    ma_bool32 reverbEnabled;
    ma_bool32 echoEnabled;
    ma_bool32 equalizerEnabled;
    ma_bool32 lowPassEnabled;
    ma_bool32 highPassEnabled;
    ma_bool32 soundInitialized;
    ma_bool32 reverbInitialized;
    ma_bool32 echoInitialized;
    ma_bool32 eqLowInitialized;
    ma_bool32 eqMidInitialized;
    ma_bool32 eqHighInitialized;
    ma_bool32 lowPassInitialized;
    ma_bool32 highPassInitialized;
};

static ma_engine g_engine;
static ma_bool32 g_initialized = MA_FALSE;

static float kine_clamp(float value, float minimum, float maximum)
{
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
}

static void kine_audio_detach_graph(KineAudioSound* sound)
{
    if (!sound) return;
    ma_node_detach_all_output_buses((ma_node*)&sound->sound);
    if (sound->reverbInitialized) ma_node_detach_all_output_buses((ma_node*)&sound->reverb);
    if (sound->echoInitialized) ma_node_detach_all_output_buses((ma_node*)&sound->echo);
    if (sound->eqLowInitialized) ma_node_detach_all_output_buses((ma_node*)&sound->eqLow);
    if (sound->eqMidInitialized) ma_node_detach_all_output_buses((ma_node*)&sound->eqMid);
    if (sound->eqHighInitialized) ma_node_detach_all_output_buses((ma_node*)&sound->eqHigh);
    if (sound->lowPassInitialized) ma_node_detach_all_output_buses((ma_node*)&sound->lowPass);
    if (sound->highPassInitialized) ma_node_detach_all_output_buses((ma_node*)&sound->highPass);
}

static void kine_audio_rebuild_graph(KineAudioSound* sound)
{
    ma_node* current;
    if (!sound || !sound->soundInitialized || !g_initialized) return;

    kine_audio_detach_graph(sound);

    current = (ma_node*)&sound->sound;
#define KINE_ATTACH(enabled, initialized, node) \
    if ((enabled) && (initialized)) { \
        ma_node_attach_output_bus(current, 0, (ma_node*)&(node), 0); \
        current = (ma_node*)&(node); \
    }
    KINE_ATTACH(sound->equalizerEnabled, sound->eqLowInitialized, sound->eqLow)
    KINE_ATTACH(sound->equalizerEnabled, sound->eqMidInitialized, sound->eqMid)
    KINE_ATTACH(sound->equalizerEnabled, sound->eqHighInitialized, sound->eqHigh)
    KINE_ATTACH(sound->lowPassEnabled, sound->lowPassInitialized, sound->lowPass)
    KINE_ATTACH(sound->highPassEnabled, sound->highPassInitialized, sound->highPass)
    KINE_ATTACH(sound->echoEnabled, sound->echoInitialized, sound->echo)
    KINE_ATTACH(sound->reverbEnabled, sound->reverbInitialized, sound->reverb)
#undef KINE_ATTACH
    ma_node_attach_output_bus(current, 0, ma_engine_get_endpoint(&g_engine), 0);
}

static void kine_audio_uninit_sound(KineAudioSound* sound)
{
    if (!sound) return;
    kine_audio_detach_graph(sound);
    if (sound->soundInitialized) ma_sound_uninit(&sound->sound);
    if (sound->reverbInitialized) ma_reverb_node_uninit(&sound->reverb, NULL);
    if (sound->echoInitialized) ma_delay_node_uninit(&sound->echo, NULL);
    if (sound->eqLowInitialized) ma_peak_node_uninit(&sound->eqLow, NULL);
    if (sound->eqMidInitialized) ma_peak_node_uninit(&sound->eqMid, NULL);
    if (sound->eqHighInitialized) ma_peak_node_uninit(&sound->eqHigh, NULL);
    if (sound->lowPassInitialized) ma_lpf_node_uninit(&sound->lowPass, NULL);
    if (sound->highPassInitialized) ma_hpf_node_uninit(&sound->highPass, NULL);
}

KINE_AUDIO_API int Kine_Audio_Init(void)
{
    if (g_initialized) return 1;
    if (ma_engine_init(NULL, &g_engine) != MA_SUCCESS) return 0;
    g_initialized = MA_TRUE;
    return 1;
}

KINE_AUDIO_API void Kine_Audio_Shutdown(void)
{
    if (!g_initialized) return;
    ma_engine_uninit(&g_engine);
    memset(&g_engine, 0, sizeof(g_engine));
    g_initialized = MA_FALSE;
}

KINE_AUDIO_API void Kine_Audio_SetMasterVolume(float volume)
{
    if (g_initialized) ma_engine_set_volume(&g_engine, kine_clamp(volume, 0.0f, 16.0f));
}

KINE_AUDIO_API void Kine_Audio_SetListener(
    float px, float py, float pz, float fx, float fy, float fz,
    float ux, float uy, float uz, float vx, float vy, float vz)
{
    if (!g_initialized) return;
    ma_engine_listener_set_position(&g_engine, 0, px, py, pz);
    ma_engine_listener_set_direction(&g_engine, 0, fx, fy, fz);
    ma_engine_listener_set_world_up(&g_engine, 0, ux, uy, uz);
    ma_engine_listener_set_velocity(&g_engine, 0, vx, vy, vz);
}

KINE_AUDIO_API KineAudioSound* Kine_Audio_LoadSound(const char* path, int stream)
{
    KineAudioSound* sound;
    ma_node_graph* graph;
    ma_uint32 channels, sampleRate;
    ma_uint32 flags = MA_SOUND_FLAG_NO_DEFAULT_ATTACHMENT;
    ma_reverb_node_config reverbConfig;
    ma_delay_node_config echoConfig;
    ma_peak_node_config peakConfig;
    ma_lpf_node_config lpfConfig;
    ma_hpf_node_config hpfConfig;

    if (!path || !path[0] || !Kine_Audio_Init()) return NULL;
    sound = (KineAudioSound*)calloc(1, sizeof(*sound));
    if (!sound) return NULL;
    if (stream) flags |= MA_SOUND_FLAG_STREAM;
    if (ma_sound_init_from_file(&g_engine, path, flags, NULL, NULL, &sound->sound) != MA_SUCCESS) {
        free(sound);
        return NULL;
    }
    sound->soundInitialized = MA_TRUE;
    graph = ma_engine_get_node_graph(&g_engine);
    channels = ma_engine_get_channels(&g_engine);
    sampleRate = ma_engine_get_sample_rate(&g_engine);

    reverbConfig = ma_reverb_node_config_init(channels, sampleRate);
    sound->reverbInitialized = ma_reverb_node_init(graph, &reverbConfig, NULL, &sound->reverb) == MA_SUCCESS;
    echoConfig = ma_delay_node_config_init(channels, sampleRate, sampleRate / 4, 0.25f);
    echoConfig.delay.wet = 0.35f;
    echoConfig.delay.dry = 1.0f;
    sound->echoInitialized = ma_delay_node_init(graph, &echoConfig, NULL, &sound->echo) == MA_SUCCESS;
    peakConfig = ma_peak_node_config_init(channels, sampleRate, 0.0, 1.0, 200.0);
    sound->eqLowInitialized = ma_peak_node_init(graph, &peakConfig, NULL, &sound->eqLow) == MA_SUCCESS;
    peakConfig = ma_peak_node_config_init(channels, sampleRate, 0.0, 1.0, 1000.0);
    sound->eqMidInitialized = ma_peak_node_init(graph, &peakConfig, NULL, &sound->eqMid) == MA_SUCCESS;
    peakConfig = ma_peak_node_config_init(channels, sampleRate, 0.0, 1.0, 6000.0);
    sound->eqHighInitialized = ma_peak_node_init(graph, &peakConfig, NULL, &sound->eqHigh) == MA_SUCCESS;
    lpfConfig = ma_lpf_node_config_init(channels, sampleRate, 20000.0, 2);
    sound->lowPassInitialized = ma_lpf_node_init(graph, &lpfConfig, NULL, &sound->lowPass) == MA_SUCCESS;
    hpfConfig = ma_hpf_node_config_init(channels, sampleRate, 20.0, 2);
    sound->highPassInitialized = ma_hpf_node_init(graph, &hpfConfig, NULL, &sound->highPass) == MA_SUCCESS;
    kine_audio_rebuild_graph(sound);
    return sound;
}

KINE_AUDIO_API void Kine_Audio_DestroySound(KineAudioSound* sound)
{
    if (!sound) return;
    kine_audio_uninit_sound(sound);
    free(sound);
}

KINE_AUDIO_API int Kine_Audio_Play(KineAudioSound* sound) { return sound && ma_sound_start(&sound->sound) == MA_SUCCESS; }
KINE_AUDIO_API void Kine_Audio_Stop(KineAudioSound* sound) { if (sound) { ma_sound_stop(&sound->sound); ma_sound_seek_to_pcm_frame(&sound->sound, 0); } }
KINE_AUDIO_API void Kine_Audio_Pause(KineAudioSound* sound) { if (sound) ma_sound_stop(&sound->sound); }
KINE_AUDIO_API int Kine_Audio_IsPlaying(KineAudioSound* sound) { return sound && ma_sound_is_playing(&sound->sound); }
KINE_AUDIO_API int Kine_Audio_IsAtEnd(KineAudioSound* sound) { return sound && ma_sound_at_end(&sound->sound); }
KINE_AUDIO_API void Kine_Audio_Seek(KineAudioSound* sound, float seconds) { if (sound) ma_sound_seek_to_second(&sound->sound, fmaxf(0.0f, seconds)); }
KINE_AUDIO_API float Kine_Audio_GetTime(KineAudioSound* sound) { float value = 0; if (sound) ma_sound_get_cursor_in_seconds(&sound->sound, &value); return value; }
KINE_AUDIO_API float Kine_Audio_GetDuration(KineAudioSound* sound) { float value = 0; if (sound) ma_sound_get_length_in_seconds(&sound->sound, &value); return value; }
KINE_AUDIO_API void Kine_Audio_SetVolume(KineAudioSound* sound, float volume) { if (sound) ma_sound_set_volume(&sound->sound, kine_clamp(volume, 0.0f, 16.0f)); }
KINE_AUDIO_API void Kine_Audio_SetPitch(KineAudioSound* sound, float pitch) { if (sound) ma_sound_set_pitch(&sound->sound, kine_clamp(pitch, 0.01f, 16.0f)); }
KINE_AUDIO_API void Kine_Audio_SetLooping(KineAudioSound* sound, int looping) { if (sound) ma_sound_set_looping(&sound->sound, looping != 0); }
KINE_AUDIO_API void Kine_Audio_SetSpatial(KineAudioSound* sound, int enabled) { if (sound) ma_sound_set_spatialization_enabled(&sound->sound, enabled != 0); }
KINE_AUDIO_API void Kine_Audio_SetPosition(KineAudioSound* sound, float x, float y, float z) { if (sound) ma_sound_set_position(&sound->sound, x, y, z); }
KINE_AUDIO_API void Kine_Audio_SetVelocity(KineAudioSound* sound, float x, float y, float z) { if (sound) ma_sound_set_velocity(&sound->sound, x, y, z); }
KINE_AUDIO_API void Kine_Audio_SetDirection(KineAudioSound* sound, float x, float y, float z) { if (sound) ma_sound_set_direction(&sound->sound, x, y, z); }

KINE_AUDIO_API void Kine_Audio_SetDistance(KineAudioSound* sound, float minDistance, float maxDistance, int rolloffMode)
{
    if (!sound) return;
    ma_sound_set_min_distance(&sound->sound, fmaxf(0.001f, minDistance));
    ma_sound_set_max_distance(&sound->sound, fmaxf(minDistance, maxDistance));
    ma_sound_set_attenuation_model(&sound->sound,
        rolloffMode == 0 ? ma_attenuation_model_linear :
        rolloffMode == 2 ? ma_attenuation_model_exponential : ma_attenuation_model_inverse);
}

KINE_AUDIO_API int Kine_Audio_SetEffect(
    KineAudioSound* sound, int effectType, int enabled,
    float a, float b, float c, float d, float e)
{
    ma_uint32 channels, sampleRate;
    if (!sound || !g_initialized || effectType < 0 || effectType > 4) return 0;
    channels = ma_engine_get_channels(&g_engine);
    sampleRate = ma_engine_get_sample_rate(&g_engine);
    if (effectType == 0 && sound->reverbInitialized) {
        sound->reverbEnabled = enabled != 0;
        verblib_set_room_size(&sound->reverb.reverb, kine_clamp(a, 0, 1));
        verblib_set_damping(&sound->reverb.reverb, kine_clamp(b, 0, 1));
        verblib_set_wet(&sound->reverb.reverb, kine_clamp(c, 0, 1));
        verblib_set_dry(&sound->reverb.reverb, kine_clamp(d, 0, 1));
        verblib_set_width(&sound->reverb.reverb, kine_clamp(e, 0, 1));
    } else if (effectType == 1 && sound->echoInitialized) {
        ma_delay_node_config config;
        sound->echoEnabled = enabled != 0;
        kine_audio_detach_graph(sound);
        ma_delay_node_uninit(&sound->echo, NULL);
        config = ma_delay_node_config_init(channels, sampleRate,
            (ma_uint32)(sampleRate * kine_clamp(a, 0.001f, 2.0f)), kine_clamp(b, 0, 0.99f));
        config.delay.wet = kine_clamp(c, 0, 1);
        config.delay.dry = kine_clamp(d, 0, 1);
        sound->echoInitialized = ma_delay_node_init(ma_engine_get_node_graph(&g_engine), &config, NULL, &sound->echo) == MA_SUCCESS;
    } else if (effectType == 2 && sound->eqLowInitialized && sound->eqMidInitialized && sound->eqHighInitialized) {
        ma_peak_config config;
        sound->equalizerEnabled = enabled != 0;
        config = ma_peak2_config_init(ma_format_f32, channels, sampleRate, kine_clamp(a, -80, 20), 1.0, 200.0);
        ma_peak_node_reinit(&config, &sound->eqLow);
        config = ma_peak2_config_init(ma_format_f32, channels, sampleRate, kine_clamp(b, -80, 20), 1.0, 1000.0);
        ma_peak_node_reinit(&config, &sound->eqMid);
        config = ma_peak2_config_init(ma_format_f32, channels, sampleRate, kine_clamp(c, -80, 20), 1.0, 6000.0);
        ma_peak_node_reinit(&config, &sound->eqHigh);
    } else if (effectType == 3 && sound->lowPassInitialized) {
        ma_lpf_config config = ma_lpf_config_init(ma_format_f32, channels, sampleRate, kine_clamp(a, 20, sampleRate * 0.49f), 2);
        sound->lowPassEnabled = enabled != 0;
        ma_lpf_node_reinit(&config, &sound->lowPass);
    } else if (effectType == 4 && sound->highPassInitialized) {
        ma_hpf_config config = ma_hpf_config_init(ma_format_f32, channels, sampleRate, kine_clamp(a, 20, sampleRate * 0.49f), 2);
        sound->highPassEnabled = enabled != 0;
        ma_hpf_node_reinit(&config, &sound->highPass);
    } else {
        return 0;
    }
    kine_audio_rebuild_graph(sound);
    return 1;
}
