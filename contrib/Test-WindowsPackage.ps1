[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Directory,
    [string]$Objdump = 'C:\msys64\mingw64\bin\objdump.exe'
)
$ErrorActionPreference = 'Stop'
$directoryPath = (Resolve-Path -LiteralPath $Directory).Path
$archives = @(Get-ChildItem -LiteralPath $directoryPath -File | Where-Object { $_.Extension -in '.exe', '.zip' })
if (-not ($archives | Where-Object Extension -eq '.exe') -or -not ($archives | Where-Object Extension -eq '.zip')) {
    throw 'Expected both an installer EXE and a portable ZIP'
}
foreach ($archive in $archives) {
    $expected = ((Get-Content -LiteralPath "$($archive.FullName).sha512") -split '\s+')[0]
    if ($expected -notmatch '^[a-fA-F0-9]{128}$' -or
        (Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA512).Hash -ne $expected) {
        throw "Invalid checksum: $($archive.Name)"
    }
}
$zip = $archives | Where-Object Extension -eq '.zip' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$testPath = Join-Path $directoryPath ('verify-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testPath | Out-Null
try {
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $testPath
    $gui = @(Get-ChildItem -LiteralPath $testPath -Recurse -File | Where-Object Name -eq 'openconnect-gui.exe')
    if ($gui.Count -ne 1) { throw 'Expected exactly one portable GUI executable' }
    $runtimeRoot = $gui[0].DirectoryName
    $binaries = @(Get-ChildItem -LiteralPath $runtimeRoot -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' })
    foreach ($binary in $binaries) {
        $imports = & $Objdump -p $binary.FullName
        if ($LASTEXITCODE -ne 0) { throw "Cannot inspect $($binary.Name)" }
        foreach ($line in $imports) {
            if ($line -notmatch 'DLL Name:\s+(\S+)') { continue }
            $dll = $Matches[1]
            if ($dll -match '^(api-ms-win-|ext-ms-win-)') { continue }
            if (-not ((Test-Path -LiteralPath (Join-Path $binary.DirectoryName $dll)) -or
                (Test-Path -LiteralPath (Join-Path $runtimeRoot $dll)) -or
                (Test-Path -LiteralPath (Join-Path "$env:WINDIR\System32" $dll)))) {
                throw "Missing DLL: $($binary.Name) -> $dll"
            }
        }
    }
    foreach ($exe in @('openconnect.exe', 'openconnect-gui.exe')) {
        $start = [System.Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $runtimeRoot $exe
        $start.Arguments = '--version'
        $start.WorkingDirectory = $runtimeRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['PATH'] = "$env:WINDIR\System32;$env:WINDIR"
        $start.EnvironmentVariables['__COMPAT_LAYER'] = 'RunAsInvoker'
        $start.EnvironmentVariables['QT_PLUGIN_PATH'] = Join-Path $runtimeRoot 'plugins'
        $start.EnvironmentVariables.Remove('QT_QPA_PLATFORM_PLUGIN_PATH')
        $start.EnvironmentVariables.Remove('QT_QPA_PLATFORM')
        $process = [System.Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) { $process.Kill(); throw "Startup timed out: $exe" }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
            throw "Startup failed: $exe; exit=$($process.ExitCode); $errorOutput"
        }
        Write-Output $output.Trim()
        $process.Dispose()
    }
    Write-Output "PASS: checksums, $($binaries.Count) PE imports, standalone GUI/core startup"
} finally {
    # Delete only the unique verification directory created inside the output folder.
    $resolvedTestPath = [System.IO.Path]::GetFullPath($testPath)
    if ($resolvedTestPath.StartsWith($directoryPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestPath) -like 'verify-*') {
        Remove-Item -LiteralPath $resolvedTestPath -Recurse -Force
    }
}
