# Installing hatter with cmux, on macOS

This is the full-feature path: cmux is the only client hatter can drive
end-to-end today, and it is macOS-only. It takes you from a bare Mac to either
a first hat or a restored config.

For WezTerm, or for Windows, see [install-wezterm.md](install-wezterm.md).

## Before you start

You need:

- **macOS.** The system `bash` (3.2) is fine — hatter is written for it.
- **An ssh key that reaches your servers**, and `ssh you@host` working from
  Terminal without a password prompt. hatter never handles ssh auth itself; if
  ssh works, hatter works.
- **A shell server or two.** Any Linux box you can ssh into. hatter installs
  tmux persistence on it for you.

## 1. Install cmux

Download it from [cmux.com](https://cmux.com) and drag it to `/Applications`.

Open it once so it can finish setting itself up.

## 2. Put the cmux CLI on your PATH

cmux puts its CLI on the PATH of terminals **it** launches. hatter also runs
from plain Terminal.app and from a background timer, neither of which get that,
so make it permanent:

```sh
echo 'export PATH="/Applications/cmux.app/Contents/Resources/bin:$PATH"' >> ~/.zshrc
exec zsh
cmux --version
```

If `cmux --version` prints a version, the CLI is reachable.

## 3. Install hatter's other dependencies

```sh
brew install jq git
```

`jq` is required — every config read and write goes through it. `git` is only
needed for `hatter backup`, but you want that.

## 4. Install hatter

```sh
git clone https://github.com/smcd-personal/hatter ~/src/hatter
install -m 755 ~/src/hatter/bin/hatter ~/.local/bin/hatter
```

Make sure `~/.local/bin` is on your PATH:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
exec zsh
hatter --help
```

## 5a. First run — no config yet

Add a hat. A hat is one login: `user@host`, one ssh connection, one tmux
server, one cmux window.

```sh
hatter hat add dev --ssh you@shell.example.com
```

Set that server up. This installs tpm, tmux-resurrect and tmux-continuum, wraps
each pane's login shell in a loop so a stray ctrl-D cannot destroy a tab,
installs the `bye` command, and self-tests the result:

```sh
hatter provision dev
```

Then make your first workspace. A workspace is a tmux session named
`<hat>-<subproject>`, shown as one entry in the cmux sidebar:

```sh
hatter dev-website
```

Open the rack to see what you have:

```sh
hatter
```

## 5b. Restore — you already have a config

Your config lives in `~/.config/hatter` and `hatter backup` commits it to a git
remote you control. On a new Mac, clone it back:

```sh
git clone <your-remote> ~/.config/hatter
```

The bootstrap secret is your ssh key, not the repo. Keep the key in a password
manager so a bare machine can reach the remote in the first place.

The repo also carries a copy of the script at `bin/hatter`, so if you cloned the
config before installing hatter you already have it:

```sh
install -m 755 ~/.config/hatter/bin/hatter ~/.local/bin/hatter
```

Then rebuild the layout — recreate missing tmux sessions and their tabs, open
each hat's window, re-mirror, put the workspaces back in their groups:

```sh
hatter restore
```

This is idempotent. Hats whose server is unreachable are skipped rather than
failing the run.

## 6. Turn on autosave

A rolling snapshot of the config, plus one frozen checkpoint per 8 hours, so a
mistake inside cmux is walkable-back:

```sh
hatter autosave install
hatter autosave status
```

That installs a launchd timer that runs every 60 seconds. It syncs first, so it
also picks up renames you made inside cmux.

## 7. Optional: Claude logins

If you run Claude Code on your servers, hatter can push a login from this Mac's
Keychain to a hat over ssh, without the login ever touching disk on either side.

```sh
uv tool install claude-swap     # provides `cswap`
hatter creds                    # lists logins and which hats hold them
hatter creds push a dev
hatter creds status
```

One login can go to as many hats as you like. A hat holds one at a time,
because Claude Code reads a single credentials file.

## Where to go next

- `hatter --help` lists every command; `hatter help <command>` goes deeper.
- `hatter` on its own opens the rack.
- `hatter backup` commits your config. Do this once you have hats worth keeping.
