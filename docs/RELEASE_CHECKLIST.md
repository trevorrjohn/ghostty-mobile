# Android Initial Release Checklist

## Release Target

- Platform: Android first. iOS follows after core parity and App Store validation.
- Product name: `Seance Shell`.
- Rejected candidates: `RelayTTY` has an exact-name terminal-project collision; `Specter Shell` has substantial software, SSH, cybersecurity, and trademark crowding.
- Current application ID: `fail.founder.terminal`.
- Initial version: `0.1.0` (`versionCode` 2; version code 1 was consumed during Play App Signing setup).
- Release owner: Unassigned.
- Target release date: Unassigned.

## Exit Rule

Production rollout does not begin until every item marked **Launch blocker** is checked, has linked evidence, and has an owner. Deferred capabilities must be disabled or clearly described; a roadmap entry alone does not make an unsafe partial feature releasable.

## Name And Identity

- [x] Preliminary `RelayTTY` check completed September 7, 2026: no exact Google Play result, but an active exact-name terminal project exists at <https://github.com/1NC4NDESCENCE/relaytty> and `relaytty.com` is registered. Do not adopt this candidate without resolving the collision.
- [x] Preliminary `Specter Shell` check completed September 7, 2026: no exact mobile SSH app was found, but active `spectre-shell` and `spectre-ssh` projects, SpecterOps, an active `SPECTER` US software registration, and a pre-existing `SpecterShell` developer identity make the name difficult to search and defend. Avoid this candidate without professional clearance.
- [x] `Seance Shell` was selected after a preliminary exact-name check found no GitHub, Google Play, npm, or PyPI collision.
- [ ] **Launch blocker:** Complete formal trademark and confusingly similar-name clearance for `Seance Shell` before public distribution.
- [x] The product name does not imply endorsement by Ghostty; Ghostty is identified separately as the terminal engine.
- [x] The public app name is locked as `Seance Shell` for release assets and store copy.
- [x] `fail.founder.terminal` is the permanent Play application ID. It cannot be changed for the existing listing after launch.
- [x] Replace the old product display name in Android, iOS, website copy, accessibility labels, exports, notifications, and user-facing documentation.
- [ ] Produce final launcher, adaptive, monochrome, notification, and store icons.

## Scope Freeze

- [ ] **Launch blocker:** Define the exact supported authentication methods for 0.1.0.
- [ ] **Launch blocker:** Decide whether Tailscale SSH ships, remains labeled beta, or is disabled pending live policy/interruption validation.
- [ ] **Launch blocker:** Decide whether SFTP ships, remains labeled beta, or is disabled until key authentication, host-key rotation, interruption, document-provider, lifecycle, and TalkBack tests pass.
- [ ] **Launch blocker:** Complete real-device biometric enable/connect/disable/invalidation testing or disable biometric identity protection for 0.1.0.
- [ ] Record all intentionally deferred capabilities in the roadmap and release notes.
- [ ] Freeze user-facing behavior and strings before final accessibility, screenshot, and localization passes.

## Security And Privacy

- [x] Unknown and changed SSH host keys require explicit approval in the implementation.
- [x] Android backup is disabled in the manifest.
- [x] Passwords, passphrases, OTP responses, and challenge answers are designed as transient values.
- [x] Diagnostics use a bounded allowlist and encrypted local storage.
- [ ] **Launch blocker:** Run and document a release security review covering logs, crashes, clipboard, screenshots, notifications, intents, content URIs, secure-store corruption, and credential lifetime.
- [ ] **Launch blocker:** Validate unknown-key trust, trust reuse, changed-key blocking, concurrent approvals, removal, and normalization against a live OpenSSH server.
- [ ] **Launch blocker:** Validate password, unencrypted key, encrypted key, keyboard-interactive, wrong credential, cancellation, and retry paths against disposable servers.
- [ ] **Launch blocker:** Confirm every exported Android component is intentional and protected.
- [ ] Review `REQUEST_INSTALL_PACKAGES` and in-app APK installation policy before public release.
- [ ] **Launch blocker:** Publish a plain-language privacy policy at a stable HTTPS URL.
- [ ] **Launch blocker:** Complete the Play Data safety form from verified behavior, not intended behavior.
- [ ] Verify no hostnames, usernames, paths, terminal contents, credentials, keys, clipboard contents, or screenshots enter logs, diagnostics, analytics, notifications, or feedback context.
- [ ] Run dependency, secret, and vulnerability scans against the release commit and archive the reports.

