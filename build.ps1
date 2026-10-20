[CmdletBinding()]
param(
    [switch]$Local,
    [ValidatePattern('^(v[0-9]+\.[0-9]+(\.[0-9]+)?|master)$')][string]$OpenConnectVersion,
    [string]$Repository,
    [string]$Ref,
    [long]$RunId,
    [ValidateRange(1,64)][int]$Jobs = 4,
    [string]$Msys2Root = 'C:\msys64',
    [switch]$RebuildCore,
    [switch]$UseInstalledToolsOnly
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location -LiteralPath $root
if ($RunId -and $OpenConnectVersion) { throw 'Use either -RunId or -OpenConnectVersion, not both.' }

if ($Local) {
    $bash = Join-Path $Msys2Root 'usr\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash)) {
        throw 'MSYS2 was not found. Run .\build.ps1 without -Local to build on GitHub without installing a toolchain.'
    }
    $names = @('MSYSTEM','CHERE_INVOKING','OCG_SOURCE_DIR','OC_TAG','BUILD_JOBS','REBUILD_CORE','OCG_PACKAGES_READY')
    $savedEnvironment = @{}
    foreach ($name in $names) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $env:MSYSTEM = 'MINGW64'
        $env:CHERE_INVOKING = '1'
        $env:OCG_SOURCE_DIR = $root
        $env:OC_TAG = $OpenConnectVersion
        $env:BUILD_JOBS = "$Jobs"
        $env:REBUILD_CORE = if ($RebuildCore) { '1' } else { '0' }
        $env:OCG_PACKAGES_READY = if ($UseInstalledToolsOnly) { '1' } else { $null }
        & $bash -lc 'cd "$(cygpath -u "$OCG_SOURCE_DIR")" && bash contrib/package-windows.sh'
        if ($LASTEXITCODE -ne 0) { throw 'Local Windows build failed; see build-output/logs.' }
        & (Join-Path $root 'contrib\Test-WindowsPackage.ps1') -Directory (Join-Path $root 'build-output\windows') -Objdump (Join-Path $Msys2Root 'mingw64\bin\objdump.exe')
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    }
    return
}
if ($RebuildCore) { throw '-RebuildCore is a local build option; use it with -Local.' }

