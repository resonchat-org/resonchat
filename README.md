# ResonChat

[![CI](https://github.com/resonchat-org/resonchat/actions/workflows/ci.yml/badge.svg)](https://github.com/resonchat-org/resonchat/actions/workflows/ci.yml)

English | [中文](README.zh.md)

A Flutter XMPP client that implements **post-quantum encryption isomorphic to OMEMO** — X25519 + ML-KEM-1024 — with **no server changes and no new XEP**, while staying **interoperable with standard OMEMO clients**. The UI follows Telegram for Android. Android first.

## Developer preview

ResonChat is early and iterating quickly. **M0–M5 are complete, M6 is in progress and M7 has not started. THERE WILL BE COMPATIBILITY-BREAKING CHANGES.**

The encryption is a custom post-quantum extension to OMEMO and has **not been audited by a third party**. Do not rely on it for high-sensitivity use, and do not claim that it is secure.

## Install

Android builds are attached to the [GitHub Releases](https://github.com/resonchat-org/resonchat/releases) page. [Obtainium](https://github.com/ImranR98/Obtainium) installs straight from there and keeps the app updated:

[![Get it on Obtainium](https://img.shields.io/badge/Get_it_on-Obtainium-3DDC84?logo=android&logoColor=white)](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22org.resonchat.resonchat%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Fresonchat-org%2Fresonchat%22%2C%22author%22%3A%22resonchat-org%22%2C%22name%22%3A%22ResonChat%22%2C%22additionalSettings%22%3A%22%7B%5C%22includePrereleases%5C%22%3Atrue%2C%5C%22fallbackToOlderReleases%5C%22%3Atrue%2C%5C%22autoApkFilterByArch%5C%22%3Atrue%7D%22%7D)

The link carries the whole configuration, so no directory listing is involved: it adds ResonChat following the **newest release including pre-releases** (the developer previews below), and lets Obtainium pick the `arm64` or `x86_64` APK for the device automatically.

<details>
<summary>The config the link adds, and how to add it by hand</summary>

```json
{"id":"org.resonchat.resonchat","url":"https://github.com/resonchat-org/resonchat","author":"resonchat-org","name":"ResonChat","additionalSettings":"{\"includePrereleases\":true,\"fallbackToOlderReleases\":true,\"autoApkFilterByArch\":true}"}
```

Adding `https://github.com/resonchat-org/resonchat` as an Obtainium source by hand and turning on **Include pre-releases** and **Auto-select by architecture** is equivalent.

</details>

Every release so far is a **developer preview** signed with the debug keystore. If you have a locally built APK installed, uninstall it first — a locally built APK and a release APK share the package name (`org.resonchat.resonchat`) but not the signing key, so Android will refuse to replace one with the other.

## Features

| Feature | Status | Notes |
|---|---|---|
| Dual-track end-to-end encryption (A track) | Done | Standard OMEMO (XEP-0384), interoperable with Conversations / Moxxy / Dino. Verified end to end against a real Conversations 2.20.4 |
| Dual-track end-to-end encryption (B track) | Done | PQ-OMEMO (X25519 + ML-KEM-1024 hybrid, PQXDH + SPQR). Sent when the user picks O2 and the peer's devices are reachable. Cross-tested between two accounts on different servers |
| Track selection (O2 / OM / NO) | Done | The user's choice plus a `TrackResolver` feasibility decision — see [docs/10](docs/10-track-selection.md) |
| Zero server changes / zero new XEPs | Done | Reuses existing standards (PEP, EME, …) |
| Encrypted database at rest | Done | SQLCipher, with the key protected by the Android Keystore |
| Standard protocol extensions | Done | MAM (XEP-0313) history sync, delivery receipts (XEP-0184), chat states (XEP-0085), carbons (XEP-0280) |
| Platform support | Partial | Android (arm64-v8a / x86_64, `pqcrypto` + native `libsignal`); Web (Dart→Wasm + Drift WASM + WebSocket); Linux AppImage / deb / rpm; Windows installer; iOS not started |
| Telegram-for-Android look | In progress | Bubbles, palette and list layout are in place; animation and tablet layout are not |

## Status

**M0–M5 are complete, M6 is in progress and M7 has not started.**

| Milestone | Status | Highlights |
|---|---|---|
| M0 Project skeleton | Done | Monorepo skeleton, upstream forks wired in, CI, drift storage, PQXDH and dual-track codecs, a buildable Android debug APK |
| M1 Communication baseline | Done | SASL SCRAM-SHA-256, resource binding, roster (RFC 6121 versioning), plaintext send/receive, MAM history sync, carbons, message storage |
| M2 Standard OMEMO | Done | **Interoperability accepted against a real Conversations 2.20.4** (messages we encrypt are decrypted and shown by a third-party client) |
| M3 PQ core | Done | ML-KEM / PQXDH / SPQR through native `libsignal`; pure-Dart `pqcrypto` for ML-DSA-87 and SHA3-512; **cross-tested between two accounts on different servers** (conversations.im and jabber.fr); the PQ bundle is really published to the server |
| M4 Negotiation and send policy | Done | Capability service, user track choice and `TrackResolver` (docs/10); PEP changes invalidate the cache |
| M5 Storage and protection | Done | OMEMO device keys sealed through the Keystore, SQLCipher-encrypted database, a chat-history backup format. **Key backup/restore and a "never store plaintext" option are not done** |
| M6 UI | In progress | Per [docs/05](docs/05-ui-telegram.md) |
| M7 Release | Not started | — |

CI runs `dart analyze` and the full `flutter test` suite on every push, and compiles Linux and Web together as a smoke check.

**Known limitations and unfinished work** (the complete list is in [`README.dev.md`](README.dev.md)):

- Reverse interoperability (Conversations → this client) is not verified yet; the acceptance environment refuses delivery to non-mutually-subscribed devices, so two real devices are still needed
- Device keys live only in the local Keystore, so **switching devices invalidates every session** (no backup or restore)
- iOS is not started; Android is only built for arm64-v8a / x86_64
- Messages are always stored (encrypted), with no "don't store plaintext" option
- The encryption protocol has **not been audited by a third party**

## Building

The repository brings its upstream forks in as **Git submodules** — `vendor/omemo_dart`, `vendor/moxxmpp`, `vendor/libsignal_dart` and `vendor/moxlib` (see [`.gitmodules`](.gitmodules)). Some code they need is **not committed** (for example the `moxxmpp` builder output), so it has to be generated before `flutter pub get` and before building; otherwise `flutter pub get` or the compiler reports missing files.

### Requirements

- [Flutter](https://docs.flutter.dev/get-started/install) stable (Dart 3.13+, matching [`README.dev.md`](README.dev.md))
- Android: JDK 21 and the Android SDK (needed to run or package an APK)

### 1. Clone the repository and its submodules

```bash
git clone --recurse-submodules https://github.com/resonchat-org/resonchat
cd resonchat
```

### 2. Generate the submodule code

```bash
./scripts/generate_submodule_code.sh
```

The script resolves the path packages in dependency order and runs `build_runner` where it is needed. (The old `protoc` step for `omemo_dart` is gone with the pure-Dart OMEMO stack — do not run `protoc` against `vendor/omemo_dart`.)

### 3. Build and run the app

```bash
cd app
flutter pub get
dart run build_runner build   # generates drift: database.g.dart, …
flutter run                   # with a device or emulator attached
```

Debug APK, from the repository root:

```bash
./scripts/build_android.sh
```

Linux AppImage (x86_64 / aarch64; needs the Flutter Linux desktop dependencies installed — clang, cmake, ninja, GTK 3, libsecret, …):

```bash
./scripts/build_appimage.sh
# → app/build/resonchat-<version>-x86_64.AppImage
chmod +x app/build/resonchat-*-x86_64.AppImage
./app/build/resonchat-*-x86_64.AppImage
```

Debian / RPM (the same release bundle; library dependencies are inferred by the packaging tools, CLI dependencies are listed in `scripts/linux_pkg_deps.sh`):

```bash
./scripts/build_deb_rpm.sh          # or --skip-build to reuse an existing bundle
# → app/build/resonchat_<version>_x86_64.deb
#   app/build/resonchat-<version>-1.x86_64.rpm
```

Windows installer, from PowerShell (`scripts/build_windows.ps1`):

```powershell
./scripts/build_windows.ps1
# → app/build/windows/installer/resonchat-<version>-x86_64-setup.exe
```

Web (Drift `sqlite3.wasm` + Dart→Wasm; output in `app/build/web/`):

```bash
./scripts/build_web.sh
# release tarball: resonchat-<tag>-wasm.tar.gz (CD tars up app/build/web)
```

`vendor/libsignal_dart` supplies the native libsignal library. Its build hook downloads the prebuilt `libsignal_frb` release for the target platform, so the first build of a checkout needs network access.

A fuller toolchain list, plus the analysis and test commands, is in [`README.dev.md`](README.dev.md) (Chinese).

## Development

Local setup, analysis and tests: [`README.dev.md`](README.dev.md) (Chinese).

## Documentation

The full design documentation lives in [`docs/`](docs/README.md) (Chinese):

| Document | Contents |
|---|---|
| [Overview and key decisions](docs/01-overview.md) | Goals, constraints, ADRs, architecture |
| [Protocol specification](docs/02-protocol-pqomemo.md) | Dual-track OMEMO, PQXDH, message format |
| [XMPP integration](docs/03-xmpp-integration.md) | PEP nodes, send and receive flows |
| [Cryptography](docs/04-crypto-android.md) | pqcrypto / libsignal, key storage |
| [UI specification](docs/05-ui-telegram.md) | Telegram look and porting |
| [Milestones](docs/06-android-milestones.md) | M0–M7 |
| [Compliance](docs/07-licensing-compliance.md) | Licenses and trademarks |
| [Risks](docs/08-risks-open-questions.md) | Risks and open questions |
| [Briar lessons](docs/09-briar-lessons.md) | Trust UX, power-saving design |
| [Track selection](docs/10-track-selection.md) | User choice, feasibility, label consistency |

## License

[GNU GPL-3.0-or-later](LICENSE).

## Third-party code

This project is released under GPL-3.0-or-later and contains the following third-party code. The full matrix is in [`docs/07-licensing-compliance.md`](docs/07-licensing-compliance.md).

### Upstream forks in the repository (`vendor/`, Git submodules)

These four libraries are forks of upstream projects. **Their original license headers and copyright notices are kept.**

| Path | Upstream | License | Local changes |
|---|---|---|---|
| `vendor/moxxmpp` | [codeberg.org/moxxy/moxxmpp](https://codeberg.org/moxxy/moxxmpp) | MIT | Removed the private registry; Dart 3; MAM; RFC 7395 / XEP-0156 |
| `vendor/omemo_dart` | [github.com/PapaTutuWawa/omemo_dart](https://github.com/PapaTutuWawa/omemo_dart) | MIT | Removed the private registry; axolotl path |
| `vendor/libsignal_dart` | [github.com/djx-y-z/libsignal_dart](https://github.com/djx-y-z/libsignal_dart) | **AGPL-3.0** | ML-KEM-1024 (`0x0A`) patch; publishes the prebuilt native `libsignal_frb` release it downloads |
| `vendor/moxlib` | [codeberg.org/moxxy/moxlib](https://codeberg.org/moxxy/moxlib) | **GPL-3.0** | Raised the SDK constraint to Dart 3 |

### UI design reference

The interface under `app/lib/ui/` follows the layout and interaction patterns of Telegram for Android (GPL-2.0-or-later). Files ported from Telegram keep their original copyright notices and NOTICE, and note the source and date of modification prominently. **This project is not an official Telegram client and is not affiliated with Telegram**; the Telegram name and logo are trademarks of their respective owners.

### Runtime dependencies (obtained through package managers, not in this repository)

| Dependency | License |
|---|---|
| `cryptography` (Dart) | Apache-2.0 |
| `pqcrypto` (Dart) | MIT |
| `libsignal` (path → `vendor/libsignal_dart`) | AGPL-3.0 |
| drift | MIT |
| SQLCipher / sqlcipher_flutter_libs | BSD-style (includes OpenSSL) |
| flutter_secure_storage | BSD-3-Clause |
| riverpod / flutter_riverpod | MIT |

> Our own source files all carry an `SPDX-License-Identifier: GPL-3.0-or-later` header.

## Disclaimer

The encryption protocol is a custom post-quantum extension to OMEMO and **has not been audited by a third party**. Until an independent audit is done, do not use it for high-sensitivity material and do not claim that it is secure.
