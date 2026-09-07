# Seance Shell

Seance Shell is a native Android and iOS SSH client powered by Ghostty's terminal engine.

Website: [founder.fail](https://founder.fail)

The project is under active development and is not yet ready for public release. Android is the current product-validation reference; iOS is progressing toward the same shared product contracts. See the [roadmap](docs/ROADMAP.md) for capability status and the [Android release checklist](docs/RELEASE_CHECKLIST.md) for remaining launch blockers.

```text
android/  Android application
ios/      iOS application
docs/     Shared product, architecture, security, and decision records
```

Start with the [documentation index](docs/README.md). Architecture, security policy, product scope, platform parity, and durable decisions are maintained there.

## Build

- [Android development](docs/platforms/ANDROID.md): JDK 17, the Android SDK/NDK, and the checked-in Gradle wrapper.
- [iOS development](docs/platforms/IOS.md): Apple Silicon macOS, Xcode 16 or newer, and XcodeGen.

The Ghostty terminal engine is pinned as a Git submodule. Initialize it before rebuilding native artifacts:

```sh
git submodule update --init
```

Platform documents contain the authoritative build and verification commands.

## Project Status and Licensing

Release readiness is tracked explicitly rather than implied by a successful development build. Security, accessibility, device validation, legal review, CI, and store-delivery work remain before the first public release.

Third-party attribution is available in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The repository does not yet declare a license for the application source; selecting one and adding a root `LICENSE` file is a tracked release blocker.