## Open Source And Legal

- [ ] **Launch blocker:** Complete the runtime dependency inventory from the final release AAB, including native and transitive dependencies.
- [ ] **Launch blocker:** Verify license compatibility and preserve every required copyright, license, and NOTICE statement.
- [x] Add an in-app Open source licenses screen reachable from Settings without a network connection.
- [ ] **Launch blocker:** Include Ghostty attribution without implying endorsement or trademark permission.
- [ ] **Launch blocker:** Choose the license for this repository/application and add a root `LICENSE` file before presenting the source distribution as open source.
- [ ] Generate and archive an SBOM for the exact release artifact.
- [x] Add privacy-policy, support, source-code, and open-source-notice links to the website.
- [ ] Add the published privacy-policy, support, source-code, and open-source-notice URLs to the Play listing.

## Functional Validation

- [x] Debug unit tests, lint, APK assembly, and Android-test APK assembly pass in the current development environment.
- [x] A local release build assembles successfully when the environment-backed signing configuration is supplied.
- [ ] **Launch blocker:** Run `testDebugUnitTest`, `lintDebug`, `assembleRelease`, and release-focused checks from a clean clone in CI.
- [ ] **Launch blocker:** Run connected tests on API 29 and API 36 emulators plus at least one supported physical Pixel.
- [ ] **Launch blocker:** Validate arm64 physical-device and x86_64 emulator artifacts.
- [ ] **Launch blocker:** Verify native libraries and the packaged AAB satisfy Android 16 KB page-size requirements.
- [ ] **Launch blocker:** Run the disposable live SSH/SFTP suite from the release commit.
- [ ] Validate host creation, edit, duplicate, deletion, startup-command persistence and once-per-shell execution, identity migration, trust removal, and process restart.
- [ ] Validate terminal Unicode, colors, cursor, resize, scrollback, selection, copy, safe paste, search, links, and shell integration.
- [ ] Validate software keyboards from Gboard and one materially different IME.
- [ ] Validate hardware keyboard letters, punctuation, Ctrl, Alt/AltGr, Shift, navigation, function, numpad, and lock keys.
- [ ] Validate tmux/screen keyboard, mouse, resize, selection override, and reconnect workflows against live hosts.
- [ ] Validate SFTP browse, hostile names, long names, sort/search, upload/download conflicts, cancellation cleanup, document providers, and server interruption if SFTP ships.

## Lifecycle And Reliability

- [ ] **Launch blocker:** Automate and validate rotation during connect, trust, authentication, terminal use, retry, biometric prompts, SFTP browsing, and transfer.
- [ ] **Launch blocker:** Validate background/foreground behavior, notification actions, task removal, process death, and explicit disconnect.
- [ ] **Launch blocker:** Validate Wi-Fi, cellular, VPN, route loss, captive/blocking transitions, and exhausted reconnect behavior.
- [ ] **Launch blocker:** Confirm reconnect always creates and labels a new remote shell.
- [ ] Validate multiple simultaneous sessions, same-host sessions, session switching, prompt ownership, and independent disconnect.
- [ ] Run a sustained terminal/SFTP soak test and review memory, battery, thread, file-descriptor, and network use.
- [ ] Review Play pre-launch report crashes, ANRs, rendering issues, and compatibility findings.

## Accessibility And Layout

