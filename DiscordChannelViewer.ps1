# DiscordChannelViewer.ps1 - v2 (Discord RPC)
# WalhallaDiscordChannelViewer - Touch Portal Plugin
# PowerShell 5.1 compatible - NO PS7 syntax, NO ternary
# Uses Discord local RPC pipe - no bot needs to be in any server

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$PluginId  = "odin23x.walhalla_discord_channel_viewer"
$TPPort    = 12136
$PluginDir = Join-Path $env:APPDATA "TouchPortal\plugins\WalhallaDiscordChannelViewer"

$Script:LogFile   = Join-Path $PluginDir "plugin.log"
$Script:TokenFile = Join-Path $PluginDir "rpc_token.json"

# State IDs
$S_STATUS  = "$PluginId.state.status"
$S_CHANNEL = "$PluginId.state.my_channel"
$S_MEMBERS = "$PluginId.state.members"
$S_COUNT   = "$PluginId.state.member_count"
$S_LASTCHK = "$PluginId.state.last_check"
$S_LASTERR = "$PluginId.state.last_error"
$S_DEBUG   = "$PluginId.state.debug"

# Settings
$Script:ClientId      = "1513616012593991731"
$Script:ClientSecret  = ""
$Script:CheckInterval = 5

# Runtime
$Script:Running      = $true
$Script:ForceRefresh = $false
$Script:AccessToken  = ""
$Script:RefreshToken = ""
$Script:RPCReady     = $false

# TP TCP objects
$Script:Tcp    = $null
$Script:Stream = $null
$Script:Writer = $null
$Script:Reader = $null

# Discord RPC named pipe
$Script:Pipe = $null

# RPC opcodes
$OP_HANDSHAKE = 0
$OP_FRAME     = 1
$OP_CLOSE     = 2

# =============================================================
# Logging
# =============================================================
function Write-Log {
    param([string]$Msg)
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Msg"
    try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 } catch {
        try {
            $desk = [Environment]::GetFolderPath("Desktop")
            Add-Content -Path (Join-Path $desk "WalhallaDiscordViewer_LOG.txt") -Value $line -Encoding UTF8
        } catch {}
    }
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
        $Script:Writer.WriteLine('{"type":"pair","id":"' + $PluginId + '"}')
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
    $Script:Tcp = $null; $Script:Stream = $null; $Script:Writer = $null; $Script:Reader = $null
}

function Send-TPRaw {
    param([string]$Json)
    try { $Script:Writer.WriteLine($Json) }
    catch { Write-Log "Send-TPRaw: $($_.Exception.Message)"; $Script:Running = $false }
}

function Set-State {
    param([string]$Id, [string]$Val)
    $jv = $Val | ConvertTo-Json
    Send-TPRaw -Json ('{"type":"stateUpdate","id":"' + $Id + '","value":' + $jv + '}')
}

function Read-TPMessage {
    try {
        if ($null -eq $Script:Tcp -or -not $Script:Tcp.Connected) { $Script:Running = $false; return $null }
        if ($Script:Stream.DataAvailable) {
            $line = $Script:Reader.ReadLine()
            if ($null -ne $line -and $line.Trim() -ne "") {
                try { return ($line | ConvertFrom-Json) } catch { Write-Log "TP JSON: $($_.Exception.Message)" }
            }
        }
    } catch { Write-Log "Read-TPMessage: $($_.Exception.Message)"; $Script:Running = $false }
    return $null
}

# =============================================================
# Settings
# =============================================================
function Apply-OneSetting {
    param([string]$Name, [string]$Value)
    switch ($Name) {
        "Application ID"         { $Script:ClientId      = $Value }
        "Client Secret"          { $Script:ClientSecret  = $Value }
        "Check Interval Seconds" {
            $p = 5
            if ([int]::TryParse($Value, [ref]$p)) {
                if ($p -lt 2) { $p = 2 }
                $Script:CheckInterval = $p
            }
        }
    }
}

function Process-Settings {
    param($Items)
    try {
        $masked = ($Items | ConvertTo-Json -Compress -Depth 5) -replace '"Client Secret":"[^"]*"', '"Client Secret":"<masked>"'
        Write-Log "Settings: $masked"
    } catch {}
    if ($null -eq $Items) { return }
    foreach ($item in $Items) {
        if ($null -eq $item) { continue }
        $item.PSObject.Properties | ForEach-Object {
            Apply-OneSetting -Name $_.Name -Value ([string]$_.Value)
        }
    }
    Write-Log "Settings applied - ClientId=$($Script:ClientId) SecretSet=$($Script:ClientSecret -ne '')"
}

