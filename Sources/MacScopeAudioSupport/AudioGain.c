#include "MacScopeAudioSupport.h"
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Audio gain must be lock-free");
_Static_assert(sizeof(float) == sizeof(uint32_t), "Audio gain requires 32-bit floats");

struct MacScopeAudioGain {
    _Atomic(uint32_t) bits;
};

MacScopeAudioGain *MacScopeAudioGainCreate(float value) {
    MacScopeAudioGain *storage = malloc(sizeof(*storage));
    if (storage) {
        uint32_t bits;
        memcpy(&bits, &value, sizeof(bits));
        atomic_init(&storage->bits, bits);
    }
    return storage;
}

void MacScopeAudioGainDestroy(MacScopeAudioGain *storage) {
    free(storage);
}

float MacScopeAudioGainGet(const MacScopeAudioGain *storage) {
    uint32_t bits = atomic_load_explicit(&storage->bits, memory_order_relaxed);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

void MacScopeAudioGainSet(MacScopeAudioGain *storage, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    atomic_store_explicit(&storage->bits, bits, memory_order_relaxed);
}
