-- /sys/drv/kbd.lua — keyboard event normaliser.
-- Translates raw key_down/key_up signals into IPC events with named fields.

local M = {}

local ipc = require("k.ipc")
local log = require("k.log")

local modifiers                                  -- {ctrl=, shift=, alt=, super=}
local known_kbd                                  -- set of attached keyboards

-- LWJGL key codes we care about for modifier tracking. Map covers the most
-- common variants; missing keys just don't update modifier state.
local MOD_KEYS = {
  [29]  = "ctrl",   [157] = "ctrl",
  [42]  = "shift",  [54]  = "shift",
  [56]  = "alt",    [184] = "alt",
  [219] = "super",  [220] = "super",
}

local function update_mods(code, down)
  local m = MOD_KEYS[code]
  if m then modifiers[m] = down or nil end
end

function M.init()
  modifiers = {}
  known_kbd = {}

  ipc.subscribe("oc.signal.component_added", function(p)
    local addr, ctype = p[1], p[2]
    if ctype == "keyboard" then known_kbd[addr] = true end
  end)
  ipc.subscribe("oc.signal.component_removed", function(p)
    local addr = p[1]
    if known_kbd[addr] then
      known_kbd[addr] = nil
      log.info("kbd", "keyboard removed: " .. addr:sub(1, 8))
    end
  end)

  ipc.subscribe("oc.signal.key_down", function(p)
    -- p comes from signal.publish via dispatch_event: it's {1=addr, 2=char, 3=code, 4=player, n=4}
    local addr, char, code, player = p[1], p[2], p[3], p[4]
    update_mods(code, true)
    ipc.publish("kbd.key", {
      down = true, char = char, code = code, player = player, addr = addr,
      mods = { ctrl = modifiers.ctrl, shift = modifiers.shift, alt = modifiers.alt, super = modifiers.super },
    })
  end)
  ipc.subscribe("oc.signal.key_up", function(p)
    local addr, char, code, player = p[1], p[2], p[3], p[4]
    update_mods(code, false)
    ipc.publish("kbd.key", {
      down = false, char = char, code = code, player = player, addr = addr,
      mods = { ctrl = modifiers.ctrl, shift = modifiers.shift, alt = modifiers.alt, super = modifiers.super },
    })
  end)
  ipc.subscribe("oc.signal.clipboard", function(p)
    ipc.publish("kbd.paste", { addr = p[1], value = p[2], player = p[3] })
  end)
end

function M.modifiers() return modifiers end

return M
