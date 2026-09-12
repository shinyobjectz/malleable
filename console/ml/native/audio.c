/*
 * audio.c -- the microphone and the speaker (spec/ml.md, "Audio").
 *
 * Built with miniaudio (console/ml/fetch-miniaudio.sh) when ML_AUDIO is defined; without
 * it, ml.audio_available() is false and the models still run on buffers from files.
 *
 * A device runs on miniaudio's own thread. Between that thread and Lua sits a ring of
 * samples with one writer and one reader, so neither ever waits on the other: the
 * microphone's thread writes what it hears and Lua reads it when it likes; Lua writes
 * what the speaker is to say and the speaker's thread plays it as it needs it. Samples are
 * f32 mono at the rate asked for; miniaudio converts from whatever the hardware runs at.
 */
#include "ml.h"

#include <string.h>
#ifdef _WIN32
#  include <windows.h>
#else
#  include <time.h>
#endif

/* ml.now() -> seconds on a clock that only goes forward: wall time, for timing a model
 * (os.clock counts the CPU time of every thread, so a threaded graph looks slower). */
static int l_now(lua_State *L) {
#ifdef _WIN32
  LARGE_INTEGER f, c;
  QueryPerformanceFrequency(&f); QueryPerformanceCounter(&c);
  lua_pushnumber(L, (lua_Number)c.QuadPart / (lua_Number)f.QuadPart);
#else
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  lua_pushnumber(L, (lua_Number)t.tv_sec + (lua_Number)t.tv_nsec * 1e-9);
#endif
  return 1;
}

/* ml.sleep(seconds) -- waits, for a loop that polls the microphone */
static int l_sleep(lua_State *L) {
  double s = luaL_checknumber(L, 1);
  if (s <= 0) return 0;
#ifdef _WIN32
  Sleep((DWORD)(s * 1000));
#else
  struct timespec t = { (time_t)s, (long)((s - (double)(time_t)s) * 1e9) };
  while (nanosleep(&t, &t) != 0) {}
#endif
  return 0;
}

#ifdef ML_AUDIO

#define MA_NO_ENCODING
#define MA_NO_DECODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#define ML_MIC     "ml.microphone"
#define ML_SPEAKER "ml.speaker"

typedef struct ml_audio {
  ma_context context;
  ma_device device;
  ma_pcm_rb ring;
  bool capture;
  bool has_context, has_device, has_ring, started;
  ma_uint32 rate;
  /* written by the device's thread, read by Lua */
  volatile ma_uint64 dropped;      /* heard while the ring was full: lost */
  volatile ma_uint64 played;       /* samples the speaker has played */
  volatile ma_uint32 clear;        /* Lua asks the speaker's thread to drop what is queued */
  char name[256];
} ml_audio;

static void on_data(ma_device *d, void *out, const void *in, ma_uint32 frames) {
  ml_audio *a = (ml_audio *)d->pUserData;
  if (a->capture) {
    const float *src = (const float *)in;
    ma_uint32 left = frames;
    while (left > 0) {
      ma_uint32 n = left;
      void *p;
      if (ma_pcm_rb_acquire_write(&a->ring, &n, &p) != MA_SUCCESS || n == 0) break;
      memcpy(p, src, n * sizeof(float));
      ma_pcm_rb_commit_write(&a->ring, n);
      src += n; left -= n;
    }
    a->dropped += left;
    return;
  }
  float *dst = (float *)out;
  if (a->clear) {
    ma_pcm_rb_seek_read(&a->ring, ma_pcm_rb_available_read(&a->ring));
    a->clear = 0;
  }
  ma_uint32 left = frames;
  while (left > 0) {
    ma_uint32 n = left;
    void *p;
    if (ma_pcm_rb_acquire_read(&a->ring, &n, &p) != MA_SUCCESS || n == 0) break;
    memcpy(dst, p, n * sizeof(float));
    ma_pcm_rb_commit_read(&a->ring, n);
    dst += n; left -= n;
  }
  if (left > 0) memset(dst, 0, left * sizeof(float));
  a->played += frames - left;
}

static void audio_close(ml_audio *a) {
  if (a->has_device) { ma_device_uninit(&a->device); a->has_device = false; }
  if (a->has_ring) { ma_pcm_rb_uninit(&a->ring); a->has_ring = false; }
  if (a->has_context) { ma_context_uninit(&a->context); a->has_context = false; }
  a->started = false;
}

