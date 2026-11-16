local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Hc: sidekick.cli.Session
---@field external? boolean running in a Herdr app tab or split instead of an embedded terminal
---@field hc_terminal_id? string herdr-core terminal address (e.g. "t7")
local M = {}
M.__index = M

--- Milliseconds to wait for a paste to show on the terminal's screen.
M.PASTE_TIMEOUT = 1000

local function non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

--- Execute a command and decode its JSON output.
---@param cmd string[]
---@param opts? {notify?:boolean}
---@return table?
function M.json(cmd, opts)
  local lines = Util.exec(cmd, opts)
  if not lines then
    return nil
  end
  if #lines == 0 then
    return {}
  end

  local ok, ret = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(ret) ~= "table" then
    if not opts or opts.notify ~= false then
      Util.error(("Failed to parse JSON response: `%s`"):format(table.concat(cmd, " ")))
    end
    return nil
  end

  return ret
end

--- Execute a `herdr-app do` command with a JSON payload.
---@param command string
---@param payload table
---@param opts? {notify?:boolean}
---@return table?
function M.app_do(command, payload, opts)
  if vim.fn.executable("herdr-app") ~= 1 then
    if not opts or opts.notify ~= false then
      Util.error("`herdr-app` is not executable")
    end
    return nil
  end
  local ret = M.json({ "herdr-app", "do", command, vim.json.encode(payload) }, opts)
  if ret and ret.error then
    if not opts or opts.notify ~= false then
      Util.error(("herdr-app %s failed: %s"):format(command, tostring(ret.error)))
    end
    return nil
  end
  return ret
end

--- Find the herdr-app space containing the current terminal, if any.
---@return string?
function M.current_space()
  local current = vim.env.HC_TERMINAL_ID
  if not non_empty_string(current) or vim.fn.executable("herdr-app") ~= 1 then
    return nil
  end
  local ret = M.json({ "herdr-app", "ls" }, { notify = false })
  for _, space in ipairs(ret and ret.spaces or {}) do
    for _, tab in ipairs(space.tabs or {}) do
      for _, term in ipairs(tab.terminals or {}) do
        if term.terminal == current then
          return space.id
        end
      end
    end
  end
  return nil
end

