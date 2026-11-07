$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot

try {
    . (Join-Path $PSScriptRoot 'Toolbox-Settings.ps1')
    $settings = Get-ToolboxSettings
    $destination = $settings.PrimaryBackup
    $external = $settings.SecondaryBackup
    $steps = if ($external) { 3 } else { 2 }
    $Host.UI.RawUI.WindowTitle = 'Lunos Toolbox | World Backup'
    $divider = '  ' + ('=' * 48)
    Write-Host
    Write-Host $divider -ForegroundColor DarkGreen
    Write-Host '    LUNOS TOOLBOX' -ForegroundColor Green
    Write-Host '    World Backup' -ForegroundColor White
    Write-Host $divider -ForegroundColor DarkGreen
    Write-Host
    Write-Host "  Source       $(Join-Path $serverRoot 'worlds')" -ForegroundColor Gray
    Write-Host "  Primary      $destination" -ForegroundColor Gray
    if ($external) { Write-Host "  Secondary    $external" -ForegroundColor Gray }
    Write-Host
    $answer = Read-Host '  Create a backup now? [Y/N]'
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host '  Backup canceled.' -ForegroundColor Yellow
        exit
    }

    if (Get-Process -Name bedrock_server -ErrorAction SilentlyContinue) {
        throw 'Bedrock is running. Enter stop in its console, then run this backup again.'
    }

    $worlds = Join-Path $serverRoot 'worlds'
    if (-not (Test-Path -LiteralPath $worlds -PathType Container)) {
        throw "Worlds folder not found at $worlds"
    }

    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $name = 'myworld-{0}.zip' -f (Get-Date -Format 'MM-dd-yyyy-HHmmss')
    $archive = Join-Path $destination $name
    if (Test-Path -LiteralPath $archive) {
        throw 'A backup already exists for this second. Please try again.'
    }
    $pending = Join-Path $destination ('.' + [Guid]::NewGuid().ToString() + '.partial')

    try {
        Write-Host "  [1/$steps] Compressing world files..." -ForegroundColor Cyan
        & tar.exe -cf $pending --format zip -C $serverRoot worlds
        if ($LASTEXITCODE -ne 0) { throw 'ZIP creation failed.' }

        Write-Host "  [2/$steps] Checking the ZIP archive..." -ForegroundColor Cyan
        & tar.exe -tf $pending | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'ZIP verification failed.' }
        if (Get-Process -Name bedrock_server -ErrorAction SilentlyContinue) {
            throw 'Bedrock started during the backup. Stop it and try again.'
        }

        [IO.File]::Move($pending, $archive)
        if (!$external) {
            Write-Host '  Backup complete' -ForegroundColor Green
            Write-Host "  $archive" -ForegroundColor Gray
            exit 0
        }
        Write-Host '  [3/3] Copying to the secondary backup folder...' -ForegroundColor Cyan
        $externalArchive = Join-Path $external $name
        $externalPending = Join-Path $external (Split-Path -Leaf $pending)

        try {
            if (-not (Test-Path -LiteralPath $external -PathType Container)) {
                throw "Backup folder unavailable at $external"
            }

            Copy-Item -LiteralPath $archive -Destination $externalPending
            if ((Get-FileHash -LiteralPath $archive).Hash -ne (Get-FileHash -LiteralPath $externalPending).Hash) {
                throw 'The external copy did not match the primary ZIP.'
            }

            [IO.File]::Move($externalPending, $externalArchive)
            Write-Host
            Write-Host '  Backup complete in both locations' -ForegroundColor Green
            Write-Host "  $archive" -ForegroundColor Gray
            Write-Host "  $externalArchive" -ForegroundColor Gray
        } catch {
            Write-Host
            Write-Host '  Primary backup saved. Secondary backup failed.' -ForegroundColor Yellow
            Write-Host "  $archive" -ForegroundColor Gray
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
            exit 1
        } finally {
            if (Test-Path -LiteralPath $externalPending) {
                Remove-Item -LiteralPath $externalPending -ErrorAction SilentlyContinue
            }
        }
    } finally {
        if (Test-Path -LiteralPath $pending) {
            Remove-Item -LiteralPath $pending
        }
    }
} catch {
    Write-Host
    Write-Host '  Backup failed' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
    exit 1
}



