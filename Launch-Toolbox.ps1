param(
    [ValidateSet('Start', 'Backup', 'Update')]
    [string]$Tool = 'Start'
)

$ErrorActionPreference = 'Stop'
$launchers = [ordered]@{
    Start  = @{ File = 'Start Bedrock Server.cmd'; Label = 'Start Server'; Icon = 'Lunos-Start-Dirt.ico' }
    Backup = @{ File = 'Back Up Minecraft World.cmd'; Label = 'World Backup'; Icon = 'Lunos-Backup.ico' }
    Update = @{ File = 'BedrockServerUpdater.cmd'; Label = 'Server Update'; Icon = 'Lunos-Update.ico' }
}

function Select-ToolboxFolder([string]$Prompt, [switch]$AllowNewFolder) {
    Write-Host "  $Prompt"
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = $Prompt
        $dialog.ShowNewFolderButton = $AllowNewFolder.IsPresent
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
    } finally {
        $dialog.Dispose()
    }
}

function Install-Toolbox([string]$Server, [string]$Primary, [string]$Secondary, [string]$Desktop) {
    if (!(Test-Path -LiteralPath (Join-Path $Server 'bedrock_server.exe') -PathType Leaf)) {
        throw 'Select the folder containing bedrock_server.exe.'
    }
    $serverPrefix = $Server.TrimEnd('\') + '\'
    foreach ($folder in @($Primary, $Secondary) | Where-Object { $_ }) {
        if ($folder.TrimEnd('\').Equals($Server.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
            $folder.StartsWith($serverPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Choose backup folders outside the server folder so full backups cannot include themselves.'
        }
    }
    if ($Secondary -and $Secondary.TrimEnd('\') -eq $Primary.TrimEnd('\')) {
        throw 'Choose different primary and secondary backup folders.'
    }

    $installed = Join-Path $Server 'LunosTools'
    foreach ($folder in @($installed, (Join-Path $installed 'GlobalServerStats'), $Primary, $Secondary) | Where-Object { $_ }) {
        [void][IO.Directory]::CreateDirectory($folder)
    }
    $source = Join-Path $PSScriptRoot 'tools'
    Get-ChildItem -LiteralPath $source | Copy-Item -Destination $installed -Recurse -Force
    @{ PrimaryBackup = $Primary; SecondaryBackup = $Secondary } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installed 'Toolbox.settings.json') -Encoding UTF8

    $shell = New-Object -ComObject WScript.Shell
    foreach ($toolInfo in $launchers.Values) {
        $name = "Lunos Toolbox - $($toolInfo.Label).lnk"
        foreach ($location in $Desktop, $installed) {
            $link = $shell.CreateShortcut((Join-Path $location $name))
            $link.TargetPath = Join-Path $installed $toolInfo.File
            $link.WorkingDirectory = $installed
            $link.IconLocation = "$(Join-Path $installed ('icons\' + $toolInfo.Icon)),0"
            $link.Description = "Lunos Toolbox | $($toolInfo.Label)"
            $link.Save()
        }
    }
    return $installed
}

try {
    $Host.UI.RawUI.WindowTitle = 'Lunos Toolbox'
    $pointer = Join-Path $PSScriptRoot 'Toolbox.install.json'
    $installed = $null
    if (Test-Path -LiteralPath $pointer) {
        $previous = Get-Content -LiteralPath $pointer -Raw | ConvertFrom-Json
        if ($previous.ToolboxFolder -and
            (Test-Path -LiteralPath (Join-Path $previous.ToolboxFolder 'Toolbox.settings.json')) -and
            (Test-Path -LiteralPath (Join-Path $previous.ToolboxFolder $launchers[$Tool].File))) {
            $installed = $previous.ToolboxFolder
        }
    }

    if (!$installed) {
        Write-Host '  LUNOS TOOLBOX  /  FIRST-RUN SETUP' -ForegroundColor Green
        Add-Type -AssemblyName System.Windows.Forms
        $server = Select-ToolboxFolder 'Select the folder containing bedrock_server.exe.'
        if (!$server) { exit 0 }
        if (!(Test-Path -LiteralPath (Join-Path $server 'bedrock_server.exe') -PathType Leaf)) {
            throw 'The selected folder does not contain bedrock_server.exe.'
        }
        $primary = Select-ToolboxFolder 'Select or create your primary backup folder.' -AllowNewFolder
        if (!$primary) { exit 0 }
        $secondary = Select-ToolboxFolder 'Select or create your secondary backup folder. Cancel to skip it.' -AllowNewFolder
        $desktop = [Environment]::GetFolderPath('Desktop')
        $installed = Install-Toolbox $server $primary $secondary $desktop
        @{ ToolboxFolder = $installed } | ConvertTo-Json | Set-Content -LiteralPath $pointer -Encoding UTF8
        Write-Host '  Setup complete. Your shortcuts are on the Desktop.' -ForegroundColor Green
    }

    & (Join-Path $installed $launchers[$Tool].File)
    exit $LASTEXITCODE
} catch {
    Write-Host "  Toolbox setup failed. $($_.Exception.Message)" -ForegroundColor Red
    [void](Read-Host '  Press Enter to close')
    exit 1
}
