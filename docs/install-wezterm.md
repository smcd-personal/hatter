# Installing hatter with WezTerm, on macOS or Windows

**Read this first.** WezTerm is the intended second client, and it is the only
one on Windows that hatter can both drive *and* read back — which is what
`hatter sync` needs. But the WezTerm backend is not built yet: it is
[issue #4](https://github.com/smcd-personal/hatter/issues/4), on top of the adapter seam
in [issue #2](https://github.com/smcd-personal/hatter/issues/2).

So this guide gets you to a machine where:

- **the server half works today** — `provision`, `hat`, `tab`, `creds`,
  `backup`, `autosave`. Your servers get tmux persistence, the shell loop,
  `bye`, and credential pushes, and your config is versioned.
- **the client half waits on #4** — `hatter`, `sync` and `restore` drive cmux
  windows and will tell you `missing dependency: cmux`. Until the backend
  lands, you attach to your hats with plain ssh, which is shown below and works
  fine.

If you are on a Mac and want the whole thing now, use
[install-cmux-macos.md](install-cmux-macos.md) instead.

## Before you start

You need:

- **An ssh key that reaches your servers**, and `ssh you@host` working without a
  password prompt.
- **A shell server or two.** Any Linux box you can ssh into.

## 1. Install WezTerm

### macOS

```sh
brew install --cask wezterm
```

The CLI lives inside the app bundle, so put it on your PATH:

```sh
echo 'export PATH="$PATH:/Applications/WezTerm.app/Contents/MacOS"' >> ~/.zshrc
exec zsh
wezterm --version
```

### Windows

```powershell
winget install wez.wezterm
```

`scoop bucket add extras && scoop install wezterm` and `choco install wezterm -y`
also work, as does the portable zip if you cannot install software. The setup
installer registers `wezterm.exe` on your PATH; the zip does not, so add its
folder yourself. WezTerm needs Windows 10.0.17763 or later, 64-bit.

Check the CLI answers:

```powershell
wezterm cli list --format json
```

That command is the whole reason WezTerm is the target: it reports
`window_id`, `tab_id`, `pane_id`, `workspace`, `title` and `cwd`, so a client
backend can read the live layout back. Windows Terminal can be driven but not
queried, which is why it stays a fallback.

## 2. Get a shell for hatter

hatter is a bash script. It needs `bash`, `ssh`, `jq` and `git`.

### macOS

```sh
brew install jq git
```

### Windows: WSL2

hatter runs inside WSL, not in PowerShell.

```powershell
wsl --install -d Ubuntu
```

Then, inside Ubuntu:

```sh
sudo apt update && sudo apt install -y jq git tmux
```

Your ssh key has to be in WSL, not just in Windows:

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp /mnt/c/Users/<you>/.ssh/id_ed25519 ~/.ssh/
chmod 600 ~/.ssh/id_ed25519
ssh you@shell.example.com true && echo "ssh works"
```

1Password's WSL agent works too, if you would rather not copy a key.

## 3. Install hatter

```sh
git clone https://github.com/smcd-personal/hatter ~/src/hatter
install -m 755 ~/src/hatter/bin/hatter ~/.local/bin/hatter
export PATH="$HOME/.local/bin:$PATH"      # add to ~/.bashrc or ~/.zshrc
hatter --help
```

## 4a. First run — no config yet

```sh
hatter hat add dev --ssh you@shell.example.com
hatter provision dev
hatter hat status
```

`provision` is the part that matters and it works here in full: tpm,
tmux-resurrect and tmux-continuum, each pane's login shell wrapped in a loop so
a stray ctrl-D hands back a prompt instead of destroying a tab, and the `bye`
command for closing one on purpose.

`hat status` reports each server. The WINDOW column stays empty — that is the
client half, and there is no client backend yet.

Create a workspace on the server directly, since `hatter new` needs a client:

```sh
ssh you@shell.example.com "tmux new-session -d -s dev-website"
hatter tab dev-website "notes"
```

## 4b. Restore — you already have a config

```sh
git clone <your-remote> ~/.config/hatter
install -m 755 ~/.config/hatter/bin/hatter ~/.local/bin/hatter
hatter hat status
```

Your hats, groups and workspaces are all recorded and readable. `hatter restore`
will not rebuild the client layout until #4 lands, but nothing is lost: the
sessions live on the servers, and any Mac running cmux still restores from the
same config.

## 5. Attach to a hat

Until the backend exists, this is how you get into a hat:

```sh
ssh -t you@shell.example.com tmux new-session -A -s dev-website
```

`-A` attaches if the session exists and creates it if it does not, so the same
command always does the right thing.

A WezTerm launch menu gives you one entry per hat. In `~/.wezterm.lua` (WezTerm
also reads `~/.config/wezterm/wezterm.lua`; on Windows `~` is your WSL or
Windows home depending on where you launch it):

```lua
local wezterm = require 'wezterm'
return {
  launch_menu = {
    { label = 'dev — website',
      args = { 'ssh', '-t', 'you@shell.example.com',
               'tmux', 'new-session', '-A', '-s', 'dev-website' } },
    { label = 'ops — main',
      args = { 'ssh', '-t', 'you@ops.example.com',
               'tmux', 'new-session', '-A', '-s', 'ops-main' } },
  },
}
```

Inside a hat, tmux's own windows are your tabs — switch them with the tmux
prefix. That is the one thing the WezTerm backend will not recover: cmux mirrors
each tmux window as a native tab, using tmux control mode, and WezTerm's
control-mode support is [still an open issue](https://github.com/wezterm/wezterm/issues/336).

## 6. Back up your config

```sh
cd ~/.config/hatter && git init -b main
git remote add origin you@shell.example.com:git/dotfiles.git
hatter backup "first backup"
```

The config maps your infrastructure — hostnames and usernames, no secrets — so
keep that remote private.

## What about credentials?

`hatter creds push` reads Claude logins from the macOS Keychain via `cswap`,
which has no Windows equivalent. On a Windows client, log in on the server
itself once; the credential persists there and `hatter creds status` still
reports it correctly from Windows.

## Following the backend work

- [#2 — the client adapter interface](https://github.com/smcd-personal/hatter/issues/2),
  the seam every backend plugs into
- [#4 — the WezTerm adapter](https://github.com/smcd-personal/hatter/issues/4), including
  the verified CLI surface and the hat/group/workspace/tab mapping
- [#6 — the headless adapter](https://github.com/smcd-personal/hatter/issues/6), which is
  what you are using today without knowing it
