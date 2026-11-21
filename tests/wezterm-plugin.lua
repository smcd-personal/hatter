-- The WezTerm plugin's messages (#295), against a stub of the wezterm module:
-- a failure stays on screen in a PromptInputLine overlay until the user
-- closes it, a success is a toast, and both are appended to a log file.
--
-- Run by tests/wezterm-plugin.sh, under a plain Lua (5.1 to 5.4) or under
-- WezTerm's own Lua as a config file. It reads three environment variables:
-- HATTER_PLUGIN (plugin/init.lua), HATTER_TEST_DIR (an empty folder) and
-- HATTER_TEST_OUT (where it writes PASS, or a FAIL line per failure). It
-- returns a config table so WezTerm can load it.

local plugin = os.getenv 'HATTER_PLUGIN'
local dir = os.getenv 'HATTER_TEST_DIR'
local outpath = os.getenv 'HATTER_TEST_OUT'
local fails = {}
local function check(cond, what)
  if not cond then table.insert(fails, 'FAIL: ' .. what) end
end

-- The stub records the calls the plugin makes.
local calls
local child -- what run_child_process does next
local function reset()
  calls = { toasts = {}, actions = {}, children = {} }
end

local stub = {
  home_dir = dir .. '/home',
  target_triple = 'x86_64-unknown-linux-gnu',
  mux = {},
  log_info = function() end,
  log_warn = function() end,
  log_error = function() end,
  json_parse = function() error 'no JSON in this stub' end,
  action_callback = function(fn) return fn end,
  run_child_process = function(args)
    table.insert(calls.children, args)
    return child(args)
  end,
  -- act.X { ... } gives { kind = 'X', args = { ... } }.
  action = setmetatable({}, {
    __index = function(_, kind)
      return function(args) return { kind = kind, args = args } end
    end,
  }),
}

local active = { name = 'active pane' }
local window = {
  toast_notification = function(_, title, msg, _, ms)
    table.insert(calls.toasts, { title = title, msg = msg, ms = ms })
  end,
  perform_action = function(_, action, pane)
    table.insert(calls.actions, { action = action, pane = pane })
  end,
  active_pane = function() return active end,
}

local saved = package.loaded.wezterm
package.loaded.wezterm = stub
local ok, M = pcall(dofile, plugin)
package.loaded.wezterm = saved
if not ok then
  table.insert(fails, 'FAIL: the plugin did not load: ' .. tostring(M))
  M = nil
end

