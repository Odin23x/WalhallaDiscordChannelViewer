# DiscordChannelViewer.ps1
# WalhallaDiscordChannelViewer - Touch Portal Plugin
# PowerShell 5.1 compatible
# NO ternary operator, NO inline if-expressions, NO PS7 syntax

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PluginId = "odin23x.walhalla_discord_channel_viewer"
$TPPort   = 12136
$ApiBase  = "https://discord.com/api/v10"

# --- State ID constants ---
$S_STATUS  = "$PluginId.state.status"
$S_CHANNEL = "$PluginId.state.my_channel"
$S_MEMBERS = "$PluginId.state.members"
$S_COUNT   = "$PluginId.state.member_count"
$S_LASTCHK = "$PluginId.state.last_check"
$S_LASTERR = "$PluginId.state.last_error"
$S_DEBUG   = "$PluginId.state.debug"

# --- Settings (populated by TP) ---
$Script:BotToken      = ""
$Script:GuildId       = ""
$Script:UserId        = ""
$Script:CheckInterval = 5

# --- Runtime flags ---
$Script:Running      = $true
$Script:ForceRefresh = $false

# --- User display name cache ---
$Script:UserCache = @{}

# --- TCP connection objects ---
$Script:Tcp    = $null
$Script:Stream = $null
$Script:Writer = $null
$Script:Reader = $null

# =============================================================
# Logging
# =============================================================

