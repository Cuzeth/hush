# Contributing to Hush

Thanks for your interest in contributing! Here's everything you need to get started.

## Building

1. Clone the repo
2. Open `hush.xcodeproj` in Xcode 16+
3. Build for iOS 18+ (simulator or device)

No third-party dependencies — everything builds out of the box.

## Project Structure

```
hush/
  App/            App entry point
  Audio/          Audio engine, generators, DSP utilities
    Generators/   Noise generators and sample player
  Models/         Data models (SoundType, SoundSource, Preset)
  ViewModels/     PlayerViewModel (central state)
  Views/          SwiftUI views and theme
  Utilities/      Constants and configuration
  Resources/      Bundled sound files
hushTests/        Unit tests
```

## Making Changes

- **Audio generators** conform to the `SoundGenerator` protocol and must be real-time safe (no heap allocation, no locks, no syscalls in render callbacks)
- **All AudioEngine public API** asserts main thread
- **Views** follow MVVM — state lives in `PlayerViewModel`
- **Sound assets** must be CC0, CC-BY, or similarly permissive — include license proof in your PR

## Code Style

- Swift 6 strict concurrency
- No third-party dependencies unless absolutely necessary
- Prefer `@ScaledMetric` and `accessibilityLabel` on all interactive elements

## Pull Request Checklist

- [ ] Builds without warnings
- [ ] Existing tests pass
- [ ] New logic has test coverage where practical
- [ ] VoiceOver labels on new interactive elements
- [ ] No new network requests or data collection
- [ ] Sound assets include license documentation

## Reporting Bugs

Open an issue with:
- Device and iOS version
- Audio output (speaker, headphones, Bluetooth)
- Steps to reproduce
- What happened vs. what you expected

## Sound Requests

Want to add a new sound? Open an issue with:
- Category (rain, nature, urban, etc.)
- Source or recording details
- License (must be CC0, CC-BY, Pixabay, or self-recorded)

## License

By contributing, you agree that your contributions will be licensed under GPL v3.0.
