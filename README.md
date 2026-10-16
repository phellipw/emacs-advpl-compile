# emacs-advpl-compile

An Emacs Lisp package for compiling AdvPL/TLPP sources using the TOTVS
`advpls cli` executable. It provides asynchronous compilation, navigable
source diagnostics, project/profile selection, a masked preview, and safe
handling of temporary authentication scripts. It does **not** contain server
settings, credentials, source code from customer projects, or example
configurations from real environments.

## Requirements

- Emacs 30.1 or later (validated locally on Emacs 31.1).
- `advpls` from TDS-LS in PATH or in a Neovim Mason installation; otherwise
  set `advpl-compile-command` to a list containing your executable path.
- An existing major mode for your AdvPL/TLPP files, or enable the included
  minor mode manually. This package does not replace a syntax-highlighting mode.

## Install and activate

Clone the repository locally, add its directory to `load-path` and load the
package in your Emacs configuration:

```elisp
(add-to-list 'load-path (expand-file-name "~/path/to/emacs-advpl-compile"))
(require 'advpl-compile)
(add-hook 'advpl-mode-hook #'advpl-compile-mode)
```

Use the name of your existing AdvPL major mode's hook, or run
`M-x advpl-compile-mode` in a source buffer. A Doom-specific, opt-in installer
for a pre-existing `advpl-mode` is maintained separately in the dotfiles
integration; this public package has no dependency on Doom.

| In an enabled buffer | Action |
|---|---|
| `C-c a f` | Compile current saved source |
| `C-c a p` | Compile source roots in the project |
| `C-c a g` | Compile modified/staged/untracked Git sources |
| `C-c a r` | Repeat the previous compile |
| `C-c a s` | Show settings without credential values |
| `C-c a l` | Reopen sanitized compilation output |
| `C-c a x` | Cancel and remove the temporary script |
| `C-c a u` | Select a session-only profile |

Prefix a compile command with `C-u` to preview a **redacted** build script
without starting the CLI. File, project, Git changes and repeat can also be
invoked with `M-x advpl-compile-file`, `M-x advpl-compile-project`,
`M-x advpl-compile-changed`, and `M-x advpl-compile-repeat`.

## Configuration

The package reads project `.advpl-build.json` and ignored
`.advpl-build.local.json` files, profile `build.json`/`local.json` under
`$XDG_CONFIG_HOME/advpl/`, and include paths from `.advpl-lsp.json`. The
Neovim profile recorded at `$XDG_STATE_HOME/nvim/advpl/profile.json` is
recognized when available. Set `useProjectOverrides` in project config if
project settings should override the selected profile; process environment
variables such as `ADVPL_SERVER`, `ADVPL_PORT`, `ADVPL_ENVIRONMENT`,
`ADVPL_USER` and `ADVPL_PASSWORD` take precedence. Keep all credentials out of
tracked project files and Emacs config.

The CLI receives only an INI path as an argument. The INI is encoded as CP1252
by default, created with mode 0600, and removed on success, failure or
cancellation. Its contents and raw process output are never printed to the
Emacs command line or compilation buffer; output is sanitized before display.
After an abnormal editor or OS termination, remove any stale private
`advpl-compile-*.ini` from the system temp directory without printing it.

**A real compile sends sources to the selected AppServer/RPO.** Verify the
target environment and include directories with `advpl-compile-status` and a
masked preview before invoking a real compile. A successful RPO commit requires
both `All files compiled successfully` and `Recompile finished` in CLI output;
exit code zero alone is not sufficient. Empty sources are excluded to avoid
aborting an entire batch.

## Development (offline)

```sh
make check
```

`make check` runs a strict byte-compile and the ERT suite with synthetic
projects and a fake `advpls` executable. It does not contact an AppServer.
