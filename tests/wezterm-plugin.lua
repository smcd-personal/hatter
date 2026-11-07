-- A WezTerm config that tests plugin/init.lua against WezTerm's real mux.
-- tests/wezterm-plugin.sh runs it on macOS and Linux; CI runs it on Windows.
-- It runs under wezterm-mux-server, which has no GUI, so no window opens and
-- nothing takes focus.
--
-- It needs three environment variables:
--   HATTER_PLUGIN      path to plugin/init.lua
--   HATTER_TEST_DIR    an empty directory: the config goes in, results come out
--   HATTER_TEST_SLEEP  "sleep" or "ping": what each tab runs instead of ssh
--
-- At mux-startup it opens tabs through hatter.open and checks where they
-- land, writing "ok ..." or "FAIL ..." lines and then "DONE" to results.txt.
-- The caller stops WezTerm afterwards.

local wezterm = require 'wezterm'
local mux = wezterm.mux

local dir = os.getenv 'HATTER_TEST_DIR'
local hatter = dofile(os.getenv 'HATTER_PLUGIN')

local cfg_path = dir .. '/config.json'
local f = assert(io.open(cfg_path, 'w'))
f:write(wezterm.json_encode {
  version = 3,
  hats = {
    a = { ssh = 'a@example.com', remote_dir = '$HOME' },
    b = { ssh = 'b@example.com', remote_dir = '$HOME' },
    ['b-x'] = { ssh = 'bx@example.com', remote_dir = '$HOME' },
    c = { ssh = 'c@example.com', remote_dir = '$HOME' },
  },
  groups = {
    A = { hat = 'a', sessions = { ['a-one'] = {}, ['a-two'] = {} } },
    B = { hat = 'b', sessions = { ['b-one'] = {} } },
    C = { hat = 'c', sessions = { ['c-one'] = {} } },
  },
})
f:close()

-- Every tab runs this instead of ssh, so nothing leaves the machine.
local stand_in = { 'sleep', '300' }
if os.getenv 'HATTER_TEST_SLEEP' == 'ping' then
  stand_in = { 'ping', '-n', '300', '127.0.0.1' }
end
hatter.ssh_args = function() return stand_in end

local out = assert(io.open(dir .. '/results.txt', 'w'))
local function check(cond, what)
  out:write((cond and 'ok ' or 'FAIL ') .. what .. '\n')
  out:flush()
end

local function titles(mw)
  local t = {}
  for _, tab in ipairs(mw:tabs()) do table.insert(t, tab:get_title()) end
  table.sort(t)
  return table.concat(t, ',')
end

local function run()
  local opts = { config_path = cfg_path }
  local cfg = assert(hatter.read(opts))

  check(hatter.hat_of_title(cfg, 'a-one') == 'a', 'a recorded session belongs to its hat')
  check(hatter.hat_of_title(cfg, 'b-x-new') == 'b-x', 'the longest hat prefix wins')
  check(hatter.hat_of_title(cfg, 'b-new') == 'b', 'an unrecorded session goes by its prefix')
  check(hatter.hat_of_title(cfg, 'zsh') == nil, 'a plain tab belongs to no hat')

  -- Window layout, the default.
  local before = #mux.all_windows()
  hatter.open(nil, opts, cfg, 'a', 'a-one')
  local wa = hatter.hat_window(opts, cfg, 'a')
  check(wa ~= nil, 'opening a session gives its hat a window')
  check(#mux.all_windows() == before + 1, 'one new window for the first hat')

  hatter.open(nil, opts, cfg, 'b', 'b-one')
  local wb = hatter.hat_window(opts, cfg, 'b')
  check(wb ~= nil and wb:window_id() ~= wa:window_id(), 'a second hat gets its own window')
  check(#mux.all_windows() == before + 2, 'two hats, two windows')

  hatter.open(nil, opts, cfg, 'a', 'a-two')
  check(titles(wa) == 'a-one,a-two', "a hat's second session is a tab in its window: " .. titles(wa))
  check(titles(wb) == 'b-one', "the other hat's window is untouched: " .. titles(wb))

  hatter.open(nil, opts, cfg, 'a', 'a-one')
  check(titles(wa) == 'a-one,a-two', 'an open session is reused, not opened twice')
  check(#mux.all_windows() == before + 2, 'reopening adds no window')
  check(wa:get_workspace() == wb:get_workspace(), 'hat windows share the current workspace')

  check(hatter.hat_of_window(wa:window_id()) == 'a', 'the window remembers its hat, for the title')
  wezterm.GLOBAL['hatter.win.a'] = nil
  wezterm.GLOBAL['hatter.hat.' .. tostring(wa:window_id())] = nil
  local found = hatter.hat_window(opts, cfg, 'a')
  check(found ~= nil and found:window_id() == wa:window_id(), 'with the memory gone, the window is found by its tabs')
  check(hatter.hat_of_window(wa:window_id()) == 'a', 'and remembered again')

  -- Workspace layout.
  local wopts = { config_path = cfg_path, layout = 'workspace' }
  hatter.open(nil, wopts, cfg, 'c', 'c-one')
  local wc = hatter.hat_window(wopts, cfg, 'c')
  check(wc ~= nil and wc:get_workspace() == 'c', "workspace layout: the hat gets a workspace named after it")
  hatter.open(nil, wopts, cfg, 'c', 'c-one')
  check(titles(wc) == 'c-one', 'workspace layout: an open session is reused')

  out:write 'DONE\n'
  out:close()
end

wezterm.on('mux-startup', function()
  local ok, err = pcall(run)
  if not ok then
    out:write('FAIL error: ' .. tostring(err) .. '\nDONE\n')
    out:close()
  end
end)

-- Its own socket, so it never meets a WezTerm you are running.
return {
  unix_domains = { { name = 'hatter-test', socket_path = dir .. '/sock' } },
}
