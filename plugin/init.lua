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
-- becomes a WezTerm window, and a hatter workspace a tab in it titled with its
-- session name; choosing one that is already open switches to it.
-- (layout = 'workspace' makes each hat a WezTerm workspace instead.)
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
    return nil, 'not in the config'
  end
  local dest = hat.ssh
  if type(dest) ~= 'string' or dest == '' or dest:sub(1, 1) == '-' then
    return nil, 'no usable ssh destination'
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
  end
  local text = f:read '*a'
  f:close()
  local ok, cfg = pcall(wezterm.json_parse, text)
  if not ok or type(cfg) ~= 'table' then
    return nil, path .. ' is not valid JSON'
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

local function notify(window, msg)
  wezterm.log_warn('hatter: ' .. msg)
  if window then
    window:toast_notification('hatter', msg, nil, 5000)
  end
end

local function layout(opts)
  return opts.layout or 'window'
end

-- The hat a tab title belongs to: the hat of a recorded session with that
-- name, else the hat whose "<hat>-" prefix it carries (the longest, so that
-- "web-app" beats "web" for "web-app-api").
function M.hat_of_title(cfg, title)
  if type(title) ~= 'string' or title == '' then return nil end
  for _, e in ipairs(M.entries(cfg)) do
    if e.session == title then return e.hat end
  end
  local best
  for name in pairs(cfg.hats or {}) do
    if title:sub(1, #name + 1) == name .. '-' and (not best or #name > #best) then
      best = name
    end
  end
  return best
end

-- Which window holds which hat. wezterm.GLOBAL lasts as long as the WezTerm
-- process, so it survives a config reload. Window ids are never reused.
local function remember(hat_name, mw)
  local id = mw:window_id()
  wezterm.GLOBAL['hatter.win.' .. hat_name] = id
  wezterm.GLOBAL['hatter.hat.' .. tostring(id)] = hat_name
end

function M.hat_of_window(window_id)
  return wezterm.GLOBAL['hatter.hat.' .. tostring(window_id)]
end

-- The mux window showing a hat, or nil. Under the window layout: the window
-- remembered for it if it is still open, else the first window with a tab
-- whose title belongs to the hat. Under the workspace layout: a window in
-- the workspace named after the hat.
function M.hat_window(opts, cfg, hat_name)
  local windows = mux.all_windows()
  if layout(opts) == 'workspace' then
    for _, mw in ipairs(windows) do
      if mw:get_workspace() == hat_name then return mw end
    end
    return nil
  end
  local id = wezterm.GLOBAL['hatter.win.' .. hat_name]
  if id then
    for _, mw in ipairs(windows) do
      if mw:window_id() == id then return mw end
    end
  end
  for _, mw in ipairs(windows) do
    for _, tab in ipairs(mw:tabs()) do
      if M.hat_of_title(cfg, tab:get_title()) == hat_name then
        remember(hat_name, mw)
        return mw
      end
    end
  end
  return nil
end

-- The GUI window for a mux window, or nil. gui_window() raises, rather than
-- returning nil, where there is no GUI (wezterm-mux-server).
local function gui_of(mw)
  local ok, gui = pcall(function() return mw:gui_window() end)
  if ok then return gui end
  return nil
end

-- Show a mux window: switch to its workspace, then raise it.
local function bring_forward(mw)
  local ws = mw:get_workspace()
  if ws ~= mux.get_active_workspace() then
    mux.set_active_workspace(ws)
  end
  local gui = gui_of(mw)
  if gui then pcall(function() gui:focus() end) end
end

-- A new window starts at WezTerm's default size; opts.maximize fills the
-- screen instead. The GUI window appears some time after the mux window
-- (at startup, only once gui-startup has returned), so it is marked here and
-- maximized by the update-status handler apply_to_config registers, which
-- WezTerm runs for each GUI window once it is up.
local function maybe_maximize(opts, mw)
  if not opts.maximize then return end
  local gui = gui_of(mw)
  if gui then
    gui:maximize()
  else
    wezterm.GLOBAL['hatter.maximize.' .. tostring(mw:window_id())] = true
  end
end

-- Switch to the session's tab in its hat's window (or, under the workspace
-- layout, its hat's workspace), opening the tab, and the window, if they are
-- not there yet. Tabs are matched on the title set when they were opened.
function M.open(window, opts, cfg, hat_name, session)
  local args, err = M.ssh_args(opts, cfg.hats[hat_name], session)
  if not args then
    notify(window, "hat '" .. hat_name .. "': " .. err)
    return
  end

  local target = M.hat_window(opts, cfg, hat_name)
  if target then
    -- Under the workspace layout the session may be in any of the hat's
    -- windows, so look in all of them.
    local look = { target }
    if layout(opts) == 'workspace' then
      look = {}
      for _, mw in ipairs(mux.all_windows()) do
        if mw:get_workspace() == hat_name then table.insert(look, mw) end
      end
    end
    for _, mw in ipairs(look) do
      for _, tab in ipairs(mw:tabs()) do
        if tab:get_title() == session then
          tab:activate()
          bring_forward(mw)
          return
        end
      end
    end
  end

  local tab
  if target then
    tab = target:spawn_tab { args = args }
  else
    local workspace = hat_name
    if layout(opts) == 'window' then
      workspace = mux.get_active_workspace()
    end
    local _
    tab, _, target = mux.spawn_window { workspace = workspace, args = args }
    if layout(opts) == 'window' then remember(hat_name, target) end
    maybe_maximize(opts, target)
  end
  tab:set_title(session)
  tab:activate()
  bring_forward(target)
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
  local path = opts.config_path or default_config_path()
  local dir = path:gsub('[/\\][^/\\]*$', '')
  -- run_child_process raises, rather than returning false, when git cannot
  -- be started at all (not on PATH).
  local called, ok, out, errout = pcall(wezterm.run_child_process, {
    'git', '-C', dir, 'pull', '--ff-only',
  })
  if not called then
    notify(window, 'git pull failed: ' .. tostring(ok))
    return
  end
  -- git reports some of a successful pull on stderr, so show whichever has it.
  local msg = ((out ~= '' and out) or errout or ''):gsub('%s+$', '')
  notify(window, (ok and 'config updated: ' or 'git pull failed: ') .. msg)
end

-- The picker: every workspace, a "new workspace" line per hat, and a line to
-- pull the config from its git remote. Given only_hat, just that hat's
-- workspaces and its "new workspace" line.
local function show_picker(window, pane, opts, cfg, only_hat)
  local choices, by_id = {}, {}
  for _, e in ipairs(M.entries(cfg)) do
    if not only_hat or e.hat == only_hat then
      local id = 'w' .. #choices
      by_id[id] = e
      table.insert(choices, {
        id = id,
        label = e.hat .. '  ›  ' .. e.group .. '  ›  ' .. e.session,
      })
    end
  end
  for _, h in ipairs(hat_names(cfg)) do
    if not only_hat or h == only_hat then
      local id = 'n' .. #choices
      by_id[id] = { hat = h }
      table.insert(choices, { id = id, label = h .. '  ›  + new workspace' })
    end
  end
  if not only_hat then
    table.insert(choices, { id = 'pull', label = 'Update config from git (git pull)' })
  end

  window:perform_action(act.InputSelector {
    title = only_hat and ('hatter: open ' .. only_hat) or 'hatter',
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
end

function M.picker(opts)
  opts = opts or {}
  return wezterm.action_callback(function(window, pane)
    local cfg, err = M.read(opts)
    if not cfg then
      notify(window, err)
      return
    end
    show_picker(window, pane, opts, cfg)
  end)
end

-- The hat switcher: every hat, open ones first. Choosing an open hat brings
-- its window forward; choosing one that is not open offers its workspaces.
function M.switcher(opts)
  opts = opts or {}
  return wezterm.action_callback(function(window, pane)
    local cfg, err = M.read(opts)
    if not cfg then
      notify(window, err)
      return
    end
    local open, closed = {}, {}
    for _, h in ipairs(hat_names(cfg)) do
      if M.hat_window(opts, cfg, h) then
        table.insert(open, { id = h, label = h })
      else
        table.insert(closed, { id = h, label = h .. '  (not open)' })
      end
    end
    for _, c in ipairs(closed) do table.insert(open, c) end

    window:perform_action(act.InputSelector {
      title = 'hatter: switch hat',
      fuzzy = true,
      fuzzy_description = 'Hat: ',
      choices = open,
      action = wezterm.action_callback(function(win, p, h)
        if not h then return end
        local mw = M.hat_window(opts, cfg, h)
        if mw then
          bring_forward(mw)
        else
          show_picker(win, p, opts, cfg, h)
        end
      end),
    }, pane)
  end)
end

-- Bind the picker and the hat switcher, add every workspace to the launch
-- menu, reload when the config changes, and (window layout) start each hat
-- window's title with its hat.
--
-- opts.layout       'window' (default): one WezTerm window per hat.
--                   'workspace': one WezTerm workspace per hat.
-- opts.key, opts.mods         the picker       (default CTRL+SHIFT+O)
-- opts.switch_key, opts.switch_mods
--                             the hat switcher (default CTRL+SHIFT+S);
--                             switch_key = false leaves it unbound
-- opts.maximize     open new hat windows maximized (default false)
-- opts.window_title false leaves window titles to WezTerm (or to your own
--                   format-window-title handler)
-- opts.config_path  hatter's config.json  (default ~/.config/hatter/config.json)
-- opts.ssh          the ssh to run        (default "ssh", which on Windows is
--                                          the built-in OpenSSH client)
function M.apply_to_config(config, opts)
  opts = opts or {}

  config.keys = config.keys or {}
  table.insert(config.keys, {
    key = opts.key or 'O',
    mods = opts.mods or 'CTRL|SHIFT',
    action = M.picker(opts),
  })
  if opts.switch_key ~= false then
    table.insert(config.keys, {
      key = opts.switch_key or 'S',
      mods = opts.switch_mods or 'CTRL|SHIFT',
      action = M.switcher(opts),
    })
  end

  if layout(opts) == 'window' and opts.window_title ~= false then
    wezterm.on('format-window-title', function(tab)
      local hat_name = M.hat_of_window(tab.window_id)
      if not hat_name then return nil end
      local title = tab.tab_title
      if not title or title == '' then title = tab.active_pane.title end
      return hat_name .. ' | ' .. title
    end)
  end

  if opts.maximize then
    wezterm.on('update-status', function(window)
      local key = 'hatter.maximize.' .. tostring(window:window_id())
      if wezterm.GLOBAL[key] then
        wezterm.GLOBAL[key] = nil
        window:maximize()
      end
    end)
  end

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
