-- /bin/help.lua
local term = require("lib.term.console")
local vfs  = require("k.vfs")

term.writeln("OCOS commands (M1):")
term.writeln("  help             show this list")
term.writeln("  ls [path]        list directory")
term.writeln("  cat <path>       print file contents")
term.writeln("  echo <args...>   print arguments")
term.writeln("  pwd              print working directory")
term.writeln("  cd <path>        change directory")
term.writeln("  dmesg            show kernel log")
term.writeln("  ps               list processes")
term.writeln("  mounts           show mount table")
term.writeln("  clear            clear screen")
term.writeln("  reboot           reboot the computer")
term.writeln("  shutdown         power off")
term.writeln("  exit             leave the shell")
return 0
