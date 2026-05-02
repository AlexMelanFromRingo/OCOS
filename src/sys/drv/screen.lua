-- /sys/drv/screen.lua — screen-side helpers.
-- Currently delegates to drv.gpu; kept as a separate module so M3's compositor
-- can grow here without touching the GPU driver.

local M = {}
local gpu = require("drv.gpu")

function M.init() end                            -- nothing to do in M1

function M.size() return gpu.size() end
function M.clear() gpu.clear() end

return M
