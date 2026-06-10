# DiscordChannelViewer.ps1 - v3 clean rewrite
# WalhallaDiscordChannelViewer - PowerShell 5.1

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$PluginId  = "odin23x.walhalla_discord_channel_viewer"
$TPPort    = 12136
$LogFile   = "$env:APPDATA\TouchPortal\plugins\WalhallaDiscordChannelViewer\plugin.log"
$TokenFile = "$env:APPDATA\TouchPortal\plugins\WalhallaDiscordChannelViewer\rpc_token.json"

# Write log - also to Desktop as fallback
function Write-Log { param([string]$M)
    $l = "[$(Get-Date -Format 'HH:mm:ss')] $M"
    try { Add-Content -Path $LogFile -Value $l -Encoding UTF8 -ErrorAction Stop } catch {
        try { Add-Content -Path "$env:USERPROFILE\Desktop\WalhallaDC.log" -Value $l -Encoding UTF8 } catch {}
    }
}

Write-Log "=== v3 starting ==="

# TP connection
$Tcp = $null; $Stream = $null; $Writer = $null; $Reader = $null

function Connect-TP {
    try {
        $script:Tcp = New-Object System.Net.Sockets.TcpClient
        $script:Tcp.Connect("127.0.0.1", $TPPort)
        $script:Stream = $script:Tcp.GetStream()
        $enc = New-Object System.Text.UTF8Encoding($false)
        $script:Writer = New-Object System.IO.StreamWriter($script:Stream, $enc)
        $script:Writer.AutoFlush = $true
        $script:Reader = New-Object System.IO.StreamReader($script:Stream, $enc)
        $script:Writer.WriteLine('{"type":"pair","id":"' + $PluginId + '"}')
        Write-Log "TP connected"
        return $true
    } catch { Write-Log "TP connect error: $($_.Exception.Message)"; return $false }
}

function Send-TP { param([string]$J)
    try { $script:Writer.WriteLine($J) } catch { $script:Running = $false }
}

function Set-State { param([string]$Id, [string]$Val)
    Send-TP ('{"type":"stateUpdate","id":"' + $Id + '","value":' + ($Val | ConvertTo-Json) + '}')
}

function Read-TP {
    try {
        if ($null -eq $script:Tcp -or -not $script:Tcp.Connected) { $script:Running = $false; return $null }
        if ($script:Stream.DataAvailable) {
            $line = $script:Reader.ReadLine()
            if ($line) { try { return ($line | ConvertFrom-Json) } catch {} }
        }
    } catch { $script:Running = $false }
    return $null
}

# RPC pipe
$Pipe = $null

function Send-RPC { param([int]$Op, [string]$J)
    try {
        $b = [System.Text.Encoding]::UTF8.GetBytes($J)
        $c = [byte[]]::new(8 + $b.Length)
        [System.BitConverter]::GetBytes([int32]$Op).CopyTo($c, 0)
        [System.BitConverter]::GetBytes([int32]$b.Length).CopyTo($c, 4)
        [Array]::Copy($b, 0, $c, 8, $b.Length)
        $script:Pipe.Write($c, 0, $c.Length)
        $script:Pipe.Flush()
        return $true
    } catch { Write-Log "Send-RPC: $($_.Exception.Message)"; return $false }
}

function Read-RPC { param([int]$Ms = 5000)
    try {
        $h = [byte[]]::new(8); $got = 0
        $dead = [DateTime]::Now.AddMilliseconds($Ms)
        while ($got -lt 8) {
            $left = [int]($dead - [DateTime]::Now).TotalMilliseconds
            if ($left -le 0) { return $null }
            $ar = $script:Pipe.BeginRead($h, $got, 8 - $got, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($left)) { return $null }
            $n = $script:Pipe.EndRead($ar)
            if ($n -le 0) { return $null }
            $got += $n
        }
        $op  = [System.BitConverter]::ToInt32($h, 0)
        $len = [System.BitConverter]::ToInt32($h, 4)
        if ($len -le 0 -or $len -gt 524288) { return $null }
        $p = [byte[]]::new($len); $got = 0
        while ($got -lt $len) {
            $left = [int]($dead - [DateTime]::Now).TotalMilliseconds
            if ($left -le 0) { break }
            $ar = $script:Pipe.BeginRead($p, $got, $len - $got, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($left)) { break }
            $n = $script:Pipe.EndRead($ar)
            if ($n -le 0) { break }
            $got += $n
        }
        $json = [System.Text.Encoding]::UTF8.GetString($p, 0, $got)
        return @{ Op = $op; D = ($json | ConvertFrom-Json) }
    } catch { return $null }
}

function Save-Token { param([string]$A, [string]$R, [int]$E)
    @{ access_token=$A; refresh_token=$R; expires_at=([DateTime]::UtcNow.AddSeconds($E).ToString("o")) } |
        ConvertTo-Json | Set-Content -Path $TokenFile -Encoding UTF8
}

