-- /bin/help.lua — short reference of available commands.
-- By default paginates if the output would not fit on one screen.
-- Pass --plain (or -p) to disable pagination, e.g. `help --plain | grep ls`.

local args, _ = ...
local pager = require("lib.devtools.pager")

local plain = false
local filter
for i = 1, #args do
  local a = args[i]
  if a == "--plain" or a == "-p" then plain = true
  elseif a:sub(1, 1) ~= "-" then filter = a end
end

local sections = {
  { "Built-ins (run inside the shell)",
    { "cd <path>", "pwd", "exit [code]", "set [k=v]", "unset <k>",
      "alias [k=v]", "unalias <k>", "echo <args>", "true", "false", "exec <cmd>" }
  },
  { "Filesystem",
    { "ls [path]", "cat [file...]", "head -n <n> [file]", "tail -n <n> [file]",
      "grep <pattern> [file...]", "wc [file...]", "find <path>", "mounts",
      "mkdir [-p] <path>", "rm [-rf] <path>", "cp [-r] <src...> <dst>",
      "mv <src...> <dst>", "touch <path...>", "ln -s <target> <link>" }
  },
  { "System",
    { "ps", "kill [-9] <pid>", "dmesg", "uname [-a]", "uptime", "free", "clear",
      "reboot", "shutdown", "sleep <sec>" }
  },
  { "Services",
    { "svc list", "svc status <id>", "svc start <id>", "svc stop <id>" }
  },
  { "Users / security",
    { "whoami", "login", "setup-root", "useradd [--admin] <name>",
      "userdel [-r] <name>", "usermod {--admin|--no-admin} <name>",
      "passwd [user]", "sudo <cmd>" }
  },
  { "Packages",
    { "pkg list", "pkg info <id>", "pkg install [-f] <dir|id>",
      "pkg uninstall <id>", "pkg verify <id>",
      "pkg registry list", "pkg registry add <name> <url>",
      "pkg registry remove <name>" }
  },
  { "Network",
    { "wget [-q] [-O <file>] <url>",
      "curl [-X method] [-H 'K: V'] [-d body] [-o file] [-L] <url>",
      "git clone [-b <branch>] <github-url> [<dest>]" }
  },
  { "Documentation",
    { "help [--plain]", "man <name>", "less [file]", "more [file]" }
  },
  { "Developer",
    { "repl", "lua [file [args]]", "profile <script>" }
  },
  { "Pipes / redirects",
    { "cmd1 | cmd2", "cmd > file", "cmd >> file", "cmd < file", "cmd 2> file",
      "cmd1 && cmd2", "cmd1 || cmd2", "cmd1 ; cmd2" }
  },
}

local lines = {}
for _, s in ipairs(sections) do
  if not filter or s[1]:lower():find(filter:lower(), 1, true) then
    lines[#lines + 1] = s[1]
    for _, c in ipairs(s[2]) do lines[#lines + 1] = "  " .. c end
    lines[#lines + 1] = ""
  end
end
local text = table.concat(lines, "\n")

if plain then
  io.write(text)
  return 0
end
return pager.show(text, { title = "OCOS help", io = io })
