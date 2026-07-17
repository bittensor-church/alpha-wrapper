#!/usr/bin/env bash
# Installs the e2e suite's Python dependencies. A bare `pip install -r
# requirements.txt` is not enough: bittensor-cli and substrate-interface each
# pull a different provider of the `scalecodec` import namespace (cyscale vs
# py-scale-codec), and whichever lands second breaks the other's import.
# cyscale is a drop-in replacement for py-scale-codec, so it is reinstalled
# last and serves both.
set -euo pipefail
cd "$(dirname "$0")"
pip install -r requirements.txt
pip uninstall -y scalecodec cyscale
pip install cyscale==0.5.0
