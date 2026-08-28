# Pipx Packages

The pipx packages dialog lets you install Python applications into isolated environments using `pipx`. This is useful for tools that aren't available as system packages.

## Configuration file

Packages are defined in `lib/configs/pipx-packages.conf`.

## Package format

Each line follows the format:

```
group|package|spec|default|venv|description
```

- **group** — category label (e.g. `Gaming`)
- **package** — logical package name (for display)
- **spec** — passed directly to `pipx install` or `pipx inject` (e.g. `git+https://...` or a PyPI package name)
- **default** — `TRUE` or `FALSE`
- **venv** — virtual environment name (groups packages into the same venv)
- **description** — shown in the selection dialog

## How venv grouping works

- The **first** package in a venv group runs `pipx install` (creates the venv)
- **Subsequent** packages in the same venv run `pipx inject` (adds to the existing venv)

This lets you bundle dependencies into a single isolated environment.

## Current packages

| Group | Package | Venv | Description |
|---|---|---|---|
| Gaming | `linuxgamebench` | `linuxgamebench` | Linux game benchmarking tool |
| Gaming | `PySide6` | `linuxgamebench` | Qt for Python GUI (injected into linuxgamebench) |

## Adding a package

Add a line to `lib/configs/pipx-packages.conf`:

```
# Standalone package (creates its own venv):
MyGroup|mytool|git+https://github.com/user/mytool|TRUE|mytool|Description

# Dependency injected into an existing venv:
MyGroup|mydep|mydep-package|TRUE|mytool|Description of dependency
```

The `spec` field is passed directly to `pipx install` or `pipx inject`, so it supports:

- PyPI package names: `my-package`
- Version specifiers: `my-package>=1.0`
- Git URLs: `git+https://github.com/user/repo`
- Git URLs with tags: `git+https://github.com/user/repo@v1.0`

## Requirements

- `python-pipx` must be selected in the hardware packages dialog (it's in the Valve manifest under `Dev`)
- `qt6-base` is needed for Qt-based Python applications (also in the Valve manifest)

## Use via CLI

```bash
./steamos-build.sh --action build \
    --image ... \
    --pipx-items "linuxgamebench PySide6"
```
