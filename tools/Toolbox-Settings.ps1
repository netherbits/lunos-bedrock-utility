function Get-ToolboxSettings {
    $file = Join-Path $PSScriptRoot 'Toolbox.settings.json'
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) {
        throw 'Toolbox setup is incomplete. Open a launcher in the extracted GitHub package to configure it.'
    }
    $settings = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if (!$settings.PrimaryBackup) { throw 'No primary backup folder is configured.' }
    return $settings
}