# =============================================================
# Discord RPC pipe helpers
# =============================================================
function Read-PipeBytes {
    param([byte[]]$Buffer, [int]$Offset, [int]$Count, [int]$TimeoutMs)
    try {
        $ar = $Script:Pipe.BeginRead($Buffer, $Offset, $Count, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($ok) {
            return $Script:Pipe.EndRead($ar)
        } else {
            Write-Log "Pipe read timeout ($TimeoutMs ms)"
            try { $Script:Pipe.Dispose() } catch {}
            $Script:Pipe = $null
            return -1
        }
    } catch {
        Write-Log "Read-PipeBytes: $($_.Exception.Message)"
        try { $Script:Pipe.Dispose() } catch {}
        $Script:Pipe = $null
        return -1
    }
}

function Send-RPCFrame {
    param([int]$Opcode, [string]$Json)
    try {
        $payload = [System.Text.Encoding]::UTF8.GetBytes($Json)
        $header  = [byte[]]::new(8)
        [System.BitConverter]::GetBytes([int32]$Opcode).CopyTo($header, 0)
        [System.BitConverter]::GetBytes([int32]$payload.Length).CopyTo($header, 4)
        $Script:Pipe.Write($header, 0, 8)
        $Script:Pipe.Write($payload, 0, $payload.Length)
        $Script:Pipe.Flush()
        return $true
    } catch {
        Write-Log "Send-RPCFrame: $($_.Exception.Message)"
        try { $Script:Pipe.Dispose() } catch {}
        $Script:Pipe = $null
        return $false
    }
}

function Read-RPCFrame {
    param([int]$TimeoutMs = 5000)
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)

    # Read 8-byte header
    $header = [byte[]]::new(8)
    $got    = 0
    while ($got -lt 8) {
        $remain = [int]($deadline - [DateTime]::Now).TotalMilliseconds
        if ($remain -le 0) { Write-Log "RPC header timeout"; return $null }
        $n = Read-PipeBytes -Buffer $header -Offset $got -Count (8 - $got) -TimeoutMs $remain
        if ($n -le 0) { return $null }
        $got += $n
    }

    $opcode = [System.BitConverter]::ToInt32($header, 0)
    $len    = [System.BitConverter]::ToInt32($header, 4)

    if ($len -lt 0 -or $len -gt 1048576) { Write-Log "Bad RPC frame length: $len"; return $null }

    # Read payload
    $payload = [byte[]]::new($len)
    $got     = 0
    while ($got -lt $len) {
        $remain = [int]($deadline - [DateTime]::Now).TotalMilliseconds
        if ($remain -le 0) { Write-Log "RPC payload timeout"; return $null }
        $n = Read-PipeBytes -Buffer $payload -Offset $got -Count ($len - $got) -TimeoutMs $remain
        if ($n -le 0) { break }
        $got += $n
    }

    $json = [System.Text.Encoding]::UTF8.GetString($payload, 0, $got)
    try {
        $parsed = $json | ConvertFrom-Json
        return @{ Opcode = $opcode; Data = $parsed }
    } catch {
        Write-Log "RPC frame JSON error: $($_.Exception.Message)"
        return $null
    }
}

# =============================================================
# Discord RPC protocol
# =============================================================
function Connect-DiscordRPC {
    $Script:RPCReady = $false
    for ($i = 0; $i -le 9; $i++) {
        try {
            $p = New-Object System.IO.Pipes.NamedPipeClientStream(
                ".", "discord-ipc-$i",
                [System.IO.Pipes.PipeDirection]::InOut,
                [System.IO.Pipes.PipeOptions]::None)
            $p.Connect(1000)
            $Script:Pipe = $p
            Write-Log "Connected to discord-ipc-$i"
            return $true
        } catch {}
    }
    Write-Log "No discord-ipc pipe found - is Discord Desktop running?"
    return $false
}

function Invoke-Handshake {
    $hs = '{"v":1,"client_id":"' + $Script:ClientId + '"}'
    if (-not (Send-RPCFrame -Opcode $OP_HANDSHAKE -Json $hs)) { return $false }
    $resp = Read-RPCFrame -TimeoutMs 5000
    if ($null -ne $resp -and $resp.Data.evt -eq "READY") {
        Write-Log "RPC READY - Discord user: $($resp.Data.data.user.username)"
        return $true
    }
    if ($null -ne $resp) { Write-Log "Handshake unexpected: $($resp.Data | ConvertTo-Json -Compress)" }
    return $false
}