--- Build argv for launching this session's tool, preserving tool env overrides.
---@return string[]
function M:tool_argv()
  local env_args = {} ---@type string[]
  for key, value in pairs(self.tool.env or {}) do
    if value == false then
      env_args[#env_args + 1] = "-u"
      env_args[#env_args + 1] = key
    else
      env_args[#env_args + 1] = ("%s=%s"):format(key, tostring(value))
    end
  end

  local argv = {} ---@type string[]
  if #env_args > 0 then
    argv[#argv + 1] = "env"
    vim.list_extend(argv, env_args)
  end
  vim.list_extend(argv, self.tool.cmd)
  return argv
end

---@return sidekick.cli.terminal.Cmd?
function M:attach()
  if not self.external and self.hc_terminal_id then
    return { cmd = { "hc", "attach", self.hc_terminal_id } }
  end
end

function M:init()
  self.hc_terminal_id = self.hc_terminal_id or (type(self.id) == "string" and self.id:match("^hc (%S+)$") or nil)
  if self.started then
    self.external = Config.cli.mux.create ~= "terminal"
  else
    self.external = non_empty_string(vim.env.HC_TERMINAL_ID) and Config.cli.mux.create ~= "terminal"
  end
  self.priority = self.external and 10 or 50
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  local argv = self:tool_argv()

  if not self.external then
    local cmd = { "hc", "run", "--bg", "--json", "--outlive-parent", "--no-notify", "--cwd", self.cwd, "--" }
    vim.list_extend(cmd, argv)
    local ret = M.json(cmd, { notify = true })
    local addr = ret and ret.address
    if not non_empty_string(addr) then
      return
    end
    self.hc_terminal_id = addr
    self.id = ("hc %s"):format(addr)
    self.started = true
    return { cmd = { "hc", "attach", addr } }
  end

  local command, payload, label
  if Config.cli.mux.create == "window" then
    command = "tab.new"
    payload = {
      name = self.tool.name,
      space = M.current_space(),
      folder = self.cwd,
      argv = argv,
    }
    label = "tab"
  elseif Config.cli.mux.create == "split" then
    command = "terminal.open"
    payload = {
      name = self.tool.name,
      folder = self.cwd,
      place = Config.cli.mux.split.vertical and "right" or "down",
      argv = argv,
    }
    label = "split"
  else
    return
  end

  local ret = M.app_do(command, payload, { notify = true })
  local addr = ret and ret.terminal
  if not non_empty_string(addr) then
    return
  end

  self.hc_terminal_id = addr
  self.id = ("hc %s"):format(addr)
  self.started = true
  Util.info(("Started **%s** in a new Herdr %s"):format(self.tool.name, label))
end

function M:is_running()
  if not self.hc_terminal_id then
    return false
  end
  local info = M.json({ "hc", "get", "--json", self.hc_terminal_id }, { notify = false })
  return info ~= nil and info.state == "live"
end

--- List all Sidekick sessions running in herdr-core terminals.
---@return sidekick.cli.session.State[]
function M.sessions()
  local list = M.json({ "hc", "ls", "--json" }, { notify = false })
  local terminals = list and list.terminals
  if type(terminals) ~= "table" or #terminals == 0 then
    return {}
  end

  local tools = Config.tools()
  local Procs = require("sidekick.cli.procs")
  local procs = Procs.new()

  -- Include `hc attach <addr>` client PIDs so an attached embedded terminal
  -- (priority 100) wins over the underlying `hc` session during deduplication.
  local attach_pids = {} ---@type table<string, integer[]>
  for _, proc in pairs(procs:list()) do
    local addr = proc.cmd:match("^%S*hc%s+attach%s+(%S+)") or proc.cmd:match("%f[%S]hc%s+attach%s+(%S+)")
    if addr then
      attach_pids[addr] = attach_pids[addr] or {}
      attach_pids[addr][#attach_pids[addr] + 1] = proc.pid
    end
  end

  local ret = {} ---@type sidekick.cli.session.State[]
  for _, term in ipairs(terminals) do
    local addr = term.address
    if non_empty_string(addr) and (term.state == nil or term.state == "live") then
      local info = M.json({ "hc", "get", "--json", addr }, { notify = false })
      if info then
        local fg = type(info.foreground) == "table" and info.foreground or nil
        local fg_cwd = fg and non_empty_string(fg.cwd) and fg.cwd or nil
        local term_cwd = non_empty_string(term.cwd) and term.cwd or nil
        local where = non_empty_string(term.where) and term.where or nil

        local is_remote = addr:find("/", 1, true) ~= nil
        local has_local_proc = not is_remote and type(info.pid) == "number" and procs:get(info.pid) ~= nil

        local pids = {} ---@type integer[]
        local pid_seen = {} ---@type table<integer, boolean>
        local function add_pid(pid)
          if type(pid) == "number" and not pid_seen[pid] then
            pids[#pids + 1] = pid
            pid_seen[pid] = true
          end
        end

        if has_local_proc then
          for _, pid in ipairs(Procs.pids(info.pid)) do
            add_pid(pid)
          end
        elseif not is_remote then
          add_pid(info.pid)
          if fg then
            add_pid(fg.pid)
          end
        end
        for _, cpid in ipairs(attach_pids[addr] or {}) do
          add_pid(cpid)
        end

        local matched = false
        if has_local_proc then
          procs:walk(info.pid, function(proc)
            for _, tool in pairs(tools) do
              if tool:is_proc(proc) then
                ret[#ret + 1] = {
                  id = ("hc %s"):format(addr),
                  cwd = proc.cwd or fg_cwd or term_cwd or vim.fn.getcwd(0),
                  tool = tool,
                  hc_terminal_id = addr,
                  mux_session = where,
                  pids = pids,
                }
                matched = true
                return true
              end
            end
          end)
        end

        -- Fallback for remote terminals whose PIDs do not exist in local /proc.
        if not matched and fg and type(fg.pid) == "number" then
          local fg_cmd = type(fg.argv) == "table" and table.concat(fg.argv, " ")
            or (non_empty_string(fg.name) and fg.name or "")
          ---@type sidekick.cli.Proc
          local p = {
            pid = is_remote and 0 or fg.pid,
            ppid = (not is_remote and type(info.pid) == "number") and info.pid or 0,
            cmd = fg_cmd,
            cwd = fg_cwd or term_cwd,
          }
          for _, tool in pairs(tools) do
            if tool:is_proc(p) then
              ret[#ret + 1] = {
                id = ("hc %s"):format(addr),
                cwd = p.cwd or vim.fn.getcwd(0),
                tool = tool,
                hc_terminal_id = addr,
                mux_session = where,
                pids = pids,
              }
              break
            end
          end
        end
      end
    end
  end

  return ret
end

--- Focus the Herdr pane or sub-agent view for this terminal.
---@return boolean focused
function M:focus()
  if not self.hc_terminal_id then
    return false
  end
  return M.app_do("agent.focus", { terminal = self.hc_terminal_id }, { notify = false }) ~= nil
end

--- Whether text can be pasted through herdr-app and the Wayland clipboard.
---@return boolean
function M.can_paste()
  return vim.env.WAYLAND_DISPLAY ~= nil
    and vim.fn.executable("wl-copy") == 1
    and vim.fn.executable("wl-paste") == 1
    and vim.fn.executable("herdr-app") == 1
end

---@param text string
---@return boolean
local function set_clipboard(text)
  local ret = vim.system({ "wl-copy", "--type", "text/plain" }, { stdin = text, stdout = false, stderr = false }):wait()
  return ret.code == 0
end

--- The terminal's screen as text, without history.
---@return string?
function M:screen()
  local ret = vim.system({ "hc", "read", self.hc_terminal_id }, { text = true }):wait()
  if ret.code ~= 0 then
    return nil
  end
  return ret.stdout
end

--- Put text in the agent's prompt without submitting it.
--- `hc send` always presses Enter and herdr-core has no paste-only call, so this
--- goes through the clipboard and herdr-app's paste into the focused terminal.
--- The text clipboard is restored afterwards; a non-text one is cleared.
--- `terminal.paste` reports success even when herdr-app could not read the
--- clipboard (Wayland only lets the focused window read it), so the paste counts
--- only once the terminal's screen changes.
---@param text string
---@return boolean ok, string? err
function M:paste(text)
  local saved = vim.system({ "wl-paste", "--no-newline", "--type", "text/plain" }, { text = true }):wait()
  local function restore()
    if saved.code == 0 then
      set_clipboard(saved.stdout or "")
      return
    end
    vim.system({ "wl-copy", "--clear" }, { stdout = false, stderr = false }):wait()
  end

  if not set_clipboard(text) then
    restore()
    return false, "`wl-copy` failed"
  end
  if not M.app_do("agent.focus", { terminal = self.hc_terminal_id }, { notify = false }) then
    restore()
    return false, "`herdr-app` could not focus it"
  end
  local before = self:screen()
  local pasted = M.app_do("terminal.paste", vim.empty_dict(), { notify = false }) ~= nil
  restore()
  if not pasted then
    return false, "`herdr-app` could not paste"
  end
  local changed = vim.wait(M.PASTE_TIMEOUT, function()
    return self:screen() ~= before
  end, 50)
  if not changed then
    return false, "nothing arrived; herdr-app can only read the clipboard while its window is focused"
  end
  return true
end

--- Put text in the herdr-core terminal's prompt; `submit` presses Enter.
---@param text string
function M:send(text)
  if not self.hc_terminal_id then
    return
  end
  local clean = (text or ""):gsub("\n$", "")
  if clean == "" then
    return
  end
  if not M.can_paste() then
    Util.error("Sending to herdr-core needs `herdr-app`, `wl-copy` and `wl-paste` on Wayland")
    return
  end
  local ok, err = self:paste(clean)
  if not ok then
    Util.error(("Could not paste into herdr-core terminal `%s`: %s"):format(self.hc_terminal_id, err))
  end
end

function M:submit()
  if not self.hc_terminal_id then
    return
  end
  Util.exec({ "hc", "keys", self.hc_terminal_id, "enter" })
end

--- Capture screen and scrollback from the herdr-core terminal.
---@return string?
function M:dump()
  if not self.hc_terminal_id then
    return
  end
  local _, ret = Util.exec({ "hc", "read", "--lines", tostring(Config.cli.mux.dump), self.hc_terminal_id })
  return ret
end

return M
