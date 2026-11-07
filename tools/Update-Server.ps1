$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot

function Assert-ServerStopped {
    if (Get-Process -Name bedrock_server -ErrorAction SilentlyContinue) {
        throw 'Bedrock is running. Enter stop in its console, then run the updater again.'
    }
}

$stage = $null
$pending = $null
$backup = $null
$copyStarted = $false
try {
    $Host.UI.RawUI.WindowTitle = 'Lunos Toolbox | Server Update'
    Write-Host
    Write-Host '  ================================================' -ForegroundColor DarkGreen
    Write-Host '    LUNOS TOOLBOX  /  SERVER UPDATE' -ForegroundColor Green
    Write-Host '  ================================================' -ForegroundColor DarkGreen
    Write-Host
    Assert-ServerStopped

    Write-Host '  Opening the official Minecraft Bedrock server download page...' -ForegroundColor Cyan
    Start-Process 'https://www.minecraft.net/en-us/download/server/bedrock'
    if ((Read-Host '  Ready to select the downloaded Windows ZIP? [Y/N]') -notmatch '^(y|yes)$') {
        Write-Host '  Update canceled.' -ForegroundColor Yellow
        exit 0
    }

    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $picker.Title = 'Select the downloaded Windows Bedrock server ZIP'
        $picker.Filter = 'ZIP archives (*.zip)|*.zip'
        $picker.InitialDirectory = Join-Path $env:USERPROFILE 'Downloads'
        if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            Write-Host '  Update canceled.' -ForegroundColor Yellow
            exit 0
        }
        $package = $picker.FileName
    } finally {
        $picker.Dispose()
    }

    $stage = Join-Path ([IO.Path]::GetTempPath()) ('lunos-update-' + [Guid]::NewGuid().ToString())
    Write-Host '  [1/4] Extracting and checking the update...' -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $stage | Out-Null
    & tar.exe -xf $package -C $stage
    if ($LASTEXITCODE -ne 0) { throw 'Update ZIP extraction failed.' }
    $exe = 'bedrock_server.exe'
    $properties = 'server.properties'
    $currentExe = Join-Path $serverRoot $exe
    $currentProperties = Join-Path $serverRoot $properties
    $packageExe = Join-Path $stage $exe
    $packageProperties = Join-Path $stage $properties
    if (!(Test-Path -LiteralPath $packageExe -PathType Leaf) -or
        !(Test-Path -LiteralPath $packageProperties -PathType Leaf)) {
        throw 'Choose the Windows Bedrock Dedicated Server ZIP with bedrock_server.exe and server.properties at its root.'
    }
    $currentVersion = (Get-Item -LiteralPath $currentExe).VersionInfo.ProductVersion
    $newVersion = (Get-Item -LiteralPath $packageExe).VersionInfo.ProductVersion
    if ($currentVersion -notmatch '^\d+(\.\d+)+$' -or $newVersion -notmatch '^\d+(\.\d+)+$') {
        throw 'Could not read the Bedrock version from both server executables.'
    }

    $keyPattern = '^\s*([^#!\s=]+)\s*='
    $knownKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $existing = [IO.File]::ReadAllText($currentProperties)
    foreach ($line in ($existing -split '\r?\n')) {
        if ($line -match $keyPattern) { [void]$knownKeys.Add($Matches[1]) }
    }
    $added = foreach ($line in [IO.File]::ReadAllLines($packageProperties)) {
        if ($line -match $keyPattern -and $knownKeys.Add($Matches[1])) { $line }
    }
    $count = @($added).Count
    Write-Host "  Installed $currentVersion   Package $newVersion" -ForegroundColor White
    Write-Host "  New properties to add: $count" -ForegroundColor Gray
    Write-Host '  The worlds folder and existing property values will be kept.' -ForegroundColor Gray
    if ((Read-Host '  Back up and apply this package? [Y/N]') -notmatch '^(y|yes)$') {
        Write-Host '  Update canceled.' -ForegroundColor Yellow
        exit 0
    }

    Assert-ServerStopped
    Write-Host '  [2/4] Creating and verifying the full server backup...' -ForegroundColor Cyan
    . (Join-Path $PSScriptRoot 'Toolbox-Settings.ps1')
    $backupDir = (Get-ToolboxSettings).PrimaryBackup
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $backup = Join-Path $backupDir ('bedrock-server-{0}-{1}.zip' -f $currentVersion, (Get-Date -Format 'MM-dd-yyyy-HHmmss'))
    $pending = "$backup.$([Guid]::NewGuid()).partial"
    & tar.exe -cf $pending --format zip -C $serverRoot .
    if ($LASTEXITCODE -ne 0) { throw 'Full backup creation failed.' }
    & tar.exe -tf $pending | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Full backup verification failed.' }
    Assert-ServerStopped
    [IO.File]::Move($pending, $backup)
    Write-Host "  Backup saved to $backup" -ForegroundColor Gray

    Write-Host '  [3/4] Installing updated server files...' -ForegroundColor Cyan
    $copyStarted = $true
    & robocopy.exe $stage $serverRoot /E /IS /IT /R:0 /W:0 /NFL /NDL /NJH /NJS /NP /XD worlds LunosTools /XF server.properties allowlist.json whitelist.json permissions.json
    if ($LASTEXITCODE -ge 8) { throw "Server file copy failed (robocopy exit $LASTEXITCODE)." }

    Write-Host '  [4/4] Merging server.properties...' -ForegroundColor Cyan
    if ($count -gt 0) {
        $merged = $existing.TrimEnd([char[]]"`r`n") + "`r`n`r`n# Added by the Bedrock $newVersion update`r`n" +
            ($added -join "`r`n") + "`r`n"
        $mergedPath = Join-Path $stage 'merged-server.properties'
        [IO.File]::WriteAllText($mergedPath, $merged, [Text.UTF8Encoding]::new($false))
        # Replace requires both files to reside on the same volume.
        $pending = Join-Path $serverRoot ("server.properties.$([Guid]::NewGuid()).partial")
        Copy-Item -LiteralPath $mergedPath -Destination $pending
        [IO.File]::Replace($pending, $currentProperties, [NullString]::Value)
    }

    $installedVersion = (Get-Item -LiteralPath $currentExe).VersionInfo.ProductVersion
    if ($installedVersion -ne $newVersion) { throw 'The installed executable version did not match the package.' }
    Write-Host
    Write-Host "  Update complete. Bedrock $installedVersion is ready to start." -ForegroundColor Green
} catch {
    Write-Host
    Write-Host "  Update failed. $($_.Exception.Message)" -ForegroundColor Red
    if ($copyStarted) {
        Write-Host "  Server files may be partially updated. Restore from $backup before starting if needed." -ForegroundColor Yellow
    }
    exit 1
} finally {
    if ($pending -and (Test-Path -LiteralPath $pending)) {
        Remove-Item -LiteralPath $pending -ErrorAction SilentlyContinue
    }
    if ($stage -and (Test-Path -LiteralPath $stage)) {
        $resolved = (Resolve-Path -LiteralPath $stage).ProviderPath
        if ($resolved -eq $stage -and (Split-Path -Leaf $resolved) -match '^lunos-update-[0-9a-f-]+$' -and
            (Split-Path -Parent $resolved) -eq [IO.Path]::GetTempPath().TrimEnd('\')) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
