#!/usr/bin/env bash
# Sourced by every test straight after `set -euo pipefail` (#302). A
# developer's shell can point hatter at real homes: Codex's, Claude's, the XDG
# directories, Cloudflare's. A test that inherits one writes the developer's
# real config even with HOME pointed at a temp dir, because these win over
# HOME. Clearing them here makes each fall back to the test's own HOME.
# ZDOTDIR, BASH_ENV and ENV would have a login or child shell read the
# developer's own dotfiles, which can export the rest again. TMUX and
# TMUX_PANE say which real tmux this is; CI runs with neither.
# tests/test-isolation.sh fails a test that does not source this.
# Run on its own (the suite runs every tests/*.sh), it does nothing.
unset CODEX_HOME CLAUDE_CONFIG_DIR XDG_CONFIG_HOME XDG_STATE_HOME \
      XDG_DATA_HOME XDG_CACHE_HOME HATTER_CF_DIR HATTER_CMUX_SETTINGS \
      ZDOTDIR BASH_ENV ENV TMUX TMUX_PANE
