-- /sys/lib/ui/init.lua — convenience re-exports.
return {
  buffer     = require("lib.ui.buffer"),
  compositor = require("lib.ui.compositor"),
  event      = require("lib.ui.event"),
  layout     = require("lib.ui.layout"),
  theme      = require("lib.ui.theme"),
  widget     = require("lib.ui.widget"),
  widgets = {
    label    = require("lib.ui.widgets.label"),
    button   = require("lib.ui.widgets.button"),
    input    = require("lib.ui.widgets.input"),
    list     = require("lib.ui.widgets.list"),
    checkbox = require("lib.ui.widgets.checkbox"),
    window   = require("lib.ui.widgets.window"),
    menu     = require("lib.ui.widgets.menu"),
  },
}