$ghCommand = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCommand) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'Install GitHub CLI from https://cli.github.com, then run this command again. No C++ toolchain is needed.'
    }
    Write-Host 'Installing the lightweight GitHub CLI; the compiler and Qt stay on GitHub.'
    & winget install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) { throw 'Could not install GitHub CLI.' }
    $ghCommand = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $ghCommand) {
        $ghPath = Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'
        if (-not (Test-Path -LiteralPath $ghPath)) { throw 'Open a new PowerShell window and run .\build.ps1 again.' }
        $ghCommand = Get-Item -LiteralPath $ghPath
    }
}
$gh = if ($ghCommand.Source) { $ghCommand.Source } else { $ghCommand.FullName }
function Invoke-GitHub {
    param([string[]]$Arguments)
    $output = & $gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "GitHub command failed: gh $($Arguments -join ' ')" }
    return $output
}
& $gh api user --jq .login *> $null
if ($LASTEXITCODE -ne 0) {
    & $gh auth login --hostname github.com --web --git-protocol ssh
    if ($LASTEXITCODE -ne 0) { throw 'GitHub sign-in was not completed.' }
}
if (-not $Repository) {
    $remote = & git config --get remote.github.url
    if (-not $remote) { $remote = & git config --get remote.origin.url }
    if ($remote -match 'github\.com(?::443)?[:/]([^/]+)/([^/]+?)(?:\.git)?$') {
        $Repository = "$($Matches[1])/$($Matches[2])"
    } else { throw 'Specify -Repository owner/repo for the GitHub repository.' }
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid GitHub repository name.' }
if (-not $Ref) {
    $Ref = & git branch --show-current
    if (-not $Ref) {
        $Ref = Invoke-GitHub -Arguments @('repo','view',$Repository,'--json','defaultBranchRef','--jq','.defaultBranchRef.name')
    }
}
if (-not $RunId) {
    $encodedRef = [uri]::EscapeDataString($Ref)
    $commit = Invoke-GitHub -Arguments @('api',"repos/$Repository/commits/$encodedRef",'--jq','.sha')
    Write-Host "Remote build: $Repository @ $Ref ($commit)"
    if (& git status --porcelain) { Write-Warning 'Local uncommitted edits are not part of a remote build. Use -Local to build them.' }
    # A push already builds this exact commit. Reuse its successful artifact, or wait
    # for its existing run, instead of compiling the same source again.
    if (-not $OpenConnectVersion) {
        $runs = Invoke-GitHub -Arguments @('run','list','--repo',$Repository,'--workflow','windows.yml','--branch',$Ref,'--limit','30','--json','databaseId,headSha,event,status,conclusion') | ConvertFrom-Json
        $existing = $runs | Where-Object { $_.headSha -eq $commit -and $_.event -eq 'push' } | Select-Object -First 1
        if ($existing) {
            $RunId = $existing.databaseId
        }
    }
    if (-not $RunId) {
        $requestId = [guid]::NewGuid().ToString('N')
        $dispatch = @('workflow','run','windows.yml','--repo',$Repository,'--ref',$Ref,'-f',"request-id=$requestId")
        if ($OpenConnectVersion) { $dispatch += @('-f',"openconnect-version=$OpenConnectVersion") }
        Invoke-GitHub -Arguments $dispatch | Out-Host
        $deadline = (Get-Date).AddSeconds(90)
        do {
            Start-Sleep -Seconds 3
            $runs = Invoke-GitHub -Arguments @('run','list','--repo',$Repository,'--workflow','windows.yml','--branch',$Ref,'--event','workflow_dispatch','--limit','30','--json','databaseId,displayTitle') | ConvertFrom-Json
            $run = $runs | Where-Object displayTitle -eq "Windows package $requestId" | Select-Object -First 1
            if ($run) { $RunId = $run.databaseId }
        } while (-not $RunId -and (Get-Date) -lt $deadline)
        if (-not $RunId) { throw 'GitHub did not register the build request within 90 seconds.' }
    }
}
Write-Host "Build run: https://github.com/$Repository/actions/runs/$RunId"
$runState = Invoke-GitHub -Arguments @('api',"repos/$Repository/actions/runs/$RunId") | ConvertFrom-Json
if ($runState.status -eq 'completed') {
    # A billing-locked account cannot start a runner. Reuse a complete local SDK
    # when it is already present, without installing missing packages implicitly.
    $blockedByBilling = $false
    if ($runState.conclusion -eq 'failure') {
        $jobsState = Invoke-GitHub -Arguments @('api',"repos/$Repository/actions/runs/$RunId/jobs") | ConvertFrom-Json
        foreach ($job in $jobsState.jobs) {
            if (@($job.steps).Count -ne 0) { continue }
            $annotations = Invoke-GitHub -Arguments @('api',"repos/$Repository/check-runs/$($job.id)/annotations") | ConvertFrom-Json
            if ($annotations | Where-Object message -Match '(?i)locked.*billing|billing.*locked') { $blockedByBilling = $true }
        }
    }
    if ($blockedByBilling) {
        $required = @('usr\bin\bash.exe','mingw64\bin\cmake.exe','mingw64\bin\c++.exe','mingw64\bin\Qt6Core.dll','mingw64\bin\Qt6StateMachine.dll')
        $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Msys2Root $_)) })
        if ($missing.Count -eq 0) {
            $localHead = & git rev-parse HEAD
            if ($localHead -ne $runState.head_sha -or (& git status --porcelain)) {
                throw 'GitHub is billing-locked and the requested commit differs from the clean local checkout. Commit/push your edits, or explicitly use -Local to build the current working tree.'
            }
            Write-Warning 'GitHub blocked its runner due to account billing. Using the existing local toolchain; no packages will be installed.'
            $localArguments = @{Local=$true; UseInstalledToolsOnly=$true; Msys2Root=$Msys2Root; Jobs=$Jobs}
            if ($OpenConnectVersion) { $localArguments.OpenConnectVersion = $OpenConnectVersion }
            & $PSCommandPath @localArguments
            return
        }
        throw 'GitHub blocked this build due to account billing. Resolve https://github.com/settings/billing before using cloud builds. No local toolchain was installed.'
    }
    $artifactState = Invoke-GitHub -Arguments @('api',"repos/$Repository/actions/runs/$RunId/artifacts") | ConvertFrom-Json
    $available = $artifactState.artifacts | Where-Object { $_.name -eq 'windows-package' -and -not $_.expired }
    if ($runState.conclusion -ne 'success' -or -not $available) {
        Write-Host 'The previous build failed or its download expired; rebuilding the same commit.'
        Invoke-GitHub -Arguments @('run','rerun',"$RunId",'--repo',$Repository) | Out-Host
        $deadline = (Get-Date).AddSeconds(90)
        do {
            Start-Sleep -Seconds 3
            $attempt = Invoke-GitHub -Arguments @('api',"repos/$Repository/actions/runs/$RunId",'--jq','.run_attempt')
        } while ([int]$attempt -le [int]$runState.run_attempt -and (Get-Date) -lt $deadline)
        if ([int]$attempt -le [int]$runState.run_attempt) { throw 'GitHub did not register the rerun within 90 seconds.' }
    }
}
& $gh run watch "$RunId" --repo $Repository --exit-status
if ($LASTEXITCODE -ne 0) { throw 'Remote build failed. Open the run URL above for its logs.' }
$destination = Join-Path $root "build-output\windows-$RunId"
if (Test-Path -LiteralPath $destination) {
    $destination += '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
}
Invoke-GitHub -Arguments @('run','download',"$RunId",'--repo',$Repository,'--name','windows-package','--dir',$destination) | Out-Host
$assets = @(Get-ChildItem -LiteralPath $destination -File | Where-Object { $_.Extension -in '.exe','.zip' })
if (-not ($assets | Where-Object Extension -eq '.exe') -or -not ($assets | Where-Object Extension -eq '.zip')) {
    throw 'Downloaded artifact is missing the EXE or portable ZIP.'
}
foreach ($asset in $assets) {
    $expected = ((Get-Content -LiteralPath "$($asset.FullName).sha512") -split '\s+')[0]
    if ($expected -notmatch '^[a-fA-F0-9]{128}$' -or
        (Get-FileHash -LiteralPath $asset.FullName -Algorithm SHA512).Hash -ne $expected) { throw "Checksum mismatch: $($asset.Name)" }
}
Write-Host "Verified EXE + portable ZIP: $destination"