function Get-Token {
    if (-not (Test-Path $TokenFile)) { return $null }
    try {
        $d = Get-Content $TokenFile -Raw | ConvertFrom-Json
        if (-not $d.access_token) { return $null }
        if ($d.expires_at -and [DateTime]::UtcNow -gt [DateTime]::Parse($d.expires_at).AddMinutes(-5)) {
            return Refresh-Token $d.refresh_token
        }
        return $d
    } catch { return $null }
}

function Refresh-Token { param([string]$R)
    try {
        $b = "client_id=$([Uri]::EscapeDataString($script:ClientId))&client_secret=$([Uri]::EscapeDataString($script:Secret))&grant_type=refresh_token&refresh_token=$([Uri]::EscapeDataString($R))"
        $r = Invoke-RestMethod -Uri "https://discord.com/api/oauth2/token" -Method Post -Body $b -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        Save-Token $r.access_token $r.refresh_token $r.expires_in
        return @{ access_token=$r.access_token; refresh_token=$r.refresh_token }
    } catch { Write-Log "Refresh error: $($_.Exception.Message)"; return $null }
}

function Exchange-Token { param([string]$Code)
    $cid = [Uri]::EscapeDataString($script:ClientId)
    $cs  = [Uri]::EscapeDataString($script:Secret)
    $c   = [Uri]::EscapeDataString($Code)
    # Try without redirect_uri first
    try {
        $r = Invoke-RestMethod -Uri "https://discord.com/api/oauth2/token" -Method Post -Body "client_id=$cid&client_secret=$cs&grant_type=authorization_code&code=$c" -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        Save-Token $r.access_token $r.refresh_token $r.expires_in
        Write-Log "Token OK (no redirect_uri)"
        return $r.access_token
    } catch {}
    # Try with redirect_uri
    try {
        $ru = [Uri]::EscapeDataString("http://127.0.0.1")
        $r = Invoke-RestMethod -Uri "https://discord.com/api/oauth2/token" -Method Post -Body "client_id=$cid&client_secret=$cs&grant_type=authorization_code&code=$c&redirect_uri=$ru" -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        Save-Token $r.access_token $r.refresh_token $r.expires_in
        Write-Log "Token OK (with redirect_uri)"
        return $r.access_token
    } catch {
        Write-Log "Token exchange FAILED: $($_.Exception.Message)"
        $script:AuthFailed = $true
        Set-State "$PluginId.state.last_error" "401: Client Secret falsch ODER http://127.0.0.1 als Redirect URI im Developer Portal fehlt"
        return ""
    }
}