function Get-StoredToken {
    if (-not (Test-Path $Script:TokenFile)) { return $null }
    try {
        $data = Get-Content $Script:TokenFile -Raw | ConvertFrom-Json
        if ($null -eq $data -or $null -eq $data.access_token -or $data.access_token -eq "") { return $null }
        if ($null -ne $data.expires_at) {
            $exp = [DateTime]::Parse($data.expires_at)
            if ([DateTime]::UtcNow -gt $exp.AddMinutes(-5)) {
                Write-Log "Token expired, refreshing..."
                return Invoke-TokenRefresh -Refresh $data.refresh_token
            }
        }
        return $data
    } catch {
        Write-Log "Get-StoredToken: $($_.Exception.Message)"
        return $null
    }
}

function Save-Token {
    param([string]$Access, [string]$Refresh, [int]$ExpiresIn)
    $exp  = [DateTime]::UtcNow.AddSeconds($ExpiresIn).ToString("o")
    $data = @{ access_token = $Access; refresh_token = $Refresh; expires_at = $exp }
    $data | ConvertTo-Json | Set-Content -Path $Script:TokenFile -Encoding UTF8
    Write-Log "Token saved (expires in ${ExpiresIn}s)"
}

function Invoke-TokenRefresh {
    param([string]$Refresh)
    if ($Script:ClientSecret -eq "") { Write-Log "No client secret for refresh"; return $null }
    try {
        $cid  = [Uri]::EscapeDataString($Script:ClientId)
        $cs   = [Uri]::EscapeDataString($Script:ClientSecret)
        $rt   = [Uri]::EscapeDataString($Refresh)
        $body = "client_id=$cid&client_secret=$cs&grant_type=refresh_token&refresh_token=$rt"
        $resp = Invoke-RestMethod -Uri "https://discord.com/api/oauth2/token" -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        Save-Token -Access $resp.access_token -Refresh $resp.refresh_token -ExpiresIn $resp.expires_in
        return @{ access_token = $resp.access_token; refresh_token = $resp.refresh_token }
    } catch {
        Write-Log "Token refresh error: $($_.Exception.Message)"
        return $null
    }
}

function Invoke-TokenExchange {
    param([string]$Code)
    if ($Script:ClientSecret -eq "") { Write-Log "No client secret for exchange"; return "" }
    try {
        $cid  = [Uri]::EscapeDataString($Script:ClientId)
        $cs   = [Uri]::EscapeDataString($Script:ClientSecret)
        $c    = [Uri]::EscapeDataString($Code)
        $ruri = [Uri]::EscapeDataString("http://127.0.0.1")
        $body = "client_id=$cid&client_secret=$cs&grant_type=authorization_code&code=$c&redirect_uri=$ruri"
        $resp = Invoke-RestMethod -Uri "https://discord.com/api/oauth2/token" -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        Save-Token -Access $resp.access_token -Refresh $resp.refresh_token -ExpiresIn $resp.expires_in
        return $resp.access_token
    } catch {
        Write-Log "Token exchange error: $($_.Exception.Message)"
        return ""
    }
}

function Invoke-RPCAuthenticate {
    param([string]$Token)
    $nonce = [System.Guid]::NewGuid().ToString("N")
    $cmd   = '{"cmd":"AUTHENTICATE","args":{"access_token":"' + $Token + '"},"nonce":"' + $nonce + '"}'
    if (-not (Send-RPCFrame -Opcode $OP_FRAME -Json $cmd)) { return $false }
    $resp = Read-RPCFrame -TimeoutMs 5000
    if ($null -ne $resp -and $resp.Data.cmd -eq "AUTHENTICATE" -and ($null -eq $resp.Data.evt -or $resp.Data.evt -eq "")) {
        Write-Log "Authenticated as $($resp.Data.data.user.username)"
        return $true
    }
    Write-Log "Authenticate failed: $(if ($null -ne $resp) { $resp.Data | ConvertTo-Json -Compress } else { 'null' })"
    return $false
}

