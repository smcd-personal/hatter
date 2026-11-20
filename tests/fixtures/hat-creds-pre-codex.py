#!/usr/bin/env python3
"""hat-creds - receive Claude Code credentials pushed from the hatter client.

The client holds every login (in the macOS Keychain, via cswap) and pushes one
here over ssh; nothing is ever stored on this server that the client did not
put here on purpose.

    hat-creds install     read a `cswap export` envelope on stdin, install it
    hat-creds status      print what is installed now, as JSON
    hat-creds clear       remove the installed credential

Claude Code reads the credential when a session starts, so an already-running
session keeps the account it started with. New sessions pick up the new one.
"""
import json
import os
import sys
import time

HOME = os.path.expanduser("~")
CRED = os.path.join(HOME, ".claude", ".credentials.json")
CONF = os.path.join(HOME, ".claude.json")


def die(msg):
    sys.stderr.write("hat-creds: %s\n" % msg)
    raise SystemExit(1)


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def write_private(path, text):
    """Write 0600 from creation - never expose a token at the umask default."""
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, 0o700)
    tmp = "%s.hat-creds.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def install():
    try:
        envelope = json.load(sys.stdin)
    except ValueError as e:
        die("stdin is not a valid cswap export: %s" % e)
    if not isinstance(envelope, dict):
        die("export envelope must be a JSON object")
    if envelope.get("version") != 1:
        die("unsupported export version: %r" % envelope.get("version"))
    if envelope.get("encrypted") is True:
        die("encrypted exports are not supported - decrypt before piping")
    accounts = envelope.get("accounts")
    if not isinstance(accounts, list) or len(accounts) != 1:
        die("expected exactly one account in the export, got %s"
            % (len(accounts) if isinstance(accounts, list) else "none"))

    acct = accounts[0]
    email = acct.get("email") or "(unknown)"
    creds = acct.get("credentials")

    if isinstance(creds, str):
        # An API-key account: the credential is the raw sk-ant-api… string.
        write_private(CRED, creds.strip() + "\n")
        kind = "api_key"
    elif isinstance(creds, dict):
        # Merge rather than replace: mcpOAuth and trustedDeviceToken belong to
        # THIS machine (MCP server logins, device trust) and are not in the
        # export. Overwriting the file wholesale would silently log the server
        # out of every MCP server it had authorised.
        existing = read_json(CRED)
        merged = existing if isinstance(existing, dict) else {}
        merged.update(creds)
        write_private(CRED, json.dumps(merged, indent=2) + "\n")
        kind = "oauth"
    else:
        die("credentials for %s are neither an object nor an API key" % email)

    # ~/.claude.json carries the account identity Claude Code displays. Merge
    # oauthAccount in and leave the rest of the file (projects, history,
    # onboarding state) exactly as it was.
    oauth_account = (acct.get("config") or {}).get("oauthAccount")
    if isinstance(oauth_account, dict):
        conf = read_json(CONF)
        if conf is None and os.path.exists(CONF):
            # The file is there but unreadable or not JSON. Rewriting it would
            # throw away every project, history entry and onboarding flag it
            # holds, so leave it: the credential itself is already installed and
            # only the displayed account name is affected.
            sys.stderr.write("hat-creds: %s exists but could not be parsed - "
                             "leaving it alone\n" % CONF)
        else:
            if not isinstance(conf, dict):
                conf = {}
            conf["oauthAccount"] = oauth_account
            write_private(CONF, json.dumps(conf, indent=2) + "\n")

    print("installed %s (%s) as %s" % (email, kind, CRED))


def status():
    out = {"host": os.uname().nodename, "user": os.environ.get("USER", ""),
           "kind": "none", "email": None, "organizationName": None,
           "expiresAt": None, "expiresInSeconds": None, "expired": None,
           "hasRefreshToken": None}
    raw = read_text(CRED)
    if raw is None:
        print(json.dumps(out))
        return
    stripped = raw.strip()
    if stripped.startswith("sk-ant-api"):
        out["kind"] = "api_key"
    else:
        try:
            obj = json.loads(stripped)
        except ValueError:
            out["kind"] = "unreadable"
            print(json.dumps(out))
            return
        oauth = obj.get("claudeAiOauth")
        if isinstance(oauth, dict):
            out["kind"] = "oauth"
            # An expired access token is routine: Claude Code trades the
            # refresh token for a new one on its own. Only a credential with
            # no refresh token actually needs pushing again.
            out["hasRefreshToken"] = bool(oauth.get("refreshToken"))
            exp = oauth.get("expiresAt")
            if isinstance(exp, (int, float)):
                # Claude Code stores expiry in milliseconds.
                out["expiresAt"] = exp
                out["expiresInSeconds"] = int(exp / 1000.0 - time.time())
                out["expired"] = out["expiresInSeconds"] <= 0
        else:
            out["kind"] = "unknown"

    conf = read_json(CONF) or {}
    acct = conf.get("oauthAccount")
    if isinstance(acct, dict):
        out["email"] = acct.get("emailAddress")
        out["organizationName"] = acct.get("organizationName")
        # One email can hold logins in two organizations; this says which.
        out["organizationUuid"] = acct.get("organizationUuid")
    print(json.dumps(out))


def clear():
    removed = []
    for path in (CRED,):
        try:
            os.unlink(path)
            removed.append(path)
        except OSError:
            pass
    conf = read_json(CONF)
    if isinstance(conf, dict) and "oauthAccount" in conf:
        del conf["oauthAccount"]
        write_private(CONF, json.dumps(conf, indent=2) + "\n")
        removed.append("%s:oauthAccount" % CONF)
    print("cleared: %s" % (", ".join(removed) if removed else "nothing to clear"))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd in ("-h", "--help", "help"):
        sys.stdout.write(__doc__)
        return
    if cmd == "install":
        install()
    elif cmd == "status":
        status()
    elif cmd == "clear":
        clear()
    else:
        die("unknown command %r (install|status|clear)" % cmd)


if __name__ == "__main__":
    main()
