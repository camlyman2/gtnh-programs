-- /etc/rc.d/robotctl.lua  -  starts the robot's bootloader (/home/boot.lua)
-- in the background whenever OpenOS boots. Switch it on once with:
--     rc robotctl enable
local thread = require("thread")
local t

function start()
  if t and t:status() ~= "dead" then return end
  t = thread.create(function()
    local ok, err = pcall(dofile, "/home/boot.lua")
    if not ok then io.stderr:write("robotctl: " .. tostring(err) .. "\n") end
  end)
  t:detach()
end

function stop()
  if t then t:kill(); t = nil end
end