function Invoke-RPCAuthorize {
    if ($Script:ClientSecret -eq "") {
        Set-State -Id $S_STATUS -Val "Client Secret fehlt"
        Set-State -Id $S_LASTERR -Val "Client Secret in TP Settings eintragen!"
        Write-Log "Cannot authorize: no client secret"
        return ""
    }

    $nonce = [System.Guid]::NewGuid().ToString("N")
    $cmd   = '{"cmd":"AUTHORIZE","args":{"client_id":"' + $Script:ClientId + '","scopes":["rpc"]},"nonce":"' + $nonce + '"}'
    if (-not (Send-RPCFrame -Opcode $OP_FRAME -Json $cmd)) { return "" }

    Set-State -Id $S_STATUS -Val "Warte auf Discord-Autorisierung..."
    Set-State -Id $S_DEBUG  -Val "Bitte in Discord den Popup bestaetigen!"
    Write-Log "Waiting for user to authorize in Discord (up to 60s)..."

    # Wait up to 60 seconds for user to click Authorize in Discord
    $resp = Read-RPCFrame -TimeoutMs 60000
    if ($null -ne $resp -and $resp.Data.cmd -eq "AUTHORIZE") {
        $code = $null
        if ($null -ne $resp.Data.data) { $code = $resp.Data.data.code }
        if ($null -ne $code -and $code -ne "") {
            Write-Log "Auth code received, exchanging for token..."
            return Invoke-TokenExchange -Code $code
        }
    }
    Write-Log "Authorization failed or timed out. Resp: $(if ($null -ne $resp) { $resp.Data | ConvertTo-Json -Compress } else { 'null/timeout' })"
    return ""
}

function Initialize-RPCConnection {
    # 1) Connect pipe
    if (-not (Connect-DiscordRPC)) {
        Set-State -Id $S_STATUS -Val "Discord nicht gefunden"
        Set-State -Id $S_LASTERR -Val "Discord Desktop muss laufen"
        return $false
    }

    # 2) Handshake
    if (-not (Invoke-Handshake)) {
        Set-State -Id $S_STATUS -Val "RPC Handshake fehlgeschlagen"
        Set-State -Id $S_LASTERR -Val "Application ID pruefen"
        return $false
    }

    # 3) Try stored token first
    $stored = Get-StoredToken
    if ($null -ne $stored) {
        $Script:AccessToken  = $stored.access_token
        $Script:RefreshToken = $stored.refresh_token
        if (Invoke-RPCAuthenticate -Token $Script:AccessToken) {
            $Script:RPCReady = $true
            Set-State -Id $S_STATUS -Val "Online"
            Set-State -Id $S_LASTERR -Val ""
            Write-Log "RPC connection established (stored token)"
            return $true
        }
        Write-Log "Stored token rejected - need re-auth"
        try { Remove-Item $Script:TokenFile -Force } catch {}
    }

    # 4) Full authorization flow
    $token = Invoke-RPCAuthorize
    if ($token -ne "") {
        $Script:AccessToken = $token
        if (Invoke-RPCAuthenticate -Token $Script:AccessToken) {
            $Script:RPCReady = $true
            Set-State -Id $S_STATUS -Val "Online"
            Set-State -Id $S_LASTERR -Val ""
            Write-Log "RPC connection established (new token)"
            return $true
        }
    }

    Set-State -Id $S_STATUS -Val "Autorisierung fehlgeschlagen"
    return $false
}