static ml_audio *check_audio(lua_State *L, int i) {
  ml_audio *a = (ml_audio *)luaL_testudata(L, i, ML_MIC);
  if (!a) a = (ml_audio *)luaL_checkudata(L, i, ML_SPEAKER);
  if (!a->has_device) luaL_error(L, "ml: this %s was closed", a->capture ? "microphone" : "speaker");
  return a;
}

/* The context for one backend by miniaudio's name ("coreaudio", "wasapi", "alsa",
 * "pulseaudio", "webaudio", "null"), or the platform's default order. */
static const struct { const char *name; ma_backend backend; } backends[] = {
  { "coreaudio", ma_backend_coreaudio }, { "wasapi", ma_backend_wasapi }, { "dsound", ma_backend_dsound },
  { "alsa", ma_backend_alsa }, { "pulseaudio", ma_backend_pulseaudio }, { "jack", ma_backend_jack },
  { "aaudio", ma_backend_aaudio }, { "webaudio", ma_backend_webaudio }, { "null", ma_backend_null },
};

static void open_context(lua_State *L, ml_audio *a, const char *backend) {
  ma_result r;
  if (backend) {
    size_t i, n = sizeof(backends) / sizeof(backends[0]);
    for (i = 0; i < n && strcmp(backends[i].name, backend) != 0; i++) {}
    if (i == n || !ma_is_backend_enabled(backends[i].backend)) {
      luaL_error(L, "ml: no audio backend %s (coreaudio, wasapi, dsound, alsa, pulseaudio, jack, aaudio, webaudio, null)", backend);
    }
    ma_backend b = backends[i].backend;
    r = ma_context_init(&b, 1, NULL, &a->context);
  } else {
    r = ma_context_init(NULL, 0, NULL, &a->context);
  }
  if (r != MA_SUCCESS) luaL_error(L, "ml: the audio system would not start (%s)", ma_result_description(r));
  a->has_context = true;
}

/* A device whose name holds `want`, of the kind asked for; NULL for the default. */
static const ma_device_id *find_device(lua_State *L, ml_audio *a, const char *want, ma_device_info *keep) {
  if (!want) return NULL;
  ma_device_info *play, *cap;
  ma_uint32 n_play, n_cap;
  if (ma_context_get_devices(&a->context, &play, &n_play, &cap, &n_cap) != MA_SUCCESS) {
    luaL_error(L, "ml: the audio devices could not be listed");
  }
  ma_device_info *list = a->capture ? cap : play;
  ma_uint32 n = a->capture ? n_cap : n_play;
  for (ma_uint32 i = 0; i < n; i++) {
    if (strstr(list[i].name, want)) { *keep = list[i]; return &keep->id; }
  }
  luaL_error(L, "ml: no %s named like \"%s\" (ml.audio_devices() lists them)", a->capture ? "microphone" : "speaker", want);
  return NULL;
}

static int open_audio(lua_State *L, bool capture) {
  if (!lua_isnoneornil(L, 1)) luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer rate = 16000, seconds = capture ? 10 : 30;
  const char *backend = NULL, *device = NULL;
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "rate"); if (!lua_isnil(L, -1)) rate = ml_checkint(L, -1); lua_pop(L, 1);
    lua_getfield(L, 1, "seconds"); if (!lua_isnil(L, -1)) seconds = ml_checkint(L, -1); lua_pop(L, 1);
    lua_getfield(L, 1, "backend"); backend = lua_tostring(L, -1); lua_pop(L, 1);
    lua_getfield(L, 1, "device"); device = lua_tostring(L, -1); lua_pop(L, 1);
  }
  if (rate < 8000 || rate > 192000) luaL_error(L, "ml: a rate of %d samples a second is outside 8000 to 192000", (int)rate);
  if (seconds < 1) seconds = 1;

  ml_audio *a = (ml_audio *)lua_newuserdata(L, sizeof(ml_audio));
  memset(a, 0, sizeof(*a));
  a->capture = capture;
  a->rate = (ma_uint32)rate;
  luaL_setmetatable(L, capture ? ML_MIC : ML_SPEAKER);

  open_context(L, a, backend);
  if (ma_pcm_rb_init(ma_format_f32, 1, (ma_uint32)(rate * seconds), NULL, NULL, &a->ring) != MA_SUCCESS) {
    audio_close(a);
    return luaL_error(L, "ml: no memory for %d seconds of audio", (int)seconds);
  }
  a->has_ring = true;

  ma_device_info info;
  const ma_device_id *id = find_device(L, a, device, &info);
  ma_device_config cfg = ma_device_config_init(capture ? ma_device_type_capture : ma_device_type_playback);
  if (capture) {
    cfg.capture.format = ma_format_f32; cfg.capture.channels = 1; cfg.capture.pDeviceID = id;
  } else {
    cfg.playback.format = ma_format_f32; cfg.playback.channels = 1; cfg.playback.pDeviceID = id;
  }
  cfg.sampleRate = a->rate;
  cfg.dataCallback = on_data;
  cfg.pUserData = a;
  ma_result r = ma_device_init(&a->context, &cfg, &a->device);
  if (r != MA_SUCCESS) {
    audio_close(a);
    return luaL_error(L, "ml: the %s would not open (%s)", capture ? "microphone" : "speaker", ma_result_description(r));
  }
  a->has_device = true;
  ma_device_get_name(&a->device, capture ? ma_device_type_capture : ma_device_type_playback, a->name, sizeof(a->name), NULL);
  return 1;
}

