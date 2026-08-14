#!/usr/bin/env bash
# Installs the e2e suite's Python dependencies. CI runs this too, so a local
# checkout and a CI job resolve the same pins from the same file.
set -euo pipefail
cd "$(dirname "$0")"
pip install -r requirements.txt
