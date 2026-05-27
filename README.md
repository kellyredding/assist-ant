# AssistAnt

Personal assistant macOS app with a companion CLI.

- `tools/assist-ant/` — Crystal CLI (`assist-ant` binary)
- `AssistAntApp/` — Swift macOS app

CLI and app communicate over a Unix domain socket at
`~/.assist-ant/runtime/assist-ant.sock`. User data lives in
`~/.assist-ant/data/`.

Implementation plans live in
`~/projects/implementation-plans/<year>/`.

## Quick start

```bash
make cli-install      # build + install ~/.local/bin/assist-ant
make app-build        # build the macOS app
```
