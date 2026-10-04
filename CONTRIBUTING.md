# Contributing to hatter

Thanks for looking. hatter is small and young, so a few ground rules save
everyone time.

## How to propose a change

- **Small fixes** — typos, docs, an obvious bug: fork, branch, open a pull
  request against `main`.
- **Anything bigger** — a new command, a config schema change, a new terminal
  adapter: open an issue first, or comment on the existing one, so we agree on
  the approach before you write the code.
- One change per pull request. Say how you tested it, and on which OS and
  terminal.
- CI must pass.

By contributing you agree that your work is licensed under the project's
[MIT licence](LICENSE).

## What we want most

**Client adapters.** hatter's claim is that one config file rebuilds your
workspace on any client. Today cmux is the only client it drives, so the
contribution that matters most is the adapter seam and the adapters behind it:

- [#2 — the client adapter interface](https://github.com/smcd-personal/hatter/issues/2):
  the twelve functions that are the whole cmux surface, and the capability
  flags (`CanMirrorTmux`, `CanGroup`, `CanStyle`) an adapter declares
- [#4 — WezTerm](https://github.com/smcd-personal/hatter/issues/4), which also brings
  Windows and Linux
- [#6 — headless](https://github.com/smcd-personal/hatter/issues/6), tmux and ssh
  only

The rule for an adapter: **it must not need changes to the core.** If yours
does, that is a finding about the interface — say so in the issue rather than
working around it.

The wider plan, and the order it should happen in, is in [EPIC.md](EPIC.md).
Issues labelled
[`good first issue`](https://github.com/smcd-personal/hatter/labels/good%20first%20issue)
are a good place to start.

## Running from a clone

hatter is one bash script with no build step:

```sh
git clone https://github.com/smcd-personal/hatter
cd hatter
bin/hatter --help
```

Point it at a throwaway config while you work, so you cannot damage your
real one:

```sh
XDG_CONFIG_HOME=$(mktemp -d) bin/hatter hat add test --ssh you@test.example.com
```

You need `ssh`, `jq` and a server running `tmux`. The cmux commands need
[cmux](https://cmux.com) on macOS; everything else runs without it.

## Rules for the code

- **bash 3.2.** macOS ships nothing newer. No associative arrays, no
  `mapfile`, no `${var^^}`.
- **`set -euo pipefail` is on.** A function that falls off the end with a
  non-zero status kills the script silently. End such functions with an
  explicit `return 0`, or handle the failure.
- **Never assign to a bash special variable** — `GROUPS`, `UID`, `EUID`,
  `PPID`, `SECONDS`, `RANDOM`, `LINENO`. The assignment fails silently and
  `set -e` turns that into an exit with no message.
- **Always pass an explicit target** (`--window`, `--workspace`) to client
  commands. A default target is whatever happens to be focused, not the
  caller.
- **No secrets, ever.** Credentials go through the OS keychain and an ssh
  pipe; nothing is written to disk. Keep it that way.
- **Examples use `example.com`.** No real hostnames or usernames in code,
  docs, tests or screenshots.

Before you push:

```sh
bash -n bin/hatter
shellcheck --severity=error bin/hatter
```

CI runs the same checks on macOS (bash 3.2) and Linux.

## Reporting bugs

Use the bug template. Include the commit you are running, your OS and
terminal, and the command you ran. **Redact your hostnames and
usernames** — the config maps your infrastructure.

Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Conduct

Be decent. The [Code of Conduct](CODE_OF_CONDUCT.md) applies everywhere the
project lives.
