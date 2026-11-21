-- hatter for WezTerm: reach your hats from any machine WezTerm runs on,
-- Windows included, with no bash and no WSL.
--
-- It reads hatter's config.json - the same file `hatter backup` pushes to
-- git - and offers every workspace in a picker. Choosing one opens a tab that
-- runs
--
--   ssh -t <dest> tmux new-session -A -s <session>
--
-- so the server's tmux holds the state, exactly as it does under cmux. A hat
-- becomes a WezTerm workspace, and a hatter workspace a tab titled with its
-- session name; choosing one that is already open switches to it.
--
--   local hatter = wezterm.plugin.require 'https://github.com/smcd-personal/hatter'
--   hatter.apply_to_config(config)
--
-- See docs/install-wezterm.md.

local wezterm = require 'wezterm'
local act = wezterm.action
local mux = wezterm.mux

local M = {}

local function default_config_path()
  local base = os.getenv 'XDG_CONFIG_HOME'
  if not base or base == '' then
    base = wezterm.home_dir .. '/.config'
  end
  return base .. '/hatter/config.json'
end

-- The folder a file is in, for either slash.
local function dir_of(path)
  return (path:gsub('[/\\][^/\\]*$', ''))
end

-- The same quoting bin/hatter uses for the remote shell: single-quote
-- everything, except that "$HOME" and "~" must reach the remote shell
-- unquoted to mean anything.
local function sq(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

local function sq_dir(d)
  if d == '$HOME' or d == '~' then
    return '"$HOME"'
  elseif d:sub(1, 6) == '$HOME/' then
    return '"$HOME"' .. sq(d:sub(6))
  elseif d:sub(1, 2) == '~/' then
    return '"$HOME"' .. sq(d:sub(2))
  end
  return sq(d)
end

-- tmux will not hold "." or ":" in a session name and quietly substitutes "_".
local function tmux_session_name(s)
  return (s:gsub('[.:]', '_'))
end

-- The argv that attaches to one session. A destination starting with "-"
-- would be read by ssh as an option, so it is refused, as bin/hatter does.
function M.ssh_args(opts, hat, session)
  if type(hat) ~= 'table' then
    return nil, 'is not in the config'
  end
  local dest = hat.ssh
  if type(dest) ~= 'string' or dest == '' or dest:sub(1, 1) == '-' then
    return nil, 'has no usable ssh destination (it is empty or starts with "-")'
  end
  local remote = 'tmux new-session -A -s ' .. sq(session)
    .. ' -c ' .. sq_dir(hat.remote_dir or '$HOME')
  return { opts.ssh or 'ssh', '-t', dest, remote }
end

-- Read the config fresh every time, so a `git pull` shows up without
-- reloading WezTerm. Returns the decoded table, or nil and a reason.
function M.read(opts)
  local path = opts.config_path or default_config_path()
  local f, err = io.open(path, 'r')
  if not f then
    return nil, 'cannot read ' .. path .. ': ' .. tostring(err)
      .. '. Clone your hatter config to that folder, or pass config_path to'
      .. ' hatter.apply_to_config in your WezTerm config.'
  end
  local text = f:read '*a'
  f:close()
  local ok, cfg = pcall(wezterm.json_parse, text)
  if not ok or type(cfg) ~= 'table' then
    return nil, path .. ' is not valid JSON. Fix it by hand, or, if the'
      .. ' folder is a git clone, go back to the last committed copy with:'
      .. ' git -C ' .. dir_of(path) .. ' checkout -- ' .. path:match '[^/\\]*$'
  end
  return cfg
end

-- Every recorded workspace, as { hat, group, session }, sorted.
function M.entries(cfg)
  local out = {}
  for gname, g in pairs(cfg.groups or {}) do
    if cfg.hats and cfg.hats[g.hat] then
      for session in pairs(g.sessions or {}) do
        table.insert(out, { hat = g.hat, group = gname, session = session })
      end
    end
  end
  table.sort(out, function(a, b)
    if a.hat ~= b.hat then return a.hat < b.hat end
    if a.group ~= b.group then return a.group < b.group end
    return a.session < b.session
  end)
  return out
end

local function hat_names(cfg)
  local names = {}
  for name in pairs(cfg.hats or {}) do table.insert(names, name) end
  table.sort(names)
  return names
end

-- Every message, success or failure, also goes to a plain text log the user
-- can open in any editor or screen reader after the toast or overlay is gone:
-- ${XDG_STATE_HOME:-~/.local/state}/hatter/wezterm.log, beside hatter's own
-- state, unless opts.log_path says otherwise.
local function default_log_path()
  local base = os.getenv 'XDG_STATE_HOME'
  if not base or base == '' then
    base = wezterm.home_dir .. '/.local/state'
  end
  return base .. '/hatter/wezterm.log'
end

-- Append one message to the log. Returns the log's path, or nil if it could
-- not be written, which never stops the message being shown.
local function log(opts, level, msg)
  local path = opts.log_path or default_log_path()
  local f = io.open(path, 'a')
  if not f then
    -- Lua cannot make a directory, so ask the OS once, then try again.
    local dir = dir_of(path)
    local mkdir = { 'mkdir', '-p', dir }
    if (wezterm.target_triple or ''):find 'windows' then
      mkdir = { 'cmd.exe', '/c', 'mkdir', (dir:gsub('/', '\\')) }
    end
    pcall(wezterm.run_child_process, mkdir)
    f = io.open(path, 'a')
  end
  if not f then return nil end
  f:write(os.date '%Y-%m-%d %H:%M:%S', ' ', level, ': ',
    (msg:gsub('\r?\n', '\n    ')), '\n')
  f:close()
  return path
end

-- A success: a toast is enough, as nothing needs doing; the log keeps it.
local function notify(window, opts, msg)
  wezterm.log_info('hatter: ' .. msg)
  log(opts, 'info', msg)
  window:toast_notification('hatter', msg, nil, 5000)
end

-- A failure stays on screen until the user closes it. A toast is gone in five
-- seconds and is drawn by the OS, which may never read it out, so it would
-- take the reason the action failed with it. PromptInputLine shows free
-- text, newlines kept, on every platform since WezTerm 20230408; Enter closes
-- it, and so does Escape on an empty line. Whatever is typed is ignored.
local function fail(window, pane, opts, msg)
  wezterm.log_warn('hatter: ' .. msg)
  local path = log(opts, 'error', msg)
  local text = 'hatter: ' .. msg .. '\n\n'
  if path then
    text = text .. 'This message is also kept in ' .. path .. '\n'
  end
  window:perform_action(act.PromptInputLine {
    description = text .. 'Press Enter to close.',
    action = wezterm.action_callback(function() end),
  }, pane or window:active_pane())
end

-- Switch to the hat's workspace and the session's tab, opening either if it
-- is not there yet. Tabs are matched on the title set when they were opened.
function M.open(window, opts, cfg, hat_name, session)
  local args, err = M.ssh_args(opts, cfg.hats[hat_name], session)
  if not args then
    fail(window, nil, opts, "cannot open workspace '" .. session .. "': hat '"
      .. hat_name .. "' " .. err .. '. On a machine with hatter, run: hatter hat add '
      .. hat_name .. ' --ssh user@host, then hatter backup. Then choose'
      .. " 'Update config from git' in this picker.")
    return
  end

  local target
  for _, mw in ipairs(mux.all_windows()) do
    if mw:get_workspace() == hat_name then
      for _, tab in ipairs(mw:tabs()) do
        if tab:get_title() == session then
          mux.set_active_workspace(hat_name)
          tab:activate()
          return
        end
      end
      target = target or mw
    end
  end

  local tab
  if target then
    tab = target:spawn_tab { args = args }
  else
    tab = mux.spawn_window { workspace = hat_name, args = args }
  end
  tab:set_title(session)
  mux.set_active_workspace(hat_name)
  tab:activate()
end

local function prompt_new(window, pane, opts, cfg, hat_name)
  window:perform_action(act.PromptInputLine {
    description = 'New workspace on ' .. hat_name .. ' (name, without the hat prefix)',
    action = wezterm.action_callback(function(win, _, line)
      if not line or line == '' then return end
      local session = tmux_session_name(line)
      if session:sub(1, #hat_name + 1) ~= hat_name .. '-' then
        session = hat_name .. '-' .. session
      end
      M.open(win, opts, cfg, hat_name, session)
    end),
  }, pane)
end

function M.pull(window, opts)
  local dir = dir_of(opts.config_path or default_config_path())
  -- run_child_process raises, rather than returning false, when git cannot
  -- be started at all (not on PATH).
  local called, ok, out, errout = pcall(wezterm.run_child_process, {
    'git', '-C', dir, 'pull', '--ff-only',
  })
  if not called then
    fail(window, nil, opts, 'could not run git to update the config: '
      .. tostring(ok) .. '\nInstall Git, make sure it is on PATH, and restart WezTerm.')
    return
  end
  if not ok then
    -- git's own words say why; a failed pull reports on stderr.
    local why = ((errout ~= '' and errout) or out or ''):gsub('%s+$', '')
    fail(window, nil, opts, 'git pull in ' .. dir .. ' failed:\n\n' .. why
      .. '\n\nFix it in a terminal (cd ' .. dir .. ', then git status),'
      .. " then choose 'Update config from git' again.")
    return
  end
  -- git reports some of a successful pull on stderr, so show whichever has it.
  local msg = ((out ~= '' and out) or errout or ''):gsub('%s+$', '')
  notify(window, opts, 'config updated: ' .. msg)
end

-- The picker: every workspace, a "new workspace" line per hat, and a line to
-- pull the config from its git remote.
function M.picker(opts)
  opts = opts or {}
  return wezterm.action_callback(function(window, pane)
    local cfg, err = M.read(opts)
    if not cfg then
      fail(window, pane, opts, err)
      return
    end

    local choices, by_id = {}, {}
    for _, e in ipairs(M.entries(cfg)) do
      local id = 'w' .. #choices
      by_id[id] = e
      table.insert(choices, {
        id = id,
        label = e.hat .. '  ›  ' .. e.group .. '  ›  ' .. e.session,
      })
    end
    for _, h in ipairs(hat_names(cfg)) do
      local id = 'n' .. #choices
      by_id[id] = { hat = h }
      table.insert(choices, { id = id, label = h .. '  ›  + new workspace' })
    end
    table.insert(choices, { id = 'pull', label = 'Update config from git (git pull)' })

    window:perform_action(act.InputSelector {
      title = 'hatter',
      fuzzy = true,
      fuzzy_description = 'Workspace: ',
      choices = choices,
      action = wezterm.action_callback(function(win, p, id)
        if not id then return end
        if id == 'pull' then return M.pull(win, opts) end
        local e = by_id[id]
        if e.session then
          M.open(win, opts, cfg, e.hat, e.session)
        else
          prompt_new(win, p, opts, cfg, e.hat)
        end
      end),
    }, pane)
  end)
end

-- Bind the picker (CTRL+SHIFT+O unless opts.key / opts.mods say otherwise),
-- add every workspace to the launch menu, and reload when the config changes.
--
-- opts.config_path  hatter's config.json  (default ~/.config/hatter/config.json)
-- opts.ssh          the ssh to run        (default "ssh", which on Windows is
--                                          the built-in OpenSSH client)
-- opts.log_path     where messages are kept (default
--                                          ~/.local/state/hatter/wezterm.log)
function M.apply_to_config(config, opts)
  opts = opts or {}

  config.keys = config.keys or {}
  table.insert(config.keys, {
    key = opts.key or 'O',
    mods = opts.mods or 'CTRL|SHIFT',
    action = M.picker(opts),
  })

  local path = opts.config_path or default_config_path()
  wezterm.add_to_config_reload_watch_list(path)

  local cfg = M.read(opts)
  if not cfg then return end
  config.launch_menu = config.launch_menu or {}
  for _, e in ipairs(M.entries(cfg)) do
    local args = M.ssh_args(opts, cfg.hats[e.hat], e.session)
    if args then
      table.insert(config.launch_menu, {
        label = e.hat .. ' › ' .. e.group .. ' › ' .. e.session,
        args = args,
      })
    end
  end
end

return M
