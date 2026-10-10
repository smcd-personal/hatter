# Installing hatter with WezTerm, on Windows, macOS or Linux

[WezTerm](https://wezterm.org) is hatter's second client, after cmux. It runs
natively on Windows, macOS and Linux, and it is the one Windows terminal hatter
can both drive and read back.

What you get today:

- **Your hats, from anywhere.** A picker (`Ctrl+Shift+O`) lists every
  workspace in your hatter config. Choosing one attaches to its tmux session
  over ssh, in a tab named after it, inside a WezTerm workspace named after
  its hat. Choosing it again switches to that tab. The picker also creates new
  workspaces and pulls the config from git.
- **No bash needed on Windows.** The picker is a WezTerm plugin that reads
  hatter's `config.json` and runs Windows' own `ssh`. WSL is not required.
- **`hatter attach`** does the same from any bash terminal (macOS, Linux, WSL).

What waits on [#4](https://github.com/smcd-personal/hatter/issues/4):
`hatter restore` and `hatter sync` driving WezTerm windows, as they do cmux
today. Until then, the cmux Mac (or any machine running `hatter`) is where
the config is written, and WezTerm reads it.

There are two paths:

- **[A. Windows, no WSL](#a-windows-no-wsl)**: WezTerm, Git and the built-in
  OpenSSH client. Enough to reach every hat.
- **[B. macOS, Linux or WSL](#b-macos-linux-or-wsl)**: the same plugin, plus
  the `hatter` script itself for `provision`, `creds`, `backup` and the rest.

## Before you start

You need:

- **Servers that hatter already knows about**: a `config.json` with your hats
  in it, backed up to a git remote with `hatter backup`. If you are starting
  from nothing, set up a server first with path B (or the
  [cmux guide](install-cmux-macos.md)); Windows cannot `provision` without bash.
- **An ssh key those servers accept**, or the means to add one.

## A. Windows, no WSL

Everything below runs in PowerShell. Windows 10 1809 or later, 64-bit.

### The quick way: one command

Paste this into PowerShell, with your own config remote (wherever
`hatter backup` pushes):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/smcd-personal/hatter/main/tools/install-windows.ps1))) -ConfigRemote you@shell.example.com:git/dotfiles.git
```

[`tools/install-windows.ps1`](../tools/install-windows.ps1) does A1 to A6 below
and then checks every hat:

1. installs WezTerm and Git with winget, if they are missing
2. adds the OpenSSH client and starts the ssh agent, asking for administrator
   rights once and only if something needs them
3. asks whether to use an ssh key you already have. If so, it lists the
   usable private keys in a folder you pick (default `~\.ssh`), with their
   fingerprints; if not, it makes one. The key goes into the agent, its
   permissions are tightened if Windows' ssh would refuse it, and the choice
   is remembered for the next run
4. clones your config to `~\.config\hatter`, or pulls it if it is there,
   using Windows' ssh for that repository only
5. fetches the plugin to `%LOCALAPPDATA%\hatter\src`
6. writes `~\.wezterm.lua`, backing up any you already have after asking, and
   loads it in WezTerm to prove it works before going on
7. connects to each hat and prints a table

Each step checks before it acts, so **run it again whenever you like**: to
update the plugin and the config, or as a health check when something is off.
A plain `-ConfigRemote` is only needed the first time.

**Keys from PuTTY** (`.ppk`) are listed but cannot be used as they are: open
the key in PuTTYgen, choose *Conversions > Export OpenSSH key*, save it in
`~\.ssh`, and run the installer again.

**A hat that says "key not authorised".** A new key cannot log in to a server
that only accepts keys, so it cannot add itself. The installer puts your public
key on the clipboard and prints a command for a machine that already gets in,
usually your Mac:

```sh
hatter key add 'ssh-ed25519 AAAA... you@windows' dev ops
```

Run that, then run the installer again. If even the config server refuses the
key, the clone fails the same way and prints the same fix.

**Your own WezTerm settings** go in `~\.wezterm-local.lua`, which survives
re-runs. It returns a function:

```lua
return function(config, wezterm)
  config.font_size = 12
  config.color_scheme = 'Builtin Solarized Dark'
end
```

Options, for when the defaults do not fit:

| Option | Does |
|---|---|
| `-KeyPath <file>` | Use this private key, without asking; also changes a remembered one |
| `-Ref <branch\|tag>` | Install the plugin from another ref (default `main`) |
| `-NoMaximize` | Do not open WezTerm maximized |
| `-Yes` | Answer yes to every question |
| `-SkipInstall` | Never install software; fail if WezTerm or Git is missing |
| `-SkipHatCheck` | Do not connect to the hats |
| `-NoLaunch` | Do not open WezTerm at the end |

If you would rather read a script before running it, download it first:

```powershell
irm https://raw.githubusercontent.com/smcd-personal/hatter/main/tools/install-windows.ps1 -OutFile install-windows.ps1
notepad install-windows.ps1
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 -ConfigRemote you@shell.example.com:git/dotfiles.git
```

The rest of this section is what the script does, by hand.

### A1. Install WezTerm and Git

```powershell
winget install wez.wezterm
winget install Git.Git
```

`scoop install extras/wezterm` and `choco install wezterm -y` work too. Close
and reopen PowerShell so both land on your PATH, then check:

```powershell
wezterm --version
git --version
```

### A2. Check the ssh client

Windows ships OpenSSH. Confirm it is there:

```powershell
ssh -V
```

If that says `ssh` is not recognised, add it (in an administrator PowerShell):

```powershell
Get-WindowsCapability -Online -Name OpenSSH.Client* | Add-WindowsCapability -Online
```

### A3. An ssh key

Use an existing key, or make one for this machine:

```powershell
ssh-keygen -t ed25519
```

Keys live in `$env:USERPROFILE\.ssh\`. To copy an existing key instead, put
`id_ed25519` and `id_ed25519.pub` there.

Let the ssh agent hold it, so you type the passphrase once per login rather
than once per tab (administrator PowerShell for the first line):

```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent
ssh-add $env:USERPROFILE\.ssh\id_ed25519
```

If the key is new, authorise it on each server. Windows has no `ssh-copy-id`,
so pipe it:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh you@shell.example.com "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

Then check each hat answers without a password prompt:

```powershell
ssh you@shell.example.com true
```

1Password's ssh agent also works on Windows and replaces this whole step.

### A4. Point Git at the same ssh

Git for Windows brings its own ssh, which does not see the Windows agent. Use
the system one, so git and WezTerm share one key and one agent:

```powershell
git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"
```

### A5. Clone your hatter config

The config goes where hatter looks for it on every platform,
`~/.config/hatter`:

```powershell
git clone you@shell.example.com:git/dotfiles.git $env:USERPROFILE\.config\hatter
dir $env:USERPROFILE\.config\hatter\config.json
```

Use whatever remote `hatter backup` pushes to. The config lists your hosts and
usernames and holds no secrets, but keep that remote private.

### A6. Configure WezTerm

Create `$env:USERPROFILE\.wezterm.lua`:

```powershell
notepad $env:USERPROFILE\.wezterm.lua
```

with:

```lua
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- hatter: Ctrl+Shift+O opens a workspace on any hat.
local hatter = wezterm.plugin.require 'https://github.com/smcd-personal/hatter'
hatter.apply_to_config(config)

return config
```

Start WezTerm. The first start clones the plugin, which takes a few seconds.

`apply_to_config` takes options, all optional:

```lua
hatter.apply_to_config(config, {
  key = 'O', mods = 'CTRL|SHIFT',   -- the picker binding
  config_path = 'D:/sync/hatter/config.json',  -- if the config lives elsewhere
  ssh = 'C:/Windows/System32/OpenSSH/ssh.exe', -- if `ssh` on PATH is the wrong one
})
```

### A7. Use it

Press **`Ctrl+Shift+O`** and start typing. The list is fuzzy-matched:

```
personal  ›  Website  ›  personal-website
work      ›  Atlas    ›  work-atlas
work      ›  Atlas    ›  work-atlas-parser
personal  ›  + new workspace
work      ›  + new workspace
Update config from git (git pull)
```

- **A workspace** opens a tab running
  `ssh -t <hat> tmux new-session -A -s <workspace>`, in a WezTerm workspace
  named after the hat. If that tab is already open, you are switched to it.
- **+ new workspace** asks for a name, prefixes it with the hat
  (`atlas-ui` becomes `work-atlas-ui`), and creates the session on the server.
- **Update config from git** runs `git pull` in the config folder.

Every workspace is also in WezTerm's launcher (right-click the `+` button in
the tab bar), which opens it in a plain tab.

Inside a workspace, tmux's windows are your tabs: switch them with the tmux
prefix, and detach with prefix then `d`. The session keeps running. Under cmux
each tmux window is a native tab; WezTerm cannot mirror tmux that way yet
([wezterm#336](https://github.com/wezterm/wezterm/issues/336)).

Switch between hats with `Ctrl+Shift+O` again, or with WezTerm's workspace
switcher, which lists one entry per hat you have open. It has no default key;
`Ctrl+Shift+S` is free:

```lua
table.insert(config.keys, {
  key = 'S', mods = 'CTRL|SHIFT',
  action = wezterm.action.ShowLauncherArgs { flags = 'FUZZY|WORKSPACES' },
})
```

### A8. Keeping it current

- **The config.** The picker reads `config.json` every time it opens, so a
  `git pull` (from the picker or by hand) shows up straight away. Workspaces
  created on this machine reach the config the next time `hatter sync` or
  autosave runs on a machine with `hatter`, followed by `hatter backup`.
- **The plugin.** If you used the installer, run it again. If you set up by
  hand with `wezterm.plugin.require`, open the debug overlay (`Ctrl+Shift+L`),
  run `wezterm.plugin.update_all()`, then reload the config (`Ctrl+Shift+R`).

### Troubleshooting

Running the installer again checks everything below and says which part is
wrong. By hand:

- **The picker shows a toast "cannot read …config.json".** The clone is not in
  `$env:USERPROFILE\.config\hatter`, or `XDG_CONFIG_HOME` points elsewhere.
  Move it, or pass `config_path`.
- **The tab opens and closes at once.** ssh failed. Run the same command in
  PowerShell to see why: `ssh -t you@shell.example.com tmux new-session -A -s test`.
- **`open terminal failed: missing or unsuitable terminal`.** The server has no
  terminfo for WezTerm's `TERM`. Add `config.term = 'xterm-256color'` to
  `.wezterm.lua`, which is also WezTerm's default.
- **Asked for a passphrase on every tab.** The ssh agent is not running, or
  `ssh` on PATH is not the Windows one. Revisit A3 or set `ssh` in A6.
- **Errors in the plugin.** `Ctrl+Shift+L` opens the debug overlay with the
  log.

## B. macOS, Linux or WSL

Here hatter itself runs, so you get the server half (`provision`, `hat`,
`tab`, `creds status`, `backup`, `autosave`) and `hatter attach`, as well as
the WezTerm plugin.

### B1. Install WezTerm

macOS:

```sh
brew install --cask wezterm
echo 'export PATH="$PATH:/Applications/WezTerm.app/Contents/MacOS"' >> ~/.zshrc
exec zsh
wezterm --version
```

Linux: see [wezterm.org/install/linux](https://wezterm.org/install/linux.html)
for your distribution's package.

WSL: install WezTerm on the Windows side, as in [A1](#a1-install-wezterm-and-git),
and run hatter inside WSL.

### B2. A shell for hatter

hatter is a bash script. It needs `bash`, `ssh`, `jq`, `git` and, on the
servers, `tmux`.

```sh
brew install jq git                       # macOS
sudo apt update && sudo apt install -y jq git tmux   # Debian, Ubuntu, WSL
```

Your ssh key has to be where this shell's ssh looks. In WSL that is WSL's own
`~/.ssh`, not the Windows one:

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp /mnt/c/Users/<you>/.ssh/id_ed25519 ~/.ssh/
chmod 600 ~/.ssh/id_ed25519
ssh you@shell.example.com true && echo "ssh works"
```

### B3. Install hatter

```sh
git clone https://github.com/smcd-personal/hatter ~/src/hatter
mkdir -p ~/.local/bin
install -m 755 ~/src/hatter/bin/hatter ~/.local/bin/hatter
export PATH="$HOME/.local/bin:$PATH"      # add to ~/.bashrc or ~/.zshrc
hatter --help
```

### B4. Your config

You already have one:

```sh
git clone you@shell.example.com:git/dotfiles.git ~/.config/hatter
hatter hat status
```

Or start from nothing:

```sh
hatter hat add dev --ssh you@shell.example.com
hatter provision dev
hatter attach dev-website        # creates the session and attaches
```

`provision` sets up tpm, tmux-resurrect and tmux-continuum, wraps each pane's
login shell in a loop so a stray ctrl-D hands back a prompt instead of
destroying a tab, and installs the `bye` command for closing one on purpose.

### B5. Configure WezTerm

`~/.wezterm.lua` (or `~/.config/wezterm/wezterm.lua`), exactly as in
[A6](#a6-configure-wezterm):

```lua
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

local hatter = wezterm.plugin.require 'https://github.com/smcd-personal/hatter'
hatter.apply_to_config(config)

return config
```

The picker and launcher then work as in [A7](#a7-use-it).

### B6. Attach from any terminal

`hatter attach` needs no WezTerm at all:

```sh
hatter attach dev-website     # that workspace, created if it is not running
hatter attach dev             # pick one of dev's workspaces
```

Given a hat, it offers every workspace the config records plus any running on
the server that were never recorded, which the WezTerm picker cannot see.

### B7. Back up your config

```sh
cd ~/.config/hatter && git init -b main     # only if it is not a clone already
git remote add origin you@shell.example.com:git/dotfiles.git
hatter backup "first backup"
```

## What about credentials?

`hatter creds push` reads Claude logins from the macOS Keychain via `cswap`,
which has no Windows or Linux equivalent. Push from the Mac, or log in on the
server itself once; the credential persists there either way.

## Following the client work

- [#2: the client adapter interface](https://github.com/smcd-personal/hatter/issues/2),
  the seam every backend plugs into
- [#4: the WezTerm adapter](https://github.com/smcd-personal/hatter/issues/4),
  which makes `restore` and `sync` drive WezTerm
- [#6: the headless adapter](https://github.com/smcd-personal/hatter/issues/6),
  of which `hatter attach` is the first part
