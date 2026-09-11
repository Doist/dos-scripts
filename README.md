# TodoistOS installer scripts

These public entry scripts install the prerequisites needed to access the
private `Doist/todoist-os` repository, clone or update the workspace, and run
its `scripts/setup.sh` or `scripts/setup.ps1` setup script.

The installer repository keeps its name, `Doist/dos-scripts`, so the existing
installation URLs stay valid.

## Install

macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/Doist/dos-scripts/refs/heads/main/install/bootstrap-mac.sh | bash
```

Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/Doist/dos-scripts/refs/heads/main/install/bootstrap-linux.sh | bash
```

The Linux entry script installs prerequisites, but full setup also depends on
Linux support in the workspace's own setup script.

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/Doist/dos-scripts/refs/heads/main/install/bootstrap-windows.ps1 | iex
```

## Existing installations

Fresh installs clone **`Doist/todoist-os`** into `~/todoist-os`.
Existing checkouts stay in place. The installer checks the old and new names
under both the home directory and `Documents`. It reuses a single checkout; if
it finds more than one, it stops and asks you to select one.

To choose a custom location, set `TODOIST_OS_DIR` before running the installation
command:

```sh
export TODOIST_OS_DIR="$HOME/code/doist/todoist-os"
```

```powershell
$env:TODOIST_OS_DIR = Join-Path $HOME 'code/doist/todoist-os'
```

The old `DOIST_OS_DIR` variable remains supported. A nonempty `TODOIST_OS_DIR`
takes precedence. Custom locations outside the default folders need an explicit
variable; the installer does not search the rest of your disk.

Before updating an existing checkout, the installer checks that its origin is
`Doist/doist-os` or `Doist/todoist-os` on GitHub, that it is on `main`, and that its
working tree is clean. Commit or stash local changes and switch to `main` before
rerunning setup. Forks and unrelated repositories are not updated automatically.

Existing origin URLs are retained. GitHub redirects the old upstream after the
rename, and the workspace's sync migration handles updating that URL. Settings
migration also belongs to the workspace; this installer does not move personal
settings or rename checkout folders.

## Release dependency

These scripts deliberately target `Doist/todoist-os` even while preparing the
rename locally. Publish them after that GitHub repository name exists. Fresh
clones will fail before then; there is no fallback to cloning the old name.
The archived `Doist/doist-os-cx` repository is not part of this release.

## Tests

Tests use temporary repositories and record clone/pull commands without running
them. They do not install packages, authenticate, or contact GitHub.

```sh
python3 -m unittest discover -s tests -v
```

```powershell
pwsh -NoProfile -File tests/bootstrap-windows.tests.ps1
```
