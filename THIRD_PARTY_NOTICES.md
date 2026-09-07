# Third-Party Notices

Seance Shell includes third-party open source software. Component names and trademarks belong to their respective owners and do not imply endorsement.

The Android app distributes an offline copy of the applicable license text at [`android/app/src/main/assets/open_source_notices.txt`](android/app/src/main/assets/open_source_notices.txt). It is available in the app from **Settings > Open source licenses**.

## Android Runtime Inventory

This inventory was checked against `debugRuntimeClasspath` on September 7, 2026. It must be regenerated and compared with the final release AAB before release.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| Ghostty / `libghostty-vt` | pinned submodule revision | MIT | <https://github.com/ghostty-org/ghostty> |
| Kotlin Standard Library | 2.2.10 | Apache-2.0 | <https://github.com/JetBrains/kotlin> |
| JetBrains Annotations | 13.0 | Apache-2.0 | <https://github.com/JetBrains/java-annotations> |
| SSHJ | 0.40.0 | Apache-2.0 | <https://github.com/hierynomus/sshj> |
| ASN.1 | 0.6.0 | Apache-2.0 | <https://github.com/hierynomus/asn-one> |
| Bouncy Castle Java | 1.80.2 | MIT-style | <https://www.bouncycastle.org/> |
| SLF4J | 2.0.17 | MIT | <https://www.slf4j.org/> |

The three Bouncy Castle artifacts resolved in the runtime graph are `bcprov-jdk18on`, `bcpkix-jdk18on`, and `bcutil-jdk18on`. The complete Apache-2.0, Bouncy Castle, and SLF4J license texts are included in the offline Android notice file. Ghostty's authoritative license is also retained at [`android/third_party/ghostty/LICENSE`](android/third_party/ghostty/LICENSE).

## iOS Inventory Status

The iOS app directly depends on the pinned Ghostty XCFramework and Citadel 0.12.1. Citadel declares runtime dependencies on a `swift-nio-ssh` fork, SwiftNIO, SwiftLog, BigInt, and Swift Crypto. There is no checked-in `Package.resolved`, so exact transitive versions and notices cannot yet be certified. Generate the Xcode project on macOS, resolve dependencies, and add the final iOS inventory and offline in-app notices before App Store distribution.

## Release Verification

The checked-in inventory is not a substitute for inspecting the shipped artifacts. Before each release:

1. Resolve dependencies from the tagged release commit.
2. Inspect the AAB, APK, or app archive for all packaged JVM, native, Swift, resource, font, and transitive components.
3. Compare the artifact inventory with this file and each upstream `LICENSE` or `NOTICE` file.
4. Update the bundled offline notices and preserve any required attribution statements.
5. Archive the inventory, SBOM, notices, source revision, and artifact checksums together.
