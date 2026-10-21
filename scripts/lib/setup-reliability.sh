#!/usr/bin/env bash

# Compatibility entry point for setup.sh. The reliability primitives are installed
# with the dotfiles so desktop-side managed configuration, such as theme switching,
# uses the same lock, run records, atomic writes and rollback as setup.
# shellcheck source=dotfiles/.config/hypr/scripts/lib/hss_reliability.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/dotfiles/.config/hypr/scripts/lib/hss_reliability.sh"
