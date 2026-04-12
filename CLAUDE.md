# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hush is a native iOS focus sounds app built with SwiftUI and AVFoundation. It mixes real-time DSP noise generators, brainwave entrainment (binaural/isochronic/monaural beats), and 80+ looping ambient sound samples into a layered soundscape with up to 6 simultaneous sources.

## Build & Test

- Open `hush.xcodeproj` in Xcode 16+ and build for **iOS 18+**.
- Do NOT run `xcodebuild` or other Xcode CLI commands. The user will build and report errors from Xcode.
- Tests run in CI via GitHub Actions on `macos-26` with the `hush` scheme targeting iOS Simulator.

## Architecture

### Audio Pipeline

`AudioEngine` (singleton) owns the `AVAudioEngine` graph. Two playback paths:

1. **Generated sources** — Real-time DSP via `AVAudioSourceNode` render callbacks. Each generator conforms to the `SoundGenerator` protocol (`generateMono`/`generateStereo`). Generators live in `Audio/Generators/` (white/pink/brown/gray noise, speech masking, binaural beats, isochronic tones, monaural beats, pure tone, drone).
2. **Sample sources** — `AVAudioPlayerNode` with looping `AVAudioPCMBuffer`. Buffers are lazy-loaded on a background queue and cached in an `NSCache` (200MB limit). `SampleLoopPlayer` handles file loading and sample-rate conversion.

All audio-thread code is `nonisolated` and `Sendable`; generator references are passed to render callbacks via `Unmanaged` to avoid ARC on the real-time thread. Volume fading uses `mixerNode.outputVolume` (never in render callbacks).

### DSP Utilities

- `AudioRNG` — fast PRNG for noise generators (xoshiro256++)
- `DCBlockingFilter` — removes DC offset from brown noise output

### Data Model

- `SoundType` (enum) — all generator types + legacy sample types + `sampleAsset` for registry-based sounds
- `SoundSource` — identifiable, codable model for one active sound layer (type, volume, parameters, optional asset ID)
- `SoundAsset` / `SoundAssetRegistry` — static registry of all bundled ambient sound files with metadata (category, display name, icon)
- `Preset` — built-in and user-saved (via SwiftData `SavedPreset`) sound combinations

### App Layer

- `PlayerViewModel` (`@Observable`, `@MainActor`) — central state: active sources, playback, preset management, focus timer with fade-out, session persistence via `UserDefaults`, Control Center/lock screen integration via `MPRemoteCommandCenter`
- Views follow MVVM: `PlayerView`, `MixerView`, `PresetSelector`, `TimerView`, `SettingsView`, `OnboardingView`
- Theme constants in `HushTheme`

### Key Constraints

- `AudioEngine` asserts main thread for all public API calls (`assertMainThread`)
- Binaural beats require headphones; the engine auto-pauses and warns on disconnect
- Legacy `SoundType` cases (rain, ocean, etc.) are kept for backward compatibility with saved presets; they map to `SoundAssetRegistry` assets via `defaultAssetID`
- Sound files are bundled mp3s under `Resources/MoodistSounds/` (organized by category)
