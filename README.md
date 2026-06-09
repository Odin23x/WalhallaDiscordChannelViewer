# WalhallaDiscordChannelViewer

Touch Portal Plugin - Discord Voice Channel Tracker

## Description

Shows in Touch Portal which Discord voice channel you are currently in and who else is in it.
Polls the Discord Bot REST API at a configurable interval.

Part of the **Walhalla Plugin Series** by [Odin23x](https://github.com/Odin23x).

## Requirements

- Touch Portal (latest)
- PowerShell 5.1
- A Discord Bot Token with the bot added to your server

## Installation

1. Download `WalhallaDiscordChannelViewer.tpp`
2. In Touch Portal: **Settings > Import Plugin** and select the `.tpp` file
3. Configure the plugin settings (see below)

## Plugin Settings

| Setting | Description | Default |
|---|---|---|
| Discord Bot Token | Your bot token from the Discord Developer Portal | *(empty)* |
| Discord Guild ID | The server/guild ID (right-click server > Copy Server ID) | *(empty)* |
| Discord User ID | Your own Discord user ID (right-click your name > Copy User ID) | *(empty)* |
| Check Interval Seconds | How often to poll the API (min: 2) | `5` |

## States

| State ID | Description |
|---|---|
| `state.status` | Current status (Online / API Fehler / etc.) |
| `state.my_channel` | Voice channel name you are in, or "Nicht verbunden" |
| `state.members` | Comma-separated list of all members in your channel |
| `state.member_count` | Number of members in your channel |
| `state.last_check` | Timestamp of the last successful poll |
| `state.last_error` | Last error message (empty if no error) |
| `state.debug` | Last API URL polled (debug info) |

## Actions

| Action | Description |
|---|---|
| Jetzt aktualisieren | Force an immediate refresh |

## Discord Bot Setup

1. Go to https://discord.com/developers/applications
2. Create a new application and add a Bot
3. Copy the Bot Token into the plugin settings
4. Under **Bot > Privileged Gateway Intents**, enable:
   - **Server Members Intent**
   - **Presence Intent** *(optional but recommended)*
5. Invite the bot to your server with `bot` scope and `View Channels` permission
6. Enable **Developer Mode** in Discord (Settings > Advanced) to copy IDs

## API Used

- `GET https://discord.com/api/v10/guilds/{guild_id}/voice-states`
- `GET https://discord.com/api/v10/channels/{channel_id}`
- `GET https://discord.com/api/v10/guilds/{guild_id}/members/{user_id}` *(fallback)*

## Notes

- The plugin writes a `plugin.log` file next to the `.ps1` for debugging
- User display names are cached for the session to reduce API calls
- Uses PowerShell 5.1 - no PS7 syntax used
