# DiscordChannelViewer.ps1 - v4 state machine (non-blocking)
# WalhallaDiscordChannelViewer - PowerShell 5.1

# Desktop diagnostic - first thing always
try { Add-Content "$env:USERPROFILE\Desktop\WalhallaDC.log" "[$(Get-Date -F 'HH:mm:ss')] v4 start" -Encoding UTF8 } catch {}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$PluginId = "odin23x.walhalla_discord_channel_viewer"
$TPPort   = 12136
$LogDir   = "$env:APPDATA\TouchPortal\plugins\WalhallaDiscordChannelViewer"
$LogFile  = "$LogDir\plugin.log"
$TokFile  = "$LogDir\rpc_token.json"

function wl { param([string]$m)
    $l = "[$(Get-Date -F 'HH:mm:ss')] $m"
    try { Add-Content $LogFile $l -Encoding UTF8 } catch {
        try { Add-Content "$env:USERPROFILE\Desktop\WalhallaDC.log" $l -Encoding UTF8 } catch {}
    }
}

wl "=== v4 starting ==="

# ---- TP socket ----
$script:Tcp    = $null
$script:Stream = $null
$script:Writer = $null
$script:Reader = $null
$script:Run    = $true

function Connect-TP {
    try {
        $script:Tcp    = New-Object System.Net.Sockets.TcpClient
        $script:Tcp.Connect("127.0.0.1", $TPPort)
        $script:Stream = $script:Tcp.GetStream()
        $enc           = New-Object System.Text.UTF8Encoding($false)
        $script:Writer = New-Object System.IO.StreamWriter($script:Stream, $enc)
        $script:Writer.AutoFlush = $true
        $script:Reader = New-Object System.IO.StreamReader($script:Stream, $enc)
        $script:Writer.WriteLine('{"type":"pair","id":"' + $PluginId + '"}')
        wl "TP connected"
        return $true
    } catch { wl "TP connect fail: $($_.Exception.Message)"; return $false }
}

function stp { param([string]$j)
    try { $script:Writer.WriteLine($j) }
    catch { wl "Send fail: $($_.Exception.Message)"; $script:Run = $false }
}

function ss { param([string]$id, [string]$v)
    stp ('{"type":"stateUpdate","id":"' + $id + '","value":' + ($v | ConvertTo-Json) + '}')
}

function rtp {
    try {
        if ($null -eq $script:Tcp -or -not $script:Tcp.Connected) { $script:Run = $false; return $null }
        if ($script:Stream.DataAvailable) {
            $ln = $script:Reader.ReadLine()
            if ($ln) { try { return ($ln | ConvertFrom-Json) } catch {} }
        }
    } catch { $script:Run = $false }
    return $null
}

# ---- Discord RPC pipe ----
$script:Pipe = $null

function srpc { param([int]$op, [string]$j)
    try {
        $b  = [System.Text.Encoding]::UTF8.GetBytes($j)
        $cb = New-Object System.Byte[] (8 + $b.Length)
        [System.BitConverter]::GetBytes([int32]$op).CopyTo($cb, 0)
        [System.BitConverter]::GetBytes([int32]$b.Length).CopyTo($cb, 4)
        [Array]::Copy($b, 0, $cb, 8, $b.Length)
        $script:Pipe.Write($cb, 0, $cb.Length)
        $script:Pipe.Flush()
        return $true
    } catch { wl "srpc fail: $($_.Exception.Message)"; return $false }
}

function rrpc { param([int]$ms = 100)
    if ($null -eq $script:Pipe -or -not $script:Pipe.IsConnected) { return $null }
    try {
        $h  = New-Object System.Byte[] 8
        $ar = $script:Pipe.BeginRead($h, 0, 8, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($ms)) { return $null }
        $n  = $script:Pipe.EndRead($ar)
        if ($n -le 0) { return $null }
        # Read remaining header bytes if needed
        $got = $n
        $deadline = [DateTime]::Now.AddMilliseconds(500)
        while ($got -lt 8) {
            if ([DateTime]::Now -gt $deadline) { return $null }
            $ar2 = $script:Pipe.BeginRead($h, $got, 8 - $got, $null, $null)
            $ar2.AsyncWaitHandle.WaitOne(200) | Out-Null
            $n2 = $script:Pipe.EndRead($ar2)
            if ($n2 -le 0) { return $null }
            $got += $n2
        }
        $len = [System.BitConverter]::ToInt32($h, 4)
        if ($len -le 0 -or $len -gt 524288) { return $null }
        $p   = New-Object System.Byte[] $len
        $got = 0
        $deadline = [DateTime]::Now.AddMilliseconds(1000)
        while ($got -lt $len) {
            if ([DateTime]::Now -gt $deadline) { break }
            $ar3 = $script:Pipe.BeginRead($p, $got, $len - $got, $null, $null)
            $ar3.AsyncWaitHandle.WaitOne(500) | Out-Null
            $n3 = $script:Pipe.EndRead($ar3)
            if ($n3 -le 0) { break }
            $got += $n3
        }
        $json = [System.Text.Encoding]::UTF8.GetString($p, 0, $got)
        return ($json | ConvertFrom-Json)
    } catch { return $null }
}

