# One-command Windows packages

Run from a checkout in Windows PowerShell:

```powershell
.\build.ps1
```

The default mode builds on GitHub Actions and downloads the installer EXE,
portable ZIP, SHA512 checksums and build information into `build-output/windows-<run-id>`.
It does not install MSYS2, Qt or a C++ compiler on your computer. If necessary,
the script installs only GitHub CLI through winget and opens GitHub sign-in once.
You need Actions access to the repository and an internet connection.

If GitHub refuses to start its runner because the account is billing-locked,
the command falls back to an already installed local Qt/MinGW environment,
without installing missing packages. If no such environment is present, it
reports the GitHub billing restriction and does not install a local SDK.

## Upgrades

Push the upgraded source to GitHub, then run the command. Each branch push
automatically produces Windows packages. The command reuses a successful build
of that exact remote commit, or waits for an existing build, instead of compiling
it again. Local uncommitted edits are not uploaded or included automatically.

To choose a different branch or repository:

```powershell
.\build.ps1 -Ref develop -Repository vegaskyo/openconnect-gui
```

To try a new OpenConnect version without changing the pinned default:

```powershell
.\build.ps1 -OpenConnectVersion v9.22
```

The example tag must exist upstream. To make an upgrade permanent, change
`contrib/openconnect-version.txt` and push it. This is the shared default used
by CMake and both legacy MSYS2 build scripts.

GitHub requires the workflow file on the default branch to accept manual
`workflow_dispatch` requests. Until this change is merged into `develop`, use
the automatic branch-push build, or download a specific run:

```powershell
.\build.ps1 -RunId 123456789
```

Runs are visible under Actions → Windows packages. Build artifacts expire after
14 days. If an old artifact has expired, the command automatically reruns the
same commit and downloads the new result. Builds are not automatically published as releases.

## Why later builds are faster

- MSYS2 package downloads are cached on the runner.
- Verified OpenConnect runtime/development ZIPs are reused. The cache key covers
  the requested tag, core build recipe, package list and installed MinGW packages.
- ccache reuses compiler outputs across GUI builds, including external CMake projects.
- A new version/toolchain invalidates the relevant dependency cache automatically.
- Reusing packages from an already completed build avoids compiling altogether.

The first build and dependency upgrades take longer. No fixed build time is
guaranteed; GitHub queue time, downloads and cache availability affect it.

Each build validates checksums, statically imported DLLs and GUI/core startup
from the extracted ZIP with a Windows-only PATH. This is a packaging smoke test,
not a real VPN connection test. The generated binaries are unsigned.

## Local mode

If MSYS2 is already installed, use it without configuring commands by hand:

```powershell
.\build.ps1 -Local
.\build.ps1 -Local -OpenConnectVersion v9.22
```

Local mode automatically installs missing packages into that MSYS2 installation,
uses incremental builds and creates both packages in `build-output/windows`.
It never installs MSYS2 itself. For an installation outside `C:\msys64`, pass
`-Msys2Root C:\path\to\msys64`. `-Jobs 4` is the default parallelism limit;
`-Local -RebuildCore` forces rebuilding the core instead of using its ZIP cache.

Existing verified legacy core ZIPs are accepted once and their current build
fingerprint is recorded. Use `-RebuildCore` if their origin/toolchain is unknown.