/* ml.microphone{ rate = 16000, seconds = 10, device = "name", backend = "null" } */
static int l_microphone(lua_State *L) { return open_audio(L, true); }
/* ml.speaker{ rate = 24000, seconds = 30, device = "name", backend = "null" } */
static int l_speaker(lua_State *L) { return open_audio(L, false); }

static int audio_start(lua_State *L) {
  ml_audio *a = check_audio(L, 1);
  if (!a->started) {
    ma_result r = ma_device_start(&a->device);
    if (r != MA_SUCCESS) return luaL_error(L, "ml: the %s would not start (%s)", a->capture ? "microphone" : "speaker", ma_result_description(r));
    a->started = true;
  }
  return 0;
}

static int audio_stop(lua_State *L) {
  ml_audio *a = check_audio(L, 1);
  if (a->started) { ma_device_stop(&a->device); a->started = false; }
  return 0;
}

static int audio_close_l(lua_State *L) {
  ml_audio *a = (ml_audio *)luaL_testudata(L, 1, ML_MIC);
  if (!a) a = (ml_audio *)luaL_checkudata(L, 1, ML_SPEAKER);
  audio_close(a);
  return 0;
}

static int audio_rate(lua_State *L) { lua_pushinteger(L, check_audio(L, 1)->rate); return 1; }
static int audio_name(lua_State *L) { lua_pushstring(L, check_audio(L, 1)->name); return 1; }

/* mic:available() -> samples heard and not yet read */
static int mic_available(lua_State *L) {
  ml_audio *a = check_audio(L, 1);
  lua_pushinteger(L, (lua_Integer)ma_pcm_rb_available_read(&a->ring));
  return 1;
}

/* mic:read([max]) -> a buffer of what has been heard since the last read, up to max */
static int mic_read(lua_State *L) {
  ml_audio *a = check_audio(L, 1);
  ma_uint32 have = ma_pcm_rb_available_read(&a->ring);
  if (!lua_isnoneornil(L, 2)) {
    int64_t max = ml_checkint(L, 2);
    if (max < have) have = max < 0 ? 0 : (ma_uint32)max;
  }
  ml_buffer *b = ml_newbuffer(L, ML_F32, have);
  ma_uint32 got = 0;
  while (got < have) {
    ma_uint32 n = have - got;
    void *p;
    if (ma_pcm_rb_acquire_read(&a->ring, &n, &p) != MA_SUCCESS || n == 0) break;
    memcpy(b->data.f + got, p, n * sizeof(float));
    ma_pcm_rb_commit_read(&a->ring, n);
    got += n;
  }
  b->n = got;
  return 1;
}

static int mic_dropped(lua_State *L) { lua_pushinteger(L, (lua_Integer)check_audio(L, 1)->dropped); return 1; }

/* speaker:write(buffer) -> how many samples it took; fewer than given when the queue is full */
static int speaker_write(lua_State *L) {
  ml_audio *a = check_audio(L, 1);
  ml_buffer *b = ml_checkbuffer(L, 2);
  if (b->type != ML_F32) return luaL_error(L, "speaker:write: the buffer holds ints; give it f32 samples");
  ma_uint32 put = 0, want = (ma_uint32)b->n;
  while (put < want) {
    ma_uint32 n = want - put;
    void *p;
    if (ma_pcm_rb_acquire_write(&a->ring, &n, &p) != MA_SUCCESS || n == 0) break;
    memcpy(p, b->data.f + put, n * sizeof(float));
    ma_pcm_rb_commit_write(&a->ring, n);
    put += n;
  }
  lua_pushinteger(L, put);
  return 1;
}