function pipe-connect {
    for ($i = 0; $i -le 9; $i++) {
        try {
            $p = New-Object System.IO.Pipes.NamedPipeClientStream(".", "discord-ipc-$i",
                [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
            $p.Connect(100)
            $script:Pipe = $p
            wl "Pipe: discord-ipc-$i"
            return $true
        } catch {}
    }
    return $false
}

# ---- Token storage ----
function save-tok { param([string]$a,[string]$r,[int]$e)
    @{access_token=$a;refresh_token=$r;expires_at=([DateTime]::UtcNow.AddSeconds($e).ToString("o"))} |
        ConvertTo-Json | Set-Content $TokFile -Encoding UTF8
}

function get-tok {
    if (-not (Test-Path $TokFile)) { return $null }
    try {
        $d = Get-Content $TokFile -Raw | ConvertFrom-Json
        if (-not $d.access_token) { return $null }
        if ($d.expires_at -and [DateTime]::UtcNow -gt [DateTime]::Parse($d.expires_at).AddMinutes(-5)) {
            # Refresh
            try {
                $b = "client_id=$([Uri]::EscapeDataString($script:ClientId))&client_secret=$([Uri]::EscapeDataString($script:Secret))&grant_type=refresh_token&refresh_token=$([Uri]::EscapeDataString($d.refresh_token))"
                $r = Invoke-RestMethod "https://discord.com/api/oauth2/token" -Method Post -Body $b -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
                save-tok $r.access_token $r.refresh_token $r.expires_in
                return @{access_token=$r.access_token}
            } catch { return $null }
        }
        return $d
    } catch { return $null }
}

function exchange-tok { param([string]$code)
    $cid = [Uri]::EscapeDataString($script:ClientId)
    $cs  = [Uri]::EscapeDataString($script:Secret)
    $c   = [Uri]::EscapeDataString($code)
    try {
        $r = Invoke-RestMethod "https://discord.com/api/oauth2/token" -Method Post `
            -Body "client_id=$cid&client_secret=$cs&grant_type=authorization_code&code=$c" `
            -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        save-tok $r.access_token $r.refresh_token $r.expires_in
        wl "Token OK (no redirect_uri)"
        return $r.access_token
    } catch {}
    try {
        $ru = [Uri]::EscapeDataString("http://127.0.0.1")
        $r = Invoke-RestMethod "https://discord.com/api/oauth2/token" -Method Post `
            -Body "client_id=$cid&client_secret=$cs&grant_type=authorization_code&code=$c&redirect_uri=$ru" `
            -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        save-tok $r.access_token $r.refresh_token $r.expires_in
        wl "Token OK (with redirect_uri)"
        return $r.access_token
    } catch {
        wl "Token exchange FAILED: $($_.Exception.Message)"
        ss "$PluginId.state.last_error" "401: Client Secret falsch ODER http://127.0.0.1 als Redirect URI im Developer Portal fehlt"
        return ""
    }
}

# ---- RPC State machine ----
# States: idle | connecting | handshaking | need_auth | authorizing | authenticating | ready | failed
$script:RpcState    = "idle"
$script:RpcDeadline = [DateTime]::MinValue
$script:AccessToken = ""
$script:NextConnect = [DateTime]::MinValue
$script:ConnectWait = 15

function tick-rpc {
    switch ($script:RpcState) {
        "idle" {
            if ([DateTime]::Now -lt $script:NextConnect) { return }
            ss "$PluginId.state.debug" "Connecting..."
            if (pipe-connect) {
                srpc 0 ('{"v":1,"client_id":"' + $script:ClientId + '"}') | Out-Null
                $script:RpcState    = "handshaking"
                $script:RpcDeadline = [DateTime]::Now.AddSeconds(3)
                wl "Handshake sent"
            } else {
                ss "$PluginId.state.status" "Discord nicht gefunden"
                $script:NextConnect = [DateTime]::Now.AddSeconds($script:ConnectWait)
                if ($script:ConnectWait -lt 60) { $script:ConnectWait += 15 }
            }
        }
        "handshaking" {
            if ([DateTime]::Now -gt $script:RpcDeadline) {
                wl "Handshake timeout"
                $script:RpcState    = "idle"
                $script:NextConnect = [DateTime]::Now.AddSeconds($script:ConnectWait)
                return
            }
            $r = rrpc 200
            if ($null -eq $r) { return }
            if ($r.evt -eq "READY") {
                wl "READY: $($r.data.user.username)"
                $script:RpcState = "need_auth"
            } elseif ($r.evt -eq "ERROR") {
                wl "Handshake error: $($r.data.message)"
                $script:RpcState    = "idle"
                $script:NextConnect = [DateTime]::Now.AddSeconds($script:ConnectWait)
            }
        }
        "need_auth" {
            $t = get-tok
            if ($t) {
                $script:AccessToken = $t.access_token
                $n = [System.Guid]::NewGuid().ToString("N")
                srpc 1 ('{"cmd":"AUTHENTICATE","args":{"access_token":"' + $script:AccessToken + '"},"nonce":"' + $n + '"}') | Out-Null
                $script:RpcState    = "authenticating"
                $script:RpcDeadline = [DateTime]::Now.AddSeconds(3)
                wl "Authenticating with stored token..."
            } else {
                $n = [System.Guid]::NewGuid().ToString("N")
                srpc 1 ('{"cmd":"AUTHORIZE","args":{"client_id":"' + $script:ClientId + '","scopes":["rpc"]},"nonce":"' + $n + '"}') | Out-Null
                $script:RpcState = "authorizing"
                ss "$PluginId.state.status" "Discord-Popup bestaetigen!"
                ss "$PluginId.state.debug"  "Warte auf Autorisierung in Discord..."
                wl "AUTHORIZE sent - waiting for user to click in Discord"
            }
        }
        "authorizing" {
            # Non-blocking - just check if Discord responded
            $r = rrpc 100
            if ($null -eq $r) { return }
            wl "Authorize pipe data: cmd=$($r.cmd) evt=$($r.evt)"
            if ($r.cmd -eq "AUTHORIZE" -and $r.data.code) {
                wl "Auth code received (length=$($r.data.code.Length))"
                ss "$PluginId.state.status" "Token wird abgerufen..."
                $tok = exchange-tok $r.data.code
                if ($tok) {
                    $script:AccessToken = $tok
                    $n = [System.Guid]::NewGuid().ToString("N")
                    srpc 1 ('{"cmd":"AUTHENTICATE","args":{"access_token":"' + $tok + '"},"nonce":"' + $n + '"}') | Out-Null
                    $script:RpcState    = "authenticating"
                    $script:RpcDeadline = [DateTime]::Now.AddSeconds(3)
                } else {
                    $script:RpcState = "failed"
                }
            }
        }
        "authenticating" {
            if ([DateTime]::Now -gt $script:RpcDeadline) {
                wl "Auth timeout - removing stored token"
                try { Remove-Item $TokFile -Force } catch {}
                $script:RpcState    = "idle"
                $script:NextConnect = [DateTime]::Now.AddSeconds(5)
                return
            }
            $r = rrpc 200
            if ($null -eq $r) { return }
            if ($r.cmd -eq "AUTHENTICATE" -and -not $r.evt) {
                wl "Authenticated OK"
                $script:RpcState    = "ready"
                $script:ConnectWait = 15
                ss "$PluginId.state.status" "Online"
                ss "$PluginId.state.last_error" ""
            } elseif ($r.evt -eq "ERROR") {
                wl "Auth failed: $($r.data.message)"
                try { Remove-Item $TokFile -Force } catch {}
                $script:RpcState    = "idle"
                $script:NextConnect = [DateTime]::Now.AddSeconds(5)
            }
        }
        "ready" {
            # Check pipe still alive
            if ($null -eq $script:Pipe -or -not $script:Pipe.IsConnected) {
                wl "Pipe disconnected"
                $script:RpcState    = "idle"
                $script:NextConnect = [DateTime]::Now.AddSeconds(5)
                return
            }
            # Get voice channel
            $n = [System.Guid]::NewGuid().ToString("N")
            if (-not (srpc 1 ('{"cmd":"GET_SELECTED_VOICE_CHANNEL","args":{},"nonce":"' + $n + '"}'))) {
                $script:RpcState = "idle"
                return
            }
            $r = rrpc 2000
            if ($null -eq $r) {
                $script:RpcState = "idle"
                wl "No response to GET_SELECTED_VOICE_CHANNEL"
                return
            }
            $ch = $r.data
            if ($null -eq $ch -or $null -eq $ch.id) {
                ss "$PluginId.state.status"       "Online"
                ss "$PluginId.state.my_channel"   "Nicht verbunden"
                ss "$PluginId.state.members"      ""
                ss "$PluginId.state.member_count" "0"
            } else {
                $names = @()
                if ($ch.voice_states) {
                    foreach ($vs in $ch.voice_states) {
                        $dn = ""
                        if ($vs.nick -and $vs.nick -ne "") { $dn = $vs.nick }
                        elseif ($vs.user -and $vs.user.global_name -and $vs.user.global_name -ne "") { $dn = $vs.user.global_name }
                        elseif ($vs.user -and $vs.user.username) { $dn = $vs.user.username }
                        if ($dn -eq "") { $dn = "?" }
                        $names += $dn
                    }
                }
                ss "$PluginId.state.status"       "Online"
                ss "$PluginId.state.my_channel"   $ch.name
                ss "$PluginId.state.members"      ($names -join ", ")
                ss "$PluginId.state.member_count" ([string]$names.Count)
            }
            ss "$PluginId.state.last_check" (Get-Date -F "HH:mm:ss")
            ss "$PluginId.state.last_error" ""
        }
        "failed" {
            ss "$PluginId.state.status" "Auth fehlgeschlagen"
        }
    }
}

# ---- Settings ----
$script:ClientId     = "1513616012593991731"
$script:Secret       = ""
$script:PollInterval = 5

function apply-setting { param([string]$name, [string]$val)
    switch ($name) {
        "Application ID"          { if ($val) { $script:ClientId = $val } }
        "Client Secret"           { $script:Secret = $val }
        "Discord Bot Token"       { $script:Secret = $val }   # legacy field name
        "Check Interval Seconds"  {
            $v = 5
            if ([int]::TryParse($val, [ref]$v) -and $v -ge 2) { $script:PollInterval = $v }
        }
    }
}

function apply-settings { param($items)
    foreach ($s in $items) {
        $s.PSObject.Properties | ForEach-Object { apply-setting $_.Name ([string]$_.Value) }
    }
    wl "Settings: ClientId=$($script:ClientId) SecretSet=$($script:Secret -ne '')"
}

# ---- Main ----
if (-not (Connect-TP)) { wl "Cannot connect TP"; exit 1 }

ss "$PluginId.state.status" "Verbunden"
$last = [DateTime]::MinValue

while ($script:Run) {
    # Process ALL pending TP messages first
    $msg = rtp
    while ($null -ne $msg) {
        switch ($msg.type) {
            "info" {
                if ($msg.settings) { apply-settings $msg.settings }
            }
            "settings" {
                if ($msg.values) { apply-settings $msg.values }
                # Reset RPC on settings change
                $script:RpcState    = "idle"
                $script:NextConnect = [DateTime]::MinValue
                if ($script:Pipe) { try { $script:Pipe.Dispose() } catch {}; $script:Pipe = $null }
            }
            "action" {
                if ($msg.actionId -eq "$PluginId.action.refresh") {
                    $last = [DateTime]::MinValue
                    if ($script:RpcState -eq "failed") {
                        $script:RpcState    = "idle"
                        $script:NextConnect = [DateTime]::MinValue
                    }
                }
            }
            "closePlugin" {
                wl "closePlugin received"
                $script:Run = $false
            }
        }
        $msg = rtp
    }

    if (-not $script:Run) { break }

    # Tick RPC state machine (non-blocking, max ~300ms per tick)
    if ($script:Secret -ne "") {
        $elapsed = ([DateTime]::Now - $last).TotalSeconds
        if ($elapsed -ge $script:PollInterval -or $script:RpcState -eq "authorizing" -or $script:RpcState -eq "handshaking" -or $script:RpcState -eq "authenticating") {
            tick-rpc
            if ($script:RpcState -eq "ready") { $last = [DateTime]::Now }
        }
    } else {
        ss "$PluginId.state.status" "Client Secret fehlt"
    }

    Start-Sleep -Milliseconds 200
}

wl "=== Stopping ==="
try { if ($script:Pipe) { $script:Pipe.Dispose() } } catch {}
try { $script:Writer.Dispose() } catch {}
try { $script:Tcp.Dispose()    } catch {}
