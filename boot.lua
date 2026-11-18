--[[
  boot.lua  -  Lymanos Robot Control: the robot's bootloader

  Put this file on the robot's hard drive as /home/boot.lua BEFORE you
  assemble the robot, together with /etc/rc.d/robotctl.lua, and switch that
  service on with:   rc robotctl enable
  (OpenOS then starts this file in the background every time it boots - it
  works on a robot without a screen.)

  What it does, every time the robot starts:
    1. Asks the controller (over the Linked Card) for the latest robot program.
    2. Downloads it if it changed, saves it as /home/robot.lua and runs it.
    3. If the controller doesn't answer, runs the copy it saved last time.
    4. When the controller presses "Update Robot", the robot program hands
       control back here and the new version is downloaded and started.
    5. If the program crashes, the error is sent to the controller and the
       robot waits for a fixed version (press "Update Robot" on the controller).

  This file never needs to change. Only robot.lua (kept on the controller) does.
]]

local BOOT_VERSION = "1.0"
local PROG = "/home/robot.lua"
local WAKE = "RC_WAKE"              -- the controller's Wake button sends this

local component = require("component")
local computer  = require("computer")
local event     = require("event")

if not component.isAvailable("tunnel") then
  io.stderr:write("boot.lua: no Linked Card found - the robot can't reach its controller.\n")
  return
end
local tunnel = component.tunnel
pcall(tunnel.setWakeMessage, WAKE)   -- lets the controller turn the robot on

local function say(...) print("[boot] " .. table.concat({ ... }, " ")) end
local function send(kind, ...) pcall(tunnel.send, "RC", kind, ...) end

-- same checksum as the controller uses
local function checksum(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

local function readAll(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeAll(path, s)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(s)
  f:close()
  return true
end

-- ask the controller for the program; returns status text
local function fetch()
  local cur = readAll(PROG)
  local sum = cur and checksum(cur) or 0
  send("HELLO", sum, cur and #cur or 0, BOOT_VERSION)
  local parts, total, got, want = {}, nil, 0, nil
  local deadline = computer.uptime() + 8
  while computer.uptime() < deadline do
    local ev = { event.pull(math.max(0.05, deadline - computer.uptime()), "modem_message") }
    if ev[1] and ev[2] == tunnel.address and ev[6] == "RC" then
      local kind = ev[7]
      if kind == "UPTODATE" then
        return "up to date"
      elseif kind == "NOCODE" then
        return "controller has no robot program yet"
      elseif kind == "CODE" then
        local i, n, s, data = ev[8], ev[9], ev[10], ev[11]
        if type(i) == "number" and type(data) == "string" then
          if not parts[i] then got = got + 1 end
          parts[i], total, want = data, n, s
          deadline = computer.uptime() + 8
          if total and got >= total then
            local code = table.concat(parts, "", 1, total)
            if checksum(code) ~= want then
              send("BOOTMSG", "download damaged - keeping the old program")
              return "download damaged"
            end
            if not writeAll(PROG, code) then
              send("BOOTMSG", "couldn't save the program - is the drive full?")
              return "save failed"
            end
            send("BOOTMSG", "updated: " .. #code .. " bytes")
            return "updated"
          end
        end
      end
    end
  end
  return "controller didn't answer"
end

-- wait until the controller says "UPDATE" (after a crash or missing program)
local function waitForUpdate(seconds)
  local deadline = computer.uptime() + seconds
  while computer.uptime() < deadline do
    local ev = { event.pull(math.max(0.05, deadline - computer.uptime()), "modem_message") }
    if ev[1] and ev[2] == tunnel.address and ev[6] == "RC" then
      if ev[7] == "UPDATE" then return true end
      if ev[7] == "PING" then send("BOOTMSG", "waiting for a working robot program (press Update Robot)") end
    end
  end
  return false
end

while true do
  local st = fetch()
  say("program:", st)
  local code = readAll(PROG)
  if not code then
    send("ERR", "no robot program on the robot: " .. st)
    waitForUpdate(60)
  else
    local fn, lerr = load(code, "=robot.lua")
    if not fn then
      send("ERR", "robot.lua won't load: " .. tostring(lerr))
      waitForUpdate(60)
    else
      local ok, res = xpcall(fn, debug.traceback, { boot = BOOT_VERSION, sum = checksum(code) })
      if ok and res == "exit" then
        say("robot program exited")
        return
      elseif not ok then
        local msg = tostring(res)
        if msg:find("interrupted") then return end
        say("crashed:", msg)
        send("ERR", msg:sub(1, 3000))
        waitForUpdate(60)
      end
      -- ok and res == "update" (or anything else): loop and fetch again
    end
  end
end