# =============================================================
# Main poll
# =============================================================
function Invoke-DiscordPoll {
    if ($Script:ClientId -eq "" -or $Script:ClientSecret -eq "") {
        Set-State -Id $S_STATUS -Val "Einstellungen fehlen"
        Write-Log "Poll skipped - settings incomplete"
        return
    }

    # Connect/reconnect if needed
    $needInit = $false
    if ($null -eq $Script:Pipe) { $needInit = $true }
    elseif (-not $Script:Pipe.IsConnected) { $needInit = $true }
    elseif (-not $Script:RPCReady) { $needInit = $true }

    if ($needInit) {
        Write-Log "Initializing RPC connection..."
        $ok = Initialize-RPCConnection
        if (-not $ok) {
            Set-State -Id $S_LASTCHK -Val (Get-Date -Format "HH:mm:ss")
            return
        }
    }

    # Send GET_SELECTED_VOICE_CHANNEL
    $nonce = [System.Guid]::NewGuid().ToString("N")
    $cmd   = '{"cmd":"GET_SELECTED_VOICE_CHANNEL","args":{},"nonce":"' + $nonce + '"}'
    Set-State -Id $S_DEBUG -Val "GET_SELECTED_VOICE_CHANNEL"

    if (-not (Send-RPCFrame -Opcode $OP_FRAME -Json $cmd)) {
        $Script:RPCReady = $false
        Set-State -Id $S_STATUS  -Val "Verbindung verloren"
        Set-State -Id $S_LASTERR -Val "RPC Verbindung unterbrochen"
        Set-State -Id $S_LASTCHK -Val (Get-Date -Format "HH:mm:ss")
        Write-Log "Send failed - RPC disconnected"
        return
    }

    $resp = Read-RPCFrame -TimeoutMs 5000
    if ($null -eq $resp) {
        $Script:RPCReady = $false
        Set-State -Id $S_STATUS  -Val "Keine Antwort von Discord"
        Set-State -Id $S_LASTCHK -Val (Get-Date -Format "HH:mm:ss")
        Write-Log "No response from Discord RPC"
        return
    }

    # data is null when not in any voice channel
    $chData = $resp.Data.data

    if ($null -eq $chData -or $null -eq $chData.id) {
        Set-State -Id $S_STATUS  -Val "Online"
        Set-State -Id $S_CHANNEL -Val "Nicht verbunden"
        Set-State -Id $S_MEMBERS -Val ""
        Set-State -Id $S_COUNT   -Val "0"
        Set-State -Id $S_LASTERR -Val ""
        Write-Log "Not in any voice channel"
    } else {
        $chName = $chData.name
        if ($null -eq $chName -or $chName -eq "") { $chName = $chData.id }

        $names = @()
        if ($null -ne $chData.voice_states) {
            foreach ($vs in $chData.voice_states) {
                $dn = ""
                if ($null -ne $vs.nick -and $vs.nick -ne "") {
                    $dn = $vs.nick
                } elseif ($null -ne $vs.user) {
                    if ($null -ne $vs.user.global_name -and $vs.user.global_name -ne "") {
                        $dn = $vs.user.global_name
                    } else {
                        $dn = $vs.user.username
                    }
                }
                if ($dn -eq "") { $dn = "Unbekannt" }
                $names += $dn
            }
        }

        $memberStr = $names -join ", "
        $cntStr    = [string]$names.Count

        Set-State -Id $S_STATUS  -Val "Online"
        Set-State -Id $S_CHANNEL -Val $chName
        Set-State -Id $S_MEMBERS -Val $memberStr
        Set-State -Id $S_COUNT   -Val $cntStr
        Set-State -Id $S_LASTERR -Val ""
        Write-Log "Channel: $chName | Members($cntStr): $memberStr"
    }

    Set-State -Id $S_LASTCHK -Val (Get-Date -Format "HH:mm:ss")
}

# =============================================================
# Main
# =============================================================
Write-Log "=== WalhallaDiscordChannelViewer v2 (RPC) starting ==="

if (-not (Connect-TP)) {
    Write-Log "FATAL: Could not connect to Touch Portal"
    exit 1
}

Set-State -Id $S_STATUS -Val "Verbunden - warte auf Einstellungen"
$lastPoll = [DateTime]::MinValue

while ($Script:Running) {
    $msg = Read-TPMessage
    while ($null -ne $msg) {
        $t = $msg.type
        if ($t -eq "info") {
            if ($null -ne $msg.settings) { Process-Settings -Items $msg.settings }
            Write-Log "TP info received"
        } elseif ($t -eq "settings") {
            if ($null -ne $msg.values) { Process-Settings -Items $msg.values }
            Write-Log "TP settings updated - resetting RPC"
            $Script:RPCReady = $false
            if ($null -ne $Script:Pipe) { try { $Script:Pipe.Dispose() } catch {}; $Script:Pipe = $null }
        } elseif ($t -eq "action") {
            if ($msg.actionId -eq "$PluginId.action.refresh") {
                $Script:ForceRefresh = $true
                Write-Log "Force refresh"
            }
        } elseif ($t -eq "closePlugin") {
            Write-Log "closePlugin received"
            $Script:Running = $false
        }
        $msg = Read-TPMessage
    }

    $elapsed = ([DateTime]::Now - $lastPoll).TotalSeconds
    if ($Script:ForceRefresh -or ($elapsed -ge [double]$Script:CheckInterval)) {
        $Script:ForceRefresh = $false
        Invoke-DiscordPoll
        $lastPoll = [DateTime]::Now
    }

    Start-Sleep -Milliseconds 200
}

Write-Log "=== Plugin stopping ==="
try { if ($null -ne $Script:Pipe) { $Script:Pipe.Dispose() } } catch {}
Disconnect-TP
exit 0
