#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
exec ruby scripts/generate.rb
