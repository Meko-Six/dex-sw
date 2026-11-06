# Dex

Start with [HANDOFF.md](HANDOFF.md) for where things stand and the standing decisions.

## Node

Node comes from **fnm**, and the version is pinned in `.node-version` (24, the same as CI).
The line `eval "$(fnm env --use-on-cd --shell zsh)"` in `~/.zprofile` (login shells) and its
`/opt/homebrew/bin/fnm` form in `~/.zshenv` (non-login shells, which agents' commands run in) put it on every shell's PATH.

- If `node` isn't found or `node -v` isn't the pinned major, stop and tell the user.
  The fix is those lines, which are the user's to add; a session picks them up after the app restarts.
- Never install Node another way (Homebrew, nvm, the nodejs.org installer, `npx` shims),
  and don't work around a missing Node with per-command PATH hacks.
- To change the version, edit `.node-version` and run `fnm install`; CI reads the same file.
