-- probe.lua - find component addresses and see what your machines expose
--
--   probe                -> lists every gt_machine and ME component
--   probe <address>      -> lists all methods + live data for that component
--                           (partial addresses work, e.g. "probe 3fa2")

local component = require("component")
local args = { ... }

local function try(proxy, method, ...)
  local fn = proxy[method]
  if not fn then return "(method not available)" end
  local ok, res = pcall(fn, ...)
  if not ok then return "(error: " .. tostring(res) .. ")" end
  return res
end

if not args[1] then
  print("== GregTech machines ==")
  for addr in component.list("gt_machine") do
    local p = component.proxy(addr)
    print(addr, tostring(try(p, "getName")))
  end
  print("== AE2 components ==")
  for addr, t in component.list("me_") do
    print(addr, t)
  end
  print("== Redstone ==")
  for addr in component.list("redstone") do print(addr) end
  print("")
  print("Run 'probe <address>' on your tree farm to see everything it exposes.")
  return
end

local addr = component.get(args[1])
if not addr then
  print("No component matches '" .. args[1] .. "'")
  return
end

print("Component: " .. addr .. " (" .. component.type(addr) .. ")")
print("-- methods --")
local names = {}
for name in pairs(component.methods(addr)) do names[#names + 1] = name end
table.sort(names)
print(table.concat(names, ", "))

local p = component.proxy(addr)
if p.getSensorInformation then
  print("-- sensor information --")
  local info = try(p, "getSensorInformation")
  if type(info) == "table" then
    for i = 1, #info do print((tostring(info[i]):gsub("\194\167.", ""))) end
  else
    print(tostring(info))
  end
  print("-- live values --")
  for _, m in ipairs({ "getName", "isMachineActive", "isWorkAllowed", "getWorkProgress",
                       "getWorkMaxProgress", "getAverageElectricInput", "getStoredEU" }) do
    print(m, tostring(try(p, m)))
  end
end
