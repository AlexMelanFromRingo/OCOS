-- /bin/repl — interactive Lua REPL.
-- Each line is first compiled as a return-expression (so `1+2` prints `3`).
-- If that fails, the line is re-compiled as a statement. Multi-line input
-- is supported via a continuation prompt: when the parser raises "<eof>"
-- we keep reading until the chunk parses or the user blanks.

return require("lib.devtools.repl").loop()
