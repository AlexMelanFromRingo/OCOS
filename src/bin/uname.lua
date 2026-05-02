-- /bin/uname.lua — print OCOS identification.
local args = ...
local long = false
for _, a in ipairs(args) do if a == "-a" then long = true end end
if long then
  print(string.format("OCOS %s OpenComputers Lua %s", _OSVERSION or "?", _VERSION))
else
  print("OCOS")
end
return 0
