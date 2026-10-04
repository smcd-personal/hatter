# Epic: turn hatter (→ hatter) into a client-agnostic, multi-host workspace orchestrator

**Status:** proposal
**Owner:** @smcd-personal
**Created:** 2026-09-06

## Summary

hatter is currently ~1000 lines of bash that drive [cmux](https://cmux.com) from a
single JSON config, so that a set of remote tmux servers can be projected into a
desktop workspace and rebuilt from scratch after any failure.

It works, in daily use, across five hosts. This epic is about deciding whether it
becomes a real, open, cross-platform project — and if so, doing it in the order
that keeps the idea honest.

## The idea worth keeping: hats

A **hat** is the top-level unit: one unique `(user, host)` pair. One ssh
connection, one tmux server, one client window. "Which hat am I wearing right
now" — work, a side project, personal, a client.

Under a hat sit **groups** (projects/areas), and under those, **workspaces**
(tmux sessions named `<hat>-<subproject>`) whose **tabs** are tmux windows.

Two properties fall out of this, and they are the whole pitch:

1. **The server is the source of truth.** Remote tmux holds the state. The
   desktop client is a projection of it, and is disposable.
2. **The config is portable.** One small JSON file rebuilds the entire layout on
   any machine, against any client that has an adapter.

That combination — multi-host, client-as-projection, rebuild-from-config — does
not appear to exist elsewhere (see Prior Art below).

## Why this might not be worth it

Recorded up front so we don't kid ourselves:

- **The heavy lifting currently isn't ours.** `cmux ssh-tmux` does control-mode
  mirroring and session→workspace mapping. hatter is glue. On a client without a
  tmux mirror, it degrades to `ssh -t host 'tmux new-session -A'`, which is a
  shell alias. **The adapter layer is where the project actually lives, and it
  does not exist yet.**
- **The `*mux` namespace is saturated**: tmux, cmux, wmux, dmux, smug, twm,
  workmux, mx.sh, intmux. "hatter" reads as parody and is hard to search for.
- **Bash will not survive an adapter architecture.** Four `set -e` landmines
  surfaced in a single day of use (silent exit-1 in `session_hat`, a sync that
  clobbered records via a duplicate group name, a restore that aborted on the
  first unreachable host, a stray-window cleanup that never fired). Fine for a
  personal tool; a liability once other people's layouts depend on it.

## Prior art

Nothing found occupies the same niche, but the neighbourhood is busy.

| Bucket | Examples | Why it isn't this |
|---|---|---|
| Declarative local layouts | tmuxp, tmuxinator, teamocil, smug, mx.sh, twm | Single host, local. No remote fan-out, no client-side grouping. |
| Multi-server SSH fan-out | tmux-connector, tmux-cluster, intmux, sshmx | Cluster/broadcast tooling. Sysadmin intent, not persistent per-host workspaces. |
| Session pickers | sesh, twm, tmux-fzf | Local switching, no state model. |
| Agent orchestrators | NTM, Paneflow, wmux, cmux, dmux | Coordinate agents within one machine. |

Closest relative: [workmux](https://github.com/raine/workmux) — already
client-agnostic across kitty/WezTerm/Zellij, but local and git-worktree-shaped.

## Sequencing

The order matters. Do **not** start with the rewrite.

1. **#9 Naming** — cheap, blocks the public artifacts, and the name is load-bearing.
2. **#2 Adapter interface** — extract the seam *in bash first*. If this is
   painful, the idea is thinner than it looks and we stop here.
3. **#4 WezTerm adapter** — the second adapter is the real proof. Also unlocks
   Windows and Linux without a native app.
4. **#1 Port to Go** — only once the interface has survived two implementations.
5. Everything else.

**Gate:** run the current bash version daily across all five hats for at least
two weeks before committing to the rewrite. Five hats in real use will teach us
more about what the abstraction needs than designing it now will.

## Sub-issues

- #1 Port from bash to a single typed binary
- #2 Define the client adapter interface
- #3 cmux adapter (extract from current bash)
- #4 WezTerm adapter — the portability proof
- #5 wmux adapter — native Windows
- #6 Headless / tmux-only adapter
- #7 Config schema v1 and migration policy
- #8 Test suite and reliability
- #9 Naming and identity
- #10 Open source on GitHub
- #11 Dedicated website and docs
- #12 Mobile mode
- #13 Server provisioning as a first-class concern