function Connect-Discord {
    for ($i = 0; $i -le 9; $i++) {
        try {
            $p = New-Object System.IO.Pipes.NamedPipeClientStream(".", "discord-ipc-$i", [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
            $p.Connect(1000)
            $script:Pipe = $p
            Write-Log "Pipe connected: discord-ipc-$i"
            return $true
        } catch {}
    }
    Write-Log "No Discord pipe found"
    return $false
}

function Init-RPC {
    if (-not (Connect-Discord)) {
        Set-State "$PluginId.state.status" "Discord nicht gefunden"
        return $false
    }
    # Handshake
    if (-not (Send-RPC 0 ('{"v":1,"client_id":"' + $script:ClientId + '"}'))) { return $false }
    $r = Read-RPC 10000
    if ($null -eq $r -or $r.D.evt -ne "READY") { Write-Log "Handshake failed"; return $false }
    Write-Log "READY: $($r.D.data.user.username)"
    # Try stored token
    $t = Get-Token
    if ($t) {
        $n = [System.Guid]::NewGuid().ToString("N")
        if (Send-RPC 1 ('{"cmd":"AUTHENTICATE","args":{"access_token":"' + $t.access_token + '"},"nonce":"' + $n + '"}')) {
            $r = Read-RPC 5000
            if ($r -and $r.D.cmd -eq "AUTHENTICATE" -and -not $r.D.evt) {
                Write-Log "Auth OK (stored token)"
                return $true
            }
        }
        Write-Log "Stored token rejected"
        try { Remove-Item $TokenFile -Force } catch {}
    }
    # Authorize
    if ($script:AuthFailed) { return $false }
    $n = [System.Guid]::NewGuid().ToString("N")
    if (-not (Send-RPC 1 ('{"cmd":"AUTHORIZE","args":{"client_id":"' + $script:ClientId + '","scopes":["rpc"]},"nonce":"' + $n + '"}'))) { return $false }
    Set-State "$PluginId.state.status" "Bitte Discord-Popup bestaetigen..."
    Write-Log "Waiting for authorization..."
    $r = Read-RPC 60000
    if ($r -and $r.D.cmd -eq "AUTHORIZE" -and $r.D.data.code) {
        $tok = Exchange-Token $r.D.data.code
        if ($tok) {
            $n = [System.Guid]::NewGuid().ToString("N")
            Send-RPC 1 ('{"cmd":"AUTHENTICATE","args":{"access_token":"' + $tok + '"},"nonce":"' + $n + '"}') | Out-Null
            $r = Read-RPC 5000
            if ($r -and $r.D.cmd -eq "AUTHENTICATE" -and -not $r.D.evt) {
                Write-Log "Auth OK (new token)"
                return $true
            }
        }
    }
    return $false
}

function Poll-Discord {
    if (-not $script:Secret) { Set-State "$PluginId.state.status" "Client Secret fehlt"; return }
    if ($null -eq $script:Pipe -or -not $script:Pipe.IsConnected -or -not $script:RPCReady) {
        $now = [DateTime]::Now
        if (($now - $script:LastTry).TotalSeconds -lt $script:Backoff) { return }
        $script:LastTry = $now
        $script:RPCReady = Init-RPC
        if (-not $script:RPCReady) { $script:Backoff = [Math]::Min($script:Backoff + 15, 60); return }
        $script:Backoff = 15
    }
    $n = [System.Guid]::NewGuid().ToString("N")
    if (-not (Send-RPC 1 ('{"cmd":"GET_SELECTED_VOICE_CHANNEL","args":{},"nonce":"' + $n + '"}'))) {
        $script:RPCReady = $false; return
    }
    $r = Read-RPC 5000
    if ($null -eq $r) { $script:RPCReady = $false; return }
    $ch = $r.D.data
    if ($null -eq $ch -or $null -eq $ch.id) {
        Set-State "$PluginId.state.status"     "Online"
        Set-State "$PluginId.state.my_channel" "Nicht verbunden"
        Set-State "$PluginId.state.members"    ""
        Set-State "$PluginId.state.member_count" "0"
    } else {
        $names = @()
        if ($ch.voice_states) {
            foreach ($vs in $ch.voice_states) {
                $dn = if ($vs.nick) { $vs.nick } elseif ($vs.user.global_name) { $vs.user.global_name } else { $vs.user.username }
                $names += $dn
            }
        }
        Set-State "$PluginId.state.status"       "Online"
        Set-State "$PluginId.state.my_channel"   $ch.name
        Set-State "$PluginId.state.members"      ($names -join ", ")
        Set-State "$PluginId.state.member_count" ([string]$names.Count)
    }
    Set-State "$PluginId.state.last_check" (Get-Date -Format "HH:mm:ss")
    Set-State "$PluginId.state.last_error" ""
}

# Runtime
$script:ClientId  = "1513616012593991731"
$script:Secret    = ""
$script:Running   = $true
$script:RPCReady  = $false
$script:AuthFailed= $false
$script:LastTry   = [DateTime]::MinValue
$script:Backoff   = 15

if (-not (Connect-TP)) { Write-Log "Cannot connect TP"; exit 1 }
Set-State "$PluginId.state.status" "Verbunden"
$last = [DateTime]::MinValue
$interval = 5

while ($script:Running) {
    $msg = Read-TP
    while ($null -ne $msg) {
        if ($msg.type -eq "info" -and $msg.settings) {
            foreach ($s in $msg.settings) {
                $s.PSObject.Properties | ForEach-Object {
                    switch ($_.Name) {
                        "Application ID"    { $script:ClientId = $_.Value }
                        "Client Secret"     { $script:Secret   = $_.Value }
                        "Discord Bot Token" { $script:Secret   = $_.Value }
                        "Check Interval Seconds" {
                            $v = 5; if ([int]::TryParse($_.Value,[ref]$v) -and $v -ge 2) { $interval = $v }
                        }
                    }
                }
            }
            Write-Log "Settings: ClientId=$($script:ClientId) SecretSet=$($script:Secret -ne '')"
        } elseif ($msg.type -eq "settings" -and $msg.values) {
            foreach ($s in $msg.values) {
                $s.PSObject.Properties | ForEach-Object {
                    switch ($_.Name) {
                        "Application ID"    { $script:ClientId = $_.Value }
                        "Client Secret"     { $script:Secret   = $_.Value }
                        "Discord Bot Token" { $script:Secret   = $_.Value }
                        "Check Interval Seconds" {
                            $v = 5; if ([int]::TryParse($_.Value,[ref]$v) -and $v -ge 2) { $interval = $v }
                        }
                    }
                }
            }
            $script:RPCReady = $false; $script:AuthFailed = $false; $script:Backoff = 15
            if ($script:Pipe) { try { $script:Pipe.Dispose() } catch {}; $script:Pipe = $null }
        } elseif ($msg.type -eq "action" -and $msg.actionId -eq "$PluginId.action.refresh") {
            $last = [DateTime]::MinValue
        } elseif ($msg.type -eq "closePlugin") {
            $script:Running = $false
        }
        $msg = Read-TP
    }
    if (([DateTime]::Now - $last).TotalSeconds -ge $interval) {
        Poll-Discord; $last = [DateTime]::Now
    }
    Start-Sleep -Milliseconds 200
}

Write-Log "Stopping"
try { if ($script:Pipe) { $script:Pipe.Dispose() } } catch {}
try { $script:Writer.Dispose() } catch {}
try { $script:Tcp.Dispose() } catch {}