function Write-Log {
    param([string]$Msg)
    try {
        $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line = "[$ts] $Msg"
        Add-Content -Path "$PSScriptRoot\plugin.log" -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

# =============================================================
# Touch Portal connection
# =============================================================

function Connect-TP {
    try {
        $Script:Tcp    = New-Object System.Net.Sockets.TcpClient
        $Script:Tcp.Connect("127.0.0.1", $TPPort)
        $Script:Stream = $Script:Tcp.GetStream()

        $enc           = New-Object System.Text.UTF8Encoding($false)
        $Script:Writer = New-Object System.IO.StreamWriter($Script:Stream, $enc)
        $Script:Writer.AutoFlush = $true
        $Script:Reader = New-Object System.IO.StreamReader($Script:Stream, $enc)

        $pairMsg = '{"type":"pair","id":"' + $PluginId + '"}'
        $Script:Writer.WriteLine($pairMsg)
        Write-Log "Connected and paired with Touch Portal"
        return $true
    } catch {
        Write-Log "Connect-TP error: $($_.Exception.Message)"
        return $false
    }
}

function Disconnect-TP {
    try { if ($null -ne $Script:Reader) { $Script:Reader.Dispose() } } catch {}
    try { if ($null -ne $Script:Writer) { $Script:Writer.Dispose() } } catch {}
    try { if ($null -ne $Script:Stream) { $Script:Stream.Dispose() } } catch {}
    try { if ($null -ne $Script:Tcp)    { $Script:Tcp.Dispose()   } } catch {}
    $Script:Tcp    = $null
    $Script:Stream = $null
    $Script:Writer = $null
    $Script:Reader = $null
}

function Send-TPRaw {
    param([string]$Json)
    try {
        $Script:Writer.WriteLine($Json)
    } catch {
        Write-Log "Send-TPRaw error: $($_.Exception.Message)"
        $Script:Running = $false
    }
}

function Set-State {
    param([string]$Id, [string]$Val)
    # Use ConvertTo-Json for correct JSON string escaping
    $jsonVal = $Val | ConvertTo-Json
    $json = '{"type":"stateUpdate","id":"' + $Id + '","value":' + $jsonVal + '}'
    Send-TPRaw -Json $json
}

function Read-TPMessage {
    try {
        if ($null -eq $Script:Tcp -or -not $Script:Tcp.Connected) {
            $Script:Running = $false
            return $null
        }
        if ($Script:Stream.DataAvailable) {
            $line = $Script:Reader.ReadLine()
            if ($null -ne $line -and $line.Trim() -ne "") {
                try {
                    return ($line | ConvertFrom-Json)
                } catch {
                    Write-Log "JSON parse error: $($_.Exception.Message)"
                }
            }
        }
    } catch {
        Write-Log "Read-TPMessage error: $($_.Exception.Message)"
        $Script:Running = $false
    }
    return $null
}

# =============================================================
# Settings
# =============================================================

function Process-Settings {
    param([object[]]$Items)
    # Clear user cache when settings change
    $Script:UserCache = @{}
    foreach ($item in $Items) {
        switch ($item.name) {
            "Discord Bot Token" {
                $Script:BotToken = [string]$item.value
            }
            "Discord Guild ID" {
                $Script:GuildId = [string]$item.value
            }
            "Discord User ID" {
                $Script:UserId = [string]$item.value
            }
            "Check Interval Seconds" {
                $parsed = 5
                if ([int]::TryParse([string]$item.value, [ref]$parsed)) {
                    if ($parsed -lt 2) { $parsed = 2 }
                    $Script:CheckInterval = $parsed
                }
            }
        }
    }
    Write-Log "Settings applied - GuildId='$($Script:GuildId)' UserId='$($Script:UserId)' Interval=$($Script:CheckInterval)s"
}

# =============================================================
# Discord helpers
# =============================================================

function Get-DisplayName {
    param(
        [string]$UserId,
        $MemberObj,
        [hashtable]$Headers
    )

    # 1) Try the member object included in the voice state
    if ($null -ne $MemberObj) {
        if ($null -ne $MemberObj.nick -and $MemberObj.nick -ne "") {
            $Script:UserCache[$UserId] = $MemberObj.nick
            return $MemberObj.nick
        }
        if ($null -ne $MemberObj.user) {
            $name = ""
            if ($null -ne $MemberObj.user.global_name -and $MemberObj.user.global_name -ne "") {
                $name = $MemberObj.user.global_name
            } else {
                $name = $MemberObj.user.username
            }
            if ($name -ne "") {
                $Script:UserCache[$UserId] = $name
                return $name
            }
        }
    }

    # 2) Check session cache
    if ($Script:UserCache.ContainsKey($UserId)) {
        return $Script:UserCache[$UserId]
    }

    # 3) Fallback: query member endpoint individually
    try {
        $url    = "$ApiBase/guilds/$($Script:GuildId)/members/$UserId"
        $member = Invoke-RestMethod -Uri $url -Headers $Headers -Method Get -ErrorAction Stop
        $name   = $UserId
        if ($null -ne $member.nick -and $member.nick -ne "") {
            $name = $member.nick
        } elseif ($null -ne $member.user) {
            if ($null -ne $member.user.global_name -and $member.user.global_name -ne "") {
                $name = $member.user.global_name
            } else {
                $name = $member.user.username
            }
        }
        $Script:UserCache[$UserId] = $name
        return $name
    } catch {
        # Last resort: return the raw user ID
        return $UserId
    }
}

function Invoke-DiscordPoll {
    if ($Script:BotToken -eq "" -or $Script:GuildId -eq "" -or $Script:UserId -eq "") {
        Set-State -Id $S_STATUS -Val "Einstellungen fehlen"
        Write-Log "Poll skipped - settings incomplete"
        return
    }

    $headers = @{
        "Authorization" = "Bot $($Script:BotToken)"
        "Content-Type"  = "application/json"
    }

    try {
        $vsUrl = "$ApiBase/guilds/$($Script:GuildId)/voice-states"
        Set-State -Id $S_DEBUG -Val "GET $vsUrl"
        Write-Log "Polling: $vsUrl"

        $voiceStates = Invoke-RestMethod -Uri $vsUrl -Headers $headers -Method Get -ErrorAction Stop

        # Find my voice state channel
        $myChannelId = $null
        foreach ($vs in $voiceStates) {
            if ($vs.user_id -eq $Script:UserId) {
                $myChannelId = $vs.channel_id
                break
            }
        }

        if ($null -eq $myChannelId -or $myChannelId -eq "") {
            Set-State -Id $S_STATUS  -Val "Online"
            Set-State -Id $S_CHANNEL -Val "Nicht verbunden"
            Set-State -Id $S_MEMBERS -Val ""
            Set-State -Id $S_COUNT   -Val "0"
            Write-Log "User not in any voice channel"
        } else {
            # Resolve channel name
            $chUrl  = "$ApiBase/channels/$myChannelId"
            $chData = Invoke-RestMethod -Uri $chUrl -Headers $headers -Method Get -ErrorAction Stop
            $chName = $chData.name
            if ($null -eq $chName -or $chName -eq "") { $chName = $myChannelId }

            # Collect all members in same channel
            $names = @()
            foreach ($vs in $voiceStates) {
                if ($vs.channel_id -eq $myChannelId) {
                    $dn = Get-DisplayName -UserId $vs.user_id -MemberObj $vs.member -Headers $headers
                    $names += $dn
                }
            }

            $memberStr = $names -join ", "
            $cntStr    = [string]$names.Count

            Set-State -Id $S_STATUS  -Val "Online"
            Set-State -Id $S_CHANNEL -Val $chName
            Set-State -Id $S_MEMBERS -Val $memberStr
            Set-State -Id $S_COUNT   -Val $cntStr
            Write-Log "Channel: $chName | Members ($($names.Count)): $memberStr"
        }

        Set-State -Id $S_LASTCHK -Val (Get-Date -Format "HH:mm:ss")
        Set-State -Id $S_LASTERR -Val ""

    } catch {
        $err = $_.Exception.Message
        Set-State -Id $S_STATUS  -Val "API Fehler"
        Set-State -Id $S_LASTERR -Val $err
        Set-State -Id $S_LASTCHK -Val (Get-Date -Format "HH:mm:ss")
        Write-Log "Poll error: $err"
    }
}

# =============================================================
# Main
# =============================================================

Write-Log "=== WalhallaDiscordChannelViewer starting ==="

if (-not (Connect-TP)) {
    Write-Log "Failed to connect to Touch Portal. Exiting."
    exit 1
}

Set-State -Id $S_STATUS -Val "Verbunden - warte auf Einstellungen"

$lastPoll = [DateTime]::MinValue

while ($Script:Running) {

    # Drain all pending TP messages
    $msg = Read-TPMessage
    while ($null -ne $msg) {
        $t = $msg.type

        if ($t -eq "info") {
            if ($null -ne $msg.settings) {
                Process-Settings -Items $msg.settings
            }
            Write-Log "TP info received"
        } elseif ($t -eq "settings") {
            if ($null -ne $msg.values) {
                Process-Settings -Items $msg.values
            }
            Write-Log "TP settings update received"
        } elseif ($t -eq "action") {
            $aid = $msg.actionId
            if ($aid -eq "$PluginId.action.refresh") {
                $Script:ForceRefresh = $true
                Write-Log "Force refresh requested via action"
            }
        } elseif ($t -eq "closePlugin") {
            Write-Log "closePlugin received"
            $Script:Running = $false
        }

        $msg = Read-TPMessage
    }

    # Poll Discord if interval elapsed or force refresh requested
    $elapsed = ([DateTime]::Now - $lastPoll).TotalSeconds
    if ($Script:ForceRefresh -or ($elapsed -ge [double]$Script:CheckInterval)) {
        $Script:ForceRefresh = $false
        Invoke-DiscordPoll
        $lastPoll = [DateTime]::Now
    }

    Start-Sleep -Milliseconds 200
}

Write-Log "=== Plugin stopping ==="
Disconnect-TP
exit 0
