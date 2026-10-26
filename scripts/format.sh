#!/usr/bin/env bash
# Copyright (C) 2026 ResonChat contributors.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Format the app's Dart sources:
#   1. relative lib imports/exports → package:resonchat
#   2. import_sorter order (dart, package:flutter, other packages, this package)
#   3. dart format
#
# Usage (from repo root):
#   ./scripts/format.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/../app" && pwd)"
cd "$APP"

dart --packages="$APP/.dart_tool/package_config.json" "$HERE/sort_imports.dart"
dart format lib test integration_test tool "$HERE/sort_imports.dart"
