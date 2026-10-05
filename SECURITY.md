# Security

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private reporting instead:
[Report a vulnerability](https://github.com/smcd-personal/hatter/security/advisories/new).
Only the maintainer sees it. Expect a first reply within a week.

Worth reporting: anything that writes a credential to disk, exposes one in a
process list, log or error message, sends it to the wrong host, or lets a
config file run commands it should not.

## What hatter handles

- **Claude Code credentials.** They live in your OS keychain, and
  `hatter creds push` sends one to a hat over ssh. The payload goes straight
  down the ssh pipe and is written on the server only to Claude Code's own
  credentials file, with mode `0600` from creation. Nothing is staged on disk
  on either side.
- **ssh.** hatter never handles ssh authentication. It uses your ssh client,
  your keys and your agent. Its connection-sharing sockets live under
  `/tmp/.hatter-ssh-<uid>/`, owned by you.

## Your config

`~/.config/hatter/config.json` holds **no secrets**, but it does map your
infrastructure: hostnames, usernames, project names. Treat it accordingly:

- Keep the `hatter backup` remote **private**. A server you own is ideal.
- Redact hostnames and usernames before pasting config or output into an
  issue.

## Supported versions

Only the latest commit on `main`.
