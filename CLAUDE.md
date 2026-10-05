# Working on hatter

The GitHub repo (`smcd-personal/hatter`) is the only source of truth for
hatter. These rules hold for every session, human or agent.

## Every code change starts from an issue

- Find the issue, or file one with `gh issue create` before writing any code.
  Say what is wrong or missing, and what done looks like.
- One issue, one branch, one pull request. The PR body says `Fixes #N`.
- Docs-only fixes can skip the issue, but still go through a PR.

## Work only in a worktree

The main checkout at `~/dev/hatter` stays on `main` and is never edited. Each
issue gets its own worktree next to it:

```sh
cd ~/dev/hatter
git fetch && git switch main && git pull --ff-only
git worktree add ../hatter-wt/<N>-<slug> -b <N>-<slug> origin/main
cd ../hatter-wt/<N>-<slug>
```

- One session per worktree. Never edit a worktree another session is using.
- Push the branch and open a PR. Do not push to `main`, even though
  branch protection lets the admin bypass it.
- After the PR merges: `git worktree remove ../hatter-wt/<N>-<slug>` and
  delete the local branch.

## Never edit the installed copy

`~/.local/bin/hatter` is a build output. Editing it in place breaks every
hatter that is already running: bash reads a script as it goes, so a running
copy resumes at its old byte offset in the new file and fails with a bogus
syntax error. Install only from `main`, after a merge:

```sh
git -C ~/dev/hatter pull --ff-only
install -m 755 ~/dev/hatter/bin/hatter ~/.local/bin/hatter
```

`install` replaces the file rather than rewriting it, so running copies keep
reading the old one.

## Nothing private reaches GitHub

The repo is public. Nothing about the maintainer's servers, identity or use
of hatter goes into it: no real hostnames, usernames, email addresses, names,
project or organisation names, and no description of the maintainer's own
setup (how many hosts, which accounts, what runs where). Examples use
`example.com`. This applies to code, docs, commit messages, author fields,
branch names, issues, PRs and comments alike.

`tools/leakcheck` enforces it at every stage:

| Stage | Check |
|---|---|
| commit | `.githooks/pre-commit` and `commit-msg` |
| push | `.githooks/pre-push`: diffs, messages, author and committer |
| issue, PR, comment | `tools/leakcheck --text <file>` on the body **before** `gh issue create`, `gh pr create`, `gh pr edit` or `gh ... comment`; agents also have a Claude Code hook that blocks the post |
| CI | the `leakcheck` workflow, generic patterns only |

- The private patterns live in `~/.config/hatter/leak-patterns` and in
  hatter's config, never in the repo. Add a pattern there when a new private
  name appears.
- Details the maintainer has deliberately kept public are listed in a private
  accept-list, `~/.config/hatter/leak-accept`. Only the maintainer adds to it.
- Never bypass a check (`--no-verify`, editing the patterns or the
  accept-list, adding a private name to `.leakcheck-allow`). If it fires, remove the detail. If you think it
  is a false positive, stop and ask.
- Write bodies to a file, check them, then post with `--body-file`.

Each new worktree shares the repo's git config, so the hooks are on once:

```sh
git -C ~/dev/hatter config core.hooksPath .githooks
```

## Before pushing

- The code rules are in [CONTRIBUTING.md](CONTRIBUTING.md): bash 3.2,
  `set -e` hazards, bash special variables, explicit client targets.
- `bash -n bin/hatter` and `shellcheck --severity=error bin/hatter` pass.
- `tools/leakcheck --all` is clean.
