#ifndef MACSCOPE_AUDIO_SUPPORT_H
#define MACSCOPE_AUDIO_SUPPORT_H

typedef struct MacScopeAudioGain MacScopeAudioGain;

MacScopeAudioGain * _Nullable MacScopeAudioGainCreate(float value);
void MacScopeAudioGainDestroy(MacScopeAudioGain * _Nonnull storage);
float MacScopeAudioGainGet(const MacScopeAudioGain * _Nonnull storage);
void MacScopeAudioGainSet(MacScopeAudioGain * _Nonnull storage, float value);

#endif
