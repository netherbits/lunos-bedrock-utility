$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot

function Get-BedrockVersion([string]$Path) {
    $versionInfo = (Get-Item -LiteralPath $Path).VersionInfo
    foreach ($label in $versionInfo.ProductVersion, $versionInfo.FileVersion) {
        if ($label -match '^\s*v?(?<version>\d+(?:\s*[.,]\s*\d+){1,3})(?=\s|[-+]|$)') {
            $version = $Matches.version -replace '\s*[.,]\s*', '.'
            if ($version -match '[1-9]') { return $version }
        }
    }
    return 'unknown'
}

function Assert-WindowsExecutable([string]$Path) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        if ($reader.BaseStream.Length -ge 64 -and $reader.ReadUInt16() -eq 0x5A4D) {
            $reader.BaseStream.Position = 60
            $headerOffset = $reader.ReadUInt32()
            if ($headerOffset -ge 64 -and $headerOffset -le ($reader.BaseStream.Length - 4)) {
                $reader.BaseStream.Position = $headerOffset
                if ($reader.ReadUInt32() -eq 0x00004550) { return }
            }
        }
        throw 'The package bedrock_server.exe is not a Windows executable.'
    } finally {
        $reader.Dispose()
    }
}

function Assert-ServerStopped {
    if (Get-Process -Name bedrock_server -ErrorAction SilentlyContinue) {
        throw 'Bedrock is running. Enter stop in its console, then run the updater again.'
    }
}

function Read-PlayerList([string]$Path) {
    $json = [IO.File]::ReadAllText($Path)
    if (!$json.TrimStart().StartsWith('[')) {
        throw "$(Split-Path -Leaf $Path) must contain a JSON array."
    }
    foreach ($entry in (ConvertFrom-Json -InputObject $json)) { $entry }
}

function Get-PlayerKeys($Entry, [string]$ListName) {
    if ($Entry -isnot [pscustomobject]) { throw "$ListName contains a non-object entry." }
    if ($Entry.xuid) { "xuid:$($Entry.xuid)" }
    if ($ListName -eq 'allowlist.json' -and $Entry.name) { "name:$($Entry.name)" }
}

function Get-MergedPlayerList([string]$InstalledPath, [string]$PackagePath) {
    if (!(Test-Path -LiteralPath $PackagePath -PathType Leaf)) { return }

    $incoming = @(Read-PlayerList $PackagePath)
    $exists = Test-Path -LiteralPath $InstalledPath -PathType Leaf
    if ($exists -and $incoming.Count -eq 0) { return }

    $name = Split-Path -Leaf $PackagePath
    $existing = @()
    $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($exists) {
        $existing = @(Read-PlayerList $InstalledPath)
        foreach ($entry in $existing) {
            foreach ($key in Get-PlayerKeys $entry $name) { [void]$known.Add($key) }
        }
    }
    $added = @(foreach ($entry in $incoming) {
        $keys = @(Get-PlayerKeys $entry $name)
        if ($keys.Count -eq 0) { throw "An entry in the package's $name has no player identifier." }
        if ($keys | Where-Object { $known.Contains($_) }) { continue }
        foreach ($key in $keys) { [void]$known.Add($key) }
        $entry
    })
    if (!$exists -or $added.Count -gt 0) {
        ConvertTo-Json -InputObject ($existing + $added) -Depth 100
    }
}

function Write-UpdatedConfig([string]$Path, [string]$Content) {
    $temporary = "$Path.$([Guid]::NewGuid()).partial"
    try {
        [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporary, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue }
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
    Assert-WindowsExecutable $packageExe
    $currentVersion = Get-BedrockVersion $currentExe
    $newVersion = Get-BedrockVersion $packageExe
    if ($newVersion -eq 'unknown' -and
        (Split-Path -Leaf $package) -match '^bedrock-server-(?<version>\d+(?:\.\d+){1,3})(?:\s*\(\d+\))?\.zip$') {
        $newVersion = $Matches.version
    }
    $packageHash = (Get-FileHash -LiteralPath $packageExe -Algorithm SHA256).Hash

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
    $packFolders = @(
        'behavior_packs'
        'development_behavior_packs'
        'development_resource_packs'
        'development_skin_packs'
        'resource_packs'
    )
    $mergedLists = @{}
    foreach ($name in 'allowlist.json', 'permissions.json') {
        $content = Get-MergedPlayerList (Join-Path $serverRoot $name) (Join-Path $stage $name)
        if ($null -ne $content) { $mergedLists[$name] = $content }
    }
    Write-Host "  Installed $currentVersion   Package $newVersion" -ForegroundColor White
    Write-Host "  New properties to add: $count" -ForegroundColor Gray
    Write-Host '  Worlds, existing pack files, settings, and player entries will be kept.' -ForegroundColor Gray
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
    $copyOptions = @('/E', '/R:0', '/W:0', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/XJ')
    $excludedFolders = @('worlds', 'LunosTools') + $packFolders
    & robocopy.exe $stage $serverRoot @copyOptions /IS /IT /XD @excludedFolders /XF server.properties allowlist.json whitelist.json permissions.json
    if ($LASTEXITCODE -ge 8) { throw "Server file copy failed (robocopy exit $LASTEXITCODE)." }

    Write-Host '  [4/4] Adding missing pack files and merging settings and player lists...' -ForegroundColor Cyan
    foreach ($name in $packFolders) {
        $source = Join-Path $stage $name
        if (!(Test-Path -LiteralPath $source -PathType Container)) { continue }
        # Exclude existing files regardless of size or timestamp.
        & robocopy.exe $source (Join-Path $serverRoot $name) @copyOptions /XC /XN /XO
        if ($LASTEXITCODE -ge 8) { throw "Pack merge failed for $name (robocopy exit $LASTEXITCODE)." }
    }
    foreach ($name in $mergedLists.Keys) {
        Write-UpdatedConfig (Join-Path $serverRoot $name) $mergedLists[$name]
    }
    if ($count -gt 0) {
        $merged = $existing.TrimEnd([char[]]"`r`n") + "`r`n`r`n# Added by the Bedrock $newVersion update`r`n" +
            ($added -join "`r`n") + "`r`n"
        Write-UpdatedConfig $currentProperties $merged
    }

    if ((Get-FileHash -LiteralPath $currentExe -Algorithm SHA256).Hash -ne $packageHash) {
        throw 'The installed executable did not match the package.'
    }
    $installedLabel = if ($newVersion -eq 'unknown') { 'Bedrock' } else { "Bedrock $newVersion" }
    Write-Host
    Write-Host "  Update complete. $installedLabel is ready to start." -ForegroundColor Green
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
