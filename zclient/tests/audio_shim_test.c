/* Deterministic shim regression tests. Only the null backend is compiled:
 * this executable cannot open a real speaker or request microphone access. */
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#define MA_ENABLE_NULL
#include "../vendor/miniaudio_impl.c"
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>

static atomic_uint callbacks;
static atomic_uint capture_callbacks;

static void fill(void *user, float *out, float *in, unsigned int frames)
{
    (void)user;
    if (out != NULL) memset(out, 0, frames * sizeof(float));
    if (in != NULL) atomic_fetch_add(&capture_callbacks, 1);
    atomic_fetch_add(&callbacks, 1);
}

int main(void)
{
    void *handle = NULL;
    ma_context ctx;
    ma_device_info *playback = NULL, *capture = NULL;
    ma_uint32 playback_count = 0, capture_count = 0;
    ma_device_id id;
    const char *missing = "this-device-does-not-exist";
    assert(zc_playback_device_open(NULL, 48000, 480, fill, NULL, NULL) == MA_INVALID_ARGS);
    assert(zc_playback_device_open(&handle, 48000, 480, NULL, NULL, NULL) == MA_INVALID_ARGS);
    assert(handle == NULL);
    assert(strcmp(zc_error_string(MA_INVALID_ARGS), ma_result_description(MA_INVALID_ARGS)) == 0);
    assert(strcmp(zc_error_string(MA_OUT_OF_MEMORY), ma_result_description(MA_OUT_OF_MEMORY)) == 0);
    assert(zc_name_contains("Built-in Speakers", "SPEAKERS"));
    assert(!zc_name_contains("Built-in Speakers", "microphone"));

    assert(ma_context_init(NULL, 0, NULL, &ctx) == MA_SUCCESS);
    assert(ma_context_get_devices(&ctx, &playback, &playback_count,
                                   &capture, &capture_count) == MA_SUCCESS);
    assert(zc_resolve_device_id(playback, playback_count, "", &id) == MA_INVALID_ARGS);
    assert(zc_resolve_device_id(playback, playback_count, "0", &id) == 0);
    assert(zc_resolve_device_id(capture, capture_count, "0", &id) == 0);
    assert(zc_resolve_device_id(playback, playback_count,
                                "999999999999999999999999999999", &id) == MA_DOES_NOT_EXIST);
    assert(zc_resolve_device_id(playback, playback_count, missing, &id) == MA_DOES_NOT_EXIST);
    ma_context_uninit(&ctx);
    assert(zc_playback_device_open(&handle, 48000, 480, fill, NULL, missing) == MA_DOES_NOT_EXIST);
    assert(handle == NULL);
    assert(zc_device_open(&handle, 48000, 480, fill, NULL, "0") == 0);
    zc_device_close(handle);

    atomic_store(&callbacks, 0);
    atomic_store(&capture_callbacks, 0);
    assert(zc_playback_device_open(&handle, 48000, 480, fill, NULL, "0") == 0);
    assert(strcmp(zc_backend_name(handle), "Null") == 0);
    for (unsigned int i = 0; i < 100 && atomic_load(&callbacks) == 0; ++i) ma_sleep(10);
    zc_device_close(handle);
    assert(atomic_load(&callbacks) > 0);
    assert(atomic_load(&capture_callbacks) == 0);
    puts("audio shim: null-backend playback, device IDs, and signed errors pass");
    return 0;
}
