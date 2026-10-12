// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

#include "audio_mute.h"

#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <windows.h>

namespace {

template <typename T>
void SafeRelease(T** punk) {
  if (punk && *punk) {
    (*punk)->Release();
    *punk = nullptr;
  }
}

}  // namespace

std::optional<bool> QueryDefaultCaptureMuted() {
  IMMDeviceEnumerator* enumerator = nullptr;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr) || enumerator == nullptr) {
    return std::nullopt;
  }

  IMMDevice* device = nullptr;
  hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
  SafeRelease(&enumerator);
  if (FAILED(hr) || device == nullptr) {
    return std::nullopt;
  }

  IAudioEndpointVolume* volume = nullptr;
  hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(&volume));
  SafeRelease(&device);
  if (FAILED(hr) || volume == nullptr) {
    return std::nullopt;
  }

  BOOL muted = FALSE;
  hr = volume->GetMute(&muted);
  if (FAILED(hr)) {
    SafeRelease(&volume);
    return std::nullopt;
  }
  if (muted) {
    SafeRelease(&volume);
    return true;
  }

  float level = 1.0f;
  hr = volume->GetMasterVolumeLevelScalar(&level);
  SafeRelease(&volume);
  if (FAILED(hr)) {
    return std::nullopt;
  }
  // Match Linux: Mute:no but volume 0% still captures silence.
  return level <= 0.0f;
}
