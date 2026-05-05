-- /bin/whoami.lua — print the current user.
local _, env = ...
print(env.USER or "?")
return 0
