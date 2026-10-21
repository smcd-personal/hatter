# Installing hatter on Android, in Termux

Android has no app for hatter, and does not need one.
[Termux](https://termux.dev) gives a phone a real Linux userland, with bash
and ssh, so `bin/hatter` itself runs there. What you get:

- **`hatter` opens a picker.** It lists your hats, then that hat's
  workspaces, and attaches to the one you pick over ssh (or mosh). The last
  entry starts a new workspace.
- **Home-screen shortcuts.** One per hat and one per workspace, through
  Termux's home-screen widget. A tap opens the picker, or goes straight in.
- **A key row for tmux.** Esc, Ctrl, Alt, Tab, arrows, the tmux prefix,
  detach and scroll, above the keyboard.
- **The same sessions as your desktop.** A workspace is a tmux session on the
  server, so the phone and the desktop can be attached at once. Each gets a
  sensible size once the server is provisioned (see
  [Phone and desktop on one session](#phone-and-desktop-on-one-session)).

The phone is a client only: `restore`, `sync`, the rack and the credential
commands drive cmux on a Mac. `hatter provision`, `hatter key add` and
`hatter backup` do run here.

## Before you start

You need:

- **Servers that hatter already knows about**: a `config.json` with your
  hats, backed up to a git remote with `hatter backup`. Starting from
  nothing works too; the installer asks for a first hat.
- **A machine that already reaches those servers**, to authorise the
  phone's ssh key with `hatter key add`. Servers that take passwords can
  skip this.

## 1. Termux

Termux comes from two places, and hatter works with either:

- **Google Play** ([Termux on Google Play](https://play.google.com/store/apps/details?id=com.termux)).
  Use this one if your phone only installs apps from Play. It needs Android
  11 or newer. The home-screen widget is built into the app, so there is
  nothing else to install.
- **F-Droid or Termux's GitHub releases** ([F-Droid](https://f-droid.org/packages/com.termux/)).
  Also install **Termux:Widget** from the same place, for the home-screen
  shortcuts. The two apps are signed together, and an F-Droid Termux will
  not take commands from a Termux:Widget installed some other way.

The two builds are signed differently and install packages from separate
repositories, so Android will not install one over the other: to switch,
uninstall the first. Open Termux once and let it finish setting up.

## 2. The installer

In Termux, with your own config remote (wherever `hatter backup` pushes):

```sh
curl -fsSLo install-termux.sh https://raw.githubusercontent.com/smcd-personal/hatter/main/tools/install-termux.sh
bash install-termux.sh --config-remote you@shell.example.com:git/dotfiles.git
```

[`tools/install-termux.sh`](../tools/install-termux.sh) checks each step
before it acts, so running it again is safe and doubles as a health check:

1. installs bash, openssh, jq, git and curl with `pkg`, if missing
2. installs `hatter` to `$PREFIX/bin`, or replaces it if it has changed
3. uses your ssh key (`~/.ssh/id_ed25519`, or the first `id_*` there), or
   makes a new one
4. clones your config, or pulls it if it is already there. With no remote it
   asks for a first hat instead
5. connects to every hat. A server seen for the first time has its host key
   recorded, as answering "yes" to ssh would
6. adds the tmux key row to `~/.termux/termux.properties`
7. writes the home-screen shortcuts

| Option | |
|---|---|
| `--config-remote <url>` | where `hatter backup` pushes; cloned the first time |
| `--hat <name>=<user@host>` | add a hat, when there is no config to clone |
| `--key <path>` | the private key to use |
| `--ref <ref>` | the hatter branch, tag or commit to install |
| `--mosh` | also install mosh |
| `--prefix <letter>` | your tmux prefix, if it is not `C-b` |
| `--no-extra-keys`, `--no-shortcuts` | skip those steps |
| `--non-interactive` | never ask; a new key gets no passphrase |

**About the key's passphrase.** hatter makes several short ssh connections
when it lists a hat's workspaces, and a key with a passphrase asks for it on
each one unless an agent holds it. On a phone with a screen lock, a key with
no passphrase is a reasonable choice. If you want one, start `ssh-agent` and
`ssh-add` the key from `~/.bashrc`, so you type it once per Termux session.

## 3. Let the phone in

A new key cannot authorise itself on a server that only takes keys. When a
hat refuses it, the installer prints the line to run on a machine that
already gets in:

```sh
hatter key add 'ssh-ed25519 AAAAC3Nz... hatter@termux' --all
```

Run that there, then run the installer again on the phone. Every hat should
say `ok`.

### A config kept on GitHub

If `hatter backup` pushes to a private GitHub repo, give `--config-remote`
its ssh address (the one under **Code > SSH** on GitHub), not the https one:
the phone has a key, not a GitHub login. GitHub is not a hat, so when it
refuses the key the installer prints two lines instead, to run on a machine
that is signed in to `gh` and already reaches your hats:

```sh
echo 'ssh-ed25519 AAAAC3Nz... hatter@termux' | gh repo deploy-key add - -R you/hatter-config --title termux
hatter key add 'ssh-ed25519 AAAAC3Nz... hatter@termux' --all
```

The first adds the key to that one repo as a read-only deploy key. That is
narrower than adding it to your GitHub account, which would let the phone
reach every repo you have. The phone only reads the config; add
`--allow-write` if you want to run `hatter backup` from it.

## 4. Use it

```sh
hatter                  # pick a hat, then a workspace
hatter attach dev       # pick one of dev's workspaces
hatter attach dev-atlas # straight in
```

Detach with the tmux prefix then `d`, or the **detach** key in the key row.
The session keeps running on the server.

### Shortcuts

Long-press the home screen and add the Termux widget: **Termux:Widget** with
the F-Droid build, or the widget the Play build of Termux provides itself. It
lists one shortcut per hat and per workspace, under `hatter/`. A workspace's
shortcut is named `<hat> <rest of its name>`, so `dev atlas` is the
`dev-atlas` workspace, and each hat's workspaces sort right after it.

The shortcuts come from the config. After pulling a newer one (run the
installer again, or `git -C ~/.config/hatter pull`), rewrite them:

```sh
hatter shortcuts
```

### The key row

Two rows, above the keyboard:

```
ESC  ^B      CTRL  ALT  TAB  HOME  UP    END
detach scroll  /    -    |   LEFT  DOWN  RIGHT
```

`^B` sends the tmux prefix. `detach` and `scroll` send the prefix and then
`d` or `[` (copy mode; `q` leaves it). If your prefix is not `C-b`, pass
`--prefix a` (for `C-a`) to the installer.

The row lives between `# >>> hatter managed >>>` markers in
`~/.termux/termux.properties`, and re-running the installer rewrites only
that block. If the file already sets `extra-keys` outside it, the installer
leaves yours alone and says so.

### mosh

ssh drops when the phone sleeps or moves between Wi-Fi and mobile data; mosh
rides it out. To use it for a hat:

```sh
bash install-termux.sh --mosh   # installs mosh here
hatter hat add dev --mosh       # dev attaches with mosh from now on
```

The server needs `mosh-server` installed and UDP ports 60000-61000 open.
Where mosh is not installed, a hat set to use it attaches over ssh as usual,
so the setting is safe in a config that a desktop shares. `hatter hat add dev
--no-mosh` turns it off.

## Phone, foldable and tablet

hatter does not change with the screen; tmux does the work.

- **Phone.** Portrait gives about 40 to 50 columns. Landscape, with the key
  row, is the comfortable way to read a wide pane. Pinch to zoom the text.
- **Foldable.** Folding and unfolding resizes the terminal, and tmux redraws
  at the new size. Nothing to set up.
- **Tablet, or a phone with a keyboard.** With a hardware keyboard the key row
  is mostly not needed; hide it with the volume-up + `q` shortcut.

## Phone and desktop on one session

tmux sizes a window to fit its clients. By default it shrinks to the smallest
one attached, so a phone would squeeze the desktop's view of the same session.
`hatter provision` sets two tmux options on the server so each screen gets a
sensible size:

- `window-size latest`: a window takes the size of the client that used it
  last. Type on the phone and it fits the phone; go back to the desktop and
  it fits the desktop again.
- `aggressive-resize on`: a window is sized by the clients looking at it, not
  by every client on the session.

Run it once per server, from any machine with hatter, the phone included:

```sh
hatter provision dev
```

tmux's `mouse` option is left alone, because it changes how text selection
works on the desktop. Turn it on yourself if you want touch scrolling in tmux.

## Troubleshooting

**`hatter` is slow on every command.** hatter shares one ssh connection per
server through a control socket. Android has no `/tmp`, so the socket goes
under Termux's `$TMPDIR` instead, in a directory with a short name; if no
short enough path exists, hatter skips sharing and each command opens its own
connection.

**`Permission denied (publickey)`.** The hat does not have this phone's key
yet. See [step 3](#3-let-the-phone-in).

**A shortcut does nothing.** With the F-Droid build, Termux:Widget and Termux
have to come from the same source (both F-Droid, or both GitHub). The Play
build has no separate widget app, so there is nothing to mismatch. On recent
Android, Termux also needs the "Display over other apps" permission to open a
session from the home screen. Check the shortcut itself runs from a Termux
prompt with `bash ~/.shortcuts/hatter/dev`.