- [ ] **Launch blocker:** Complete the primary TalkBack journey: create host, verify trust, authenticate, use terminal controls, switch sessions, disconnect, and recover from failure.
- [ ] **Launch blocker:** Verify password fields and terminal password mode do not expose secrets to accessibility services or previews.
- [ ] Verify touch targets, labels, focus order, custom accessibility actions, and announcements.
- [ ] Verify font scaling, display scaling, contrast, color independence, and reduced-motion expectations.
- [ ] Verify portrait, landscape, split-screen, tablet, foldable, keyboard-open, and edge-to-edge layouts.
- [ ] Verify the immersive terminal and file browser retain discoverable exit and failure-recovery paths.

## Release Engineering

- [ ] **Launch blocker:** Add CI for unit tests, lint, debug assembly, release assembly, and deterministic native-artifact verification.
- [x] Configure release builds for environment-backed signing and add a fail-closed build/verification script.
- [x] Create the Play upload keystore and store its credentials in the recoverable 1Password vault without a persistent local plaintext environment file.
- [ ] Verify upload-key recovery from a separate authorized development machine before production rollout.
- [ ] **Launch blocker:** Complete the Play Console upload-key reset from the unavailable certificate with SHA-1 ending `49:ED` to the vaulted certificate with SHA-1 ending `FF:23`, then verify a signed AAB upload.
- [ ] **Launch blocker:** Confirm Play App Signing enrollment and archive both the app-signing and upload certificate fingerprints.
- [ ] **Launch blocker:** Produce a signed AAB from a tagged, clean commit and record SHA-256 checksums.
- [ ] **Launch blocker:** Verify the release build installs, upgrades, launches, connects, and preserves encrypted data from the latest internal build.
- [ ] Decide minification/resource shrinking policy and test the resulting release artifact.
- [ ] Confirm versionCode/versionName policy and automate monotonically increasing release versions.
- [ ] Tag the release and archive source revision, dependency locks, Ghostty revision, tool versions, mapping files, symbols, SBOM, notices, and signed artifact checksums.

## Play Store

- [ ] **Launch blocker:** Create and verify the Play Console app and publisher identity.
- [ ] **Launch blocker:** Add support email, support URL, privacy-policy URL, and source-code URL.
- [ ] **Launch blocker:** Complete app category, content rating, target audience, ads declaration, app access, and Data safety forms.
- [ ] **Launch blocker:** Complete foreground-service, notification, biometric, VPN-related behavior, and sensitive-permission declarations as applicable.
- [ ] Prepare app title, short description, full description, release notes, phone screenshots, tablet screenshots, feature graphic, and icon.
- [ ] Ensure store copy does not promise process survival, credential synchronization, unsupported authentication, or unvalidated SFTP behavior.

## Rollout And Support

- [ ] **Launch blocker:** Complete internal testing with clean installs and upgrades on multiple accounts/devices.
- [ ] **Launch blocker:** Complete a closed test with people who use real SSH workflows and collect explicit go/no-go feedback.
- [ ] Define crash/ANR monitoring that does not capture terminal or credential data.
- [ ] Publish troubleshooting for trust changes, authentication failures, reconnect semantics, biometric invalidation, notifications, VPN/Tailscale, and data deletion.
- [ ] Define support intake, response ownership, severity levels, and a security contact.
- [ ] Start production with a staged rollout and written halt/rollback criteria.
- [ ] Review Play vitals and support reports daily during rollout.
- [ ] Record the final go/no-go decision, approver, date, release commit, artifact checksum, and known limitations.

## iOS Follow-Up

- [ ] Generate the Xcode project and compile the current iOS SFTP work on Apple Silicon with Xcode 16 or newer.
- [ ] Resolve Citadel's unbounded directory-listing API before claiming hostile-directory memory bounds.
- [ ] Complete iOS session ownership, lifecycle, reconnect, effects, selection/search, pointer, accessibility, privacy, signing, CI, TestFlight, and App Store checklists.
- [ ] Reuse the cleared product name and attribution inventory without blocking the Android-first launch on incomplete iOS parity.
