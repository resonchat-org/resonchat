#!/usr/bin/env bash
# Resolve path packages and generate code the app needs before flutter pub get.
# Classic omemo_dart protobuf generation was removed with the pure-Dart OMEMO
# stack — do not run protoc against vendor/omemo_dart.
#
# Usage (from repo root): ./scripts/generate_submodule_code.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

(cd vendor/moxlib && dart pub get)
(cd vendor/omemo_dart && dart pub get)
(cd vendor/moxxmpp/packages/moxxmpp && dart pub get && dart run build_runner build)
(cd vendor/moxxmpp/packages/moxxmpp_socket_tcp && dart pub get)
