# `hatter state --json`

One JSON document with every hat, group, workspace and tab, and the status of
each tab. It is for programs: a GUI, a picker, a script. People have
`hatter list`, `hatter ps` and the rack.

```sh
hatter state --json              # every hat
hatter state --json --hat dev    # one hat
```

The command exits 0 whether or not each hat's server answers. A server that is
down shows up as `reachable: false`. A server that takes the connection and
then hangs is given 30 seconds (set `HATTER_SERVER_TIMEOUT` to change it), and
then counts as down. Every server is asked at once, so the whole run takes
about as long as the slowest server.

This page is the only description of the schema. `hatter ps --json` uses the
same [agent fields](#agent).

## Versioning

`schema` is a whole number. It goes up when a field is removed or renamed,
or when a value changes meaning. Adding a field does not change it, so
ignore fields you don't know about.

## Document

```json
{
  "schema": 1,
  "generated": 1767268800,
  "hats": [ <hat>, ... ]
}
```

| Field | Type | Meaning |
|---|---|---|
| `schema` | number | The schema version, 1 for this page |
| `generated` | number | When the document was made, in epoch seconds by this machine's clock |
| `hats` | array | One [hat](#hat) per configured hat, sorted by name. With `--hat`, just that one |

## Hat

| Field | Type | Meaning |
|---|---|---|
| `name` | string | The hat's name |
| `ssh` | string or null | Its ssh destination, `user@host` |
| `color` | string or null | Its colour from the config |
| `reachable` | boolean | The server answered over ssh |
| `why` | string or null | Why the hat is not `live`: why ssh failed (`connection refused`, `timed out`, `no answer in 30s`, ...), or what the server reported (`tmux is not running`). Null when `live` |
| `live` | boolean | The tree below comes from the server. When false, it is the **saved layout** from the config, and the live-only fields below are null |
| `groups` | array | The hat's [groups](#group): its Unassigned group first, as cmux shows it, then the rest in the order the config keeps them |
| `ungrouped` | array | [Workspaces](#workspace) running on the server that no group records. Always empty when `live` is false |

## Group

| Field | Type | Meaning |
|---|---|---|
| `key` | string | The group's key in the config. Unique across all hats |
| `name` | string | The name shown, which is the key unless the group has its own name |
| `color` | string or null | The group's colour |
| `icon` | string or null | The group's icon |
| `unassigned` | boolean | True for the group hatter keeps for workspaces nobody placed |
| `workspaces` | array | Its [workspaces](#workspace), in saved order |

## Workspace

A workspace is a tmux session.

| Field | Type | Meaning |
|---|---|---|
| `name` | string | The tmux session's name |
| `running` | boolean or null | The session exists on the server. Null when the hat is not `live` |
| `mirrored` | boolean or null | A client is mirroring it in control mode, the way cmux does. Null when not `live` |
| `clients` | number or null | Clients attached to it, mirrors included. Null when not `live` |
| `tabs` | array | Its [tabs](#tab) |

When the hat is `live`, `tabs` lists the windows that are running, in index
order, then the snoozed tabs that came from this workspace, then the
hibernated ones. A saved tab that is not running is not listed. When the hat
is not `live`, `tabs` lists the saved tabs.

## Tab

A tab is a tmux window.

| Field | Type | Meaning |
|---|---|---|
| `index` | number or null | The window's index in its session. Null for a snoozed, hibernated or saved tab |
| `window_id` | string or null | The tmux window id, such as `@12`. A snoozed tab still has one. Null for a hibernated or saved tab |
| `title` | string | The window's name. Empty when it has none |
| `pinned` | boolean | The tab is pinned |
| `snoozed` | object or null | `{"until": <epoch seconds or null>}` when the tab is snoozed. `until` is null when only the tab's record says it is snoozed |
| `hibernated` | object or null | `{"since": <epoch seconds or null>}` when the session is hibernated and has no window. A hibernated session wakes only when you wake it, so it has no wake time |
| `agent` | object or null | The [agent fields](#agent). Null for a saved tab |

## Agent

These are the status fields of a tab. They appear as `agent` in `hatter state --json`
and in each row of `hatter ps --json`, with the same values. A `ps --json`
row also has `hat`, `group`, `workspace`, `tab` (the title, with `* ` in
front when pinned) and `window_id`.

Every value is a string. A value that is not known is `-`.

| Field | Meaning |
|---|---|
| `status` | `approval` or `question`: the agent is asking you something. `waiting`: its turn ended. `working`: a tool call has no result yet, or the transcript moved in the last 30 seconds. `idle`: waiting for an hour or more. `snoozed`, `asleep`: a snoozed tab, a hibernated session. `shell`: no agent runs in the tab |
| `model` | The model of the last turn, shortened: `opus-5.5`. `codex` for a Codex tab with nothing more known |
| `ctx` | Context in use: the last turn's whole input, cached or not, such as `142k` or `1.2M` |
| `idle` | Time since you or the agent last said anything, such as `5m`, `2h30m` or `3d` |
| `age` | Time since the session's first message, across resumes |
| `cwd` | The working directory, with the home directory shown as `~` |
| `last_prompt` | The last thing you typed, cut to 300 characters |
| `session_id` | The Claude session id. Empty when no agent runs |
