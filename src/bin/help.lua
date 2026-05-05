-- /bin/help.lua — print a short reference of available commands.
local sections = {
  { "Built-ins (run inside the shell)",
    { "cd <path>", "pwd", "exit [code]", "set [k=v]", "unset <k>",
      "alias [k=v]", "unalias <k>", "echo <args>", "true", "false", "exec <cmd>" }
  },
  { "Filesystem",
    { "ls [path]", "cat [file...]", "head -n <n> [file]", "tail -n <n> [file]",
      "grep <pattern> [file...]", "wc [file...]", "find <path>", "mounts" }
  },
  { "System",
    { "ps", "dmesg", "uname [-a]", "uptime", "free", "clear",
      "reboot", "shutdown", "sleep <sec>" }
  },
  { "Services",
    { "svc list", "svc status <id>", "svc start <id>", "svc stop <id>" }
  },
  { "Users / security",
    { "whoami", "login", "useradd <name>", "userdel <name>",
      "passwd [user]", "sudo <cmd>" }
  },
  { "Packages",
    { "pkg list", "pkg info <id>", "pkg install [-f] <dir|id>",
      "pkg uninstall <id>", "pkg verify <id>" }
  },
  { "Developer",
    { "repl", "profile <script>" }
  },
  { "Pipes / redirects",
    { "cmd1 | cmd2", "cmd > file", "cmd >> file", "cmd < file", "cmd 2> file",
      "cmd1 && cmd2", "cmd1 || cmd2", "cmd1 ; cmd2" }
  },
}
for _, s in ipairs(sections) do
  print(s[1])
  for _, c in ipairs(s[2]) do print("  " .. c) end
  print("")
end
return 0
