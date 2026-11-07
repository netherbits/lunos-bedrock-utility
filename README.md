# Lunos Toolbox for Bedrock Dedicated Server

Windows launch, backup, update, and playtime tools for an existing Minecraft Bedrock Dedicated Server.

## Get started

1. On GitHub, select **Code → Download ZIP**.
2. Extract the ZIP to your Desktop.
3. Open the extracted folder and double-click **Start Server.cmd**. On first run, choose the folder containing `bedrock_server.exe`, your primary backup folder, and your secondary backup folder. Cancel the secondary picker if you only want one backup location.

Setup creates **Lunos Toolbox - Start Server**, **Lunos Toolbox - World Backup**, and **Lunos Toolbox - Server Update** shortcuts on your Desktop. It installs the scripts, icons, settings, and copies of the shortcuts in `LunosTools` inside the selected server folder. Choose backup locations outside the server folder.

## Tools

- **Start Server** opens Bedrock and a Live Stats Dashboard. The dashboard shows uptime, connected players, session and global playtime, and the latest backup at each configured destination. It stays open with a session summary after Bedrock stops. All-time totals and last-seen times are saved at shutdown to `LunosTools\GlobalServerStats\Playtime.txt`.
- **World Backup** asks for confirmation and checks that Bedrock is stopped. It creates a timestamped ZIP of `worlds` in the primary folder. If a secondary folder is configured, it copies the ZIP there and checks that the files match.
- **Server Update** opens Minecraft's download page and asks you to select the Windows server ZIP. After confirmation, it creates a versioned full backup in the primary folder, copies the update files, and adds new `server.properties` keys while keeping existing values. It preserves worlds, Toolbox files, allowlists, and player permissions.

## Move or reconfigure

To change destinations or select a different server, delete `Toolbox.install.json` from the extracted package, then open one of its launchers again. On a new PC, run setup again to recreate the Desktop shortcuts with the new paths. Keep `LunosTools\GlobalServerStats` with your server if you want to carry forward the playtime totals.

The package uses Windows PowerShell, the Windows console host, `tar.exe`, and `robocopy.exe`. Minecraft server binaries and world files are supplied separately.
