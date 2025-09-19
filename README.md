# nanojoule

Nanojoule (cli `nj`) is a command line utility to read junit XML files and yield the position in the test failed, in vimgrep format.

## Status

Beta - usable, with some quirks.

Known "issues" are:
- paths are clunky because they depend on cwd;
- hardcoded to handle kotlin tests only for the moment;
- performance might be suboptimal due to excessive scanning in the file

## Usage

In you neovim, run `:set makeprg=nj` and after running your tests run `:make` to populate the quickfix list.

Nanojoule will yield a list that points to all the tests that failed, with the message of the failure.