/* speaker:queued() -> samples written and not yet played */
static int speaker_queued(lua_State *L) {
  ml_audio *a = check_audio(L, 1);
  lua_pushinteger(L, a->clear ? 0 : (lua_Integer)ma_pcm_rb_available_read(&a->ring));
  return 1;
}

/* speaker:clear() -- drops what is queued: the person started talking */
static int speaker_clear(lua_State *L) {
  ml_audio *a = check_audio(L, 1);
  if (a->started) a->clear = 1;
  else ma_pcm_rb_reset(&a->ring);
  return 0;
}

static int speaker_played(lua_State *L) { lua_pushinteger(L, (lua_Integer)check_audio(L, 1)->played); return 1; }

static int audio_gc(lua_State *L) {
  ml_audio *a = (ml_audio *)lua_touserdata(L, 1);
  if (a) audio_close(a);
  return 0;
}

/* ml.audio_devices([backend]) -> { { name =, kind = "microphone" | "speaker", default = bool } } */
static int l_audio_devices(lua_State *L) {
  const char *backend = luaL_optstring(L, 1, NULL);
  ml_audio a;
  memset(&a, 0, sizeof(a));
  open_context(L, &a, backend);
  ma_device_info *play, *cap;
  ma_uint32 n_play, n_cap;
  ma_result r = ma_context_get_devices(&a.context, &play, &n_play, &cap, &n_cap);
  if (r != MA_SUCCESS) { ma_context_uninit(&a.context); return luaL_error(L, "ml: the audio devices could not be listed"); }
  lua_newtable(L);
  int k = 0;
  for (int pass = 0; pass < 2; pass++) {
    ma_device_info *list = pass ? play : cap;
    ma_uint32 n = pass ? n_play : n_cap;
    for (ma_uint32 i = 0; i < n; i++) {
      lua_newtable(L);
      lua_pushstring(L, list[i].name); lua_setfield(L, -2, "name");
      lua_pushstring(L, pass ? "speaker" : "microphone"); lua_setfield(L, -2, "kind");
      lua_pushboolean(L, list[i].isDefault); lua_setfield(L, -2, "default");
      lua_rawseti(L, -2, ++k);
    }
  }
  ma_context_uninit(&a.context);
  return 1;
}

static const luaL_Reg mic_methods[] = {
  { "start", audio_start }, { "stop", audio_stop }, { "close", audio_close_l },
  { "read", mic_read }, { "available", mic_available }, { "dropped", mic_dropped },
  { "rate", audio_rate }, { "name", audio_name }, { NULL, NULL },
};

static const luaL_Reg speaker_methods[] = {
  { "start", audio_start }, { "stop", audio_stop }, { "close", audio_close_l },
  { "write", speaker_write }, { "queued", speaker_queued }, { "clear", speaker_clear },
  { "played", speaker_played }, { "rate", audio_rate }, { "name", audio_name }, { NULL, NULL },
};

#endif /* ML_AUDIO */

static int l_audio_available(lua_State *L) {
#ifdef ML_AUDIO
  lua_pushboolean(L, 1);
#else
  lua_pushboolean(L, 0);
#endif
  return 1;
}

#ifndef ML_AUDIO
static int l_no_audio(lua_State *L) {
  return luaL_error(L, "ml: this build has no audio; build with ML_AUDIO=ON (console/ml/build.sh)");
}
#endif

void ml_open_audio(lua_State *L) {
  lua_pushcfunction(L, l_now); lua_setfield(L, -2, "now");
  lua_pushcfunction(L, l_sleep); lua_setfield(L, -2, "sleep");
  lua_pushcfunction(L, l_audio_available);
  lua_setfield(L, -2, "audio_available");
#ifdef ML_AUDIO
  luaL_newmetatable(L, ML_MIC);
  lua_newtable(L); luaL_setfuncs(L, mic_methods, 0); lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, audio_gc); lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  luaL_newmetatable(L, ML_SPEAKER);
  lua_newtable(L); luaL_setfuncs(L, speaker_methods, 0); lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, audio_gc); lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  lua_pushcfunction(L, l_microphone); lua_setfield(L, -2, "microphone");
  lua_pushcfunction(L, l_speaker); lua_setfield(L, -2, "speaker");
  lua_pushcfunction(L, l_audio_devices); lua_setfield(L, -2, "audio_devices");
#else
  lua_pushcfunction(L, l_no_audio); lua_setfield(L, -2, "microphone");
  lua_pushcfunction(L, l_no_audio); lua_setfield(L, -2, "speaker");
  lua_pushcfunction(L, l_no_audio); lua_setfield(L, -2, "audio_devices");
#endif
}