local function slurp(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local t = f:read '*a'
  f:close()
  return t
end

local function has(s, needle)
  return type(s) == 'string' and s:find(needle, 1, true) ~= nil
end

-- The one overlay a failure opened, or nil.
local function overlay()
  local a = calls.actions[1]
  if #calls.actions == 1 and a.action.kind == 'PromptInputLine' then
    return a.action.args, a.pane
  end
end

-- Inside a function run under pcall: an error must reach the result file, not
-- stop WezTerm loading this as a config.
local function run()
  local log = dir .. '/state/wezterm.log'
  local cfgdir = dir .. '/cfg'
  local opts = { config_path = cfgdir .. '/config.json', log_path = log }

  -- 1. git pull fails: git's own words stay on screen, not in a toast.
  reset()
  child = function() return false, '', 'fatal: Not possible to fast-forward, aborting.\n' end
  M.pull(window, opts)
  local o, pane = overlay()
  check(o, 'a failed pull did not open one PromptInputLine overlay')
  check(#calls.toasts == 0, 'a failed pull still went to a toast')
  if o then
    check(has(o.description, 'git pull in ' .. cfgdir .. ' failed'), 'failed pull: no "what failed": ' .. o.description)
    check(has(o.description, 'Not possible to fast-forward'), "failed pull: git's output not shown")
    check(has(o.description, 'git status'), 'failed pull: no "what to do next"')
    check(has(o.description, 'Press Enter to close'), 'failed pull: does not say how to close it')
    check(has(o.description, log), 'failed pull: does not say where the log is')
    check(type(o.action) == 'function', 'failed pull: the overlay has no action callback')
    check(pane == active, 'failed pull: the overlay is not on the active pane')
  end
  local text = slurp(log)
  check(has(text, ' error: git pull in '), 'failed pull: not in the log: ' .. tostring(text))
  check(has(text, '\n    fatal: Not possible'), "failed pull: git's lines not indented in the log")

  -- 2. git pull succeeds: a toast, and the log, but no overlay to close.
  reset()
  child = function() return true, 'Already up to date.\n', '' end
  M.pull(window, opts)
  check(#calls.actions == 0, 'a successful pull opened an overlay')
  check(#calls.toasts == 1 and calls.toasts[1].msg == 'config updated: Already up to date.',
    'a successful pull did not toast "config updated: Already up to date."')
  text = slurp(log)
  check(has(text, ' info: config updated: Already up to date.'), 'successful pull: not in the log')
  check(has(text, ' error: git pull in '), 'the log lost the earlier failure')

  -- 3. git cannot be started at all: run_child_process raises.
  reset()
  child = function() error 'No such file or directory (os error 2)' end
  M.pull(window, opts)
  o = overlay()
  check(o and has(o.description, 'could not run git') and has(o.description, 'Install Git'),
    'git missing: no overlay saying what failed and what to do')
  check(#calls.toasts == 0, 'git missing: still went to a toast')

  -- 4. The picker cannot read the config: the overlay is on the picker's pane.
  reset()
  local mypane = { name = 'picker pane' }
  M.picker(opts)(window, mypane)
  o, pane = overlay()
  check(o and has(o.description, 'cannot read ' .. opts.config_path)
    and has(o.description, 'config_path'), 'unreadable config: no overlay with the fix')
  check(pane == mypane, "unreadable config: the overlay is not on the picker's pane")
  check(#calls.toasts == 0, 'unreadable config: still went to a toast')

  -- 5. A hat whose destination would be read as an ssh option.
  reset()
  local cfg = { hats = { bad = { ssh = '-oProxyCommand=x' } } }
  M.open(window, opts, cfg, 'bad', 'bad-web')
  o = overlay()
  check(o and has(o.description, "cannot open workspace 'bad-web'")
    and has(o.description, 'hatter hat add bad --ssh'), 'bad hat: no overlay with the fix')
  check(#calls.toasts == 0, 'bad hat: still went to a toast')

  -- 6. The log's folder is missing: the plugin asks the OS to make it. The
  -- stub makes nothing, so the message is still shown, without claiming a log.
  reset()
  local nolog = { config_path = opts.config_path, log_path = dir .. '/missing/wezterm.log' }
  child = function(args)
    if args[1] == 'git' then return false, '', 'fatal: boom\n' end
    return true, '', ''
  end
  M.pull(window, nolog)
  local mk = calls.children[2]
  check(mk and mk[1] == 'mkdir' and mk[2] == '-p' and mk[3] == dir .. '/missing',
    'missing log folder: no mkdir -p of it')
  o = overlay()
  check(o and has(o.description, 'fatal: boom') and not has(o.description, 'also kept in'),
    'unwritable log: the overlay is missing, or claims a log it could not write')

  -- 7. The same on Windows: cmd's mkdir, with backslashes.
  reset()
  stub.target_triple = 'x86_64-pc-windows-msvc'
  M.pull(window, { config_path = opts.config_path, log_path = 'C:/no/such/dir/wezterm.log' })
  mk = calls.children[2]
  check(mk and mk[1] == 'cmd.exe' and mk[4] == 'C:\\no\\such\\dir', 'Windows: no cmd.exe mkdir of the log folder')
  stub.target_triple = 'x86_64-unknown-linux-gnu'

  -- 8. With no log_path, the log goes to $XDG_STATE_HOME/hatter, or the
  -- home's .local/state/hatter (the runner unsets XDG_STATE_HOME).
  reset()
  child = function() return false, '', 'fatal: here\n' end
  M.pull(window, { config_path = opts.config_path })
  o = overlay()
  check(o and has(o.description, dir .. '/home/.local/state/hatter/wezterm.log'),
    'default log path: not ~/.local/state/hatter/wezterm.log: ' .. (o and o.description or 'no overlay'))
end

if M then
  local ran, err = pcall(run)
  if not ran then table.insert(fails, 'FAIL: the test raised: ' .. tostring(err)) end
end

local f = assert(io.open(outpath, 'w'))
f:write(#fails == 0 and 'PASS\n' or table.concat(fails, '\n') .. '\n')
f:close()

return {}
