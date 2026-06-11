'use strict';

const fs             = require('fs');
const path           = require('path');
const TouchPortalAPI = require('touchportal-api');
const DiscordRPC     = require('discord-rpc');

const pluginId = 'odin23x.walhalla_discord_channel_viewer';

const S_STATUS  = pluginId + '.state.status';
const S_CHANNEL = pluginId + '.state.my_channel';
const S_MEMBERS = pluginId + '.state.members';
const S_COUNT   = pluginId + '.state.member_count';
const S_CHECK   = pluginId + '.state.last_check';
const S_ERROR   = pluginId + '.state.last_error';
const S_DEBUG   = pluginId + '.state.debug';
const A_REFRESH = pluginId + '.action.refresh';

const logFile = path.join(__dirname, 'plugin.log');
const LOG_MAX = 400;

function log() {
    var args = Array.prototype.slice.call(arguments);
    var line = '[' + new Date().toISOString() + '] ' +
        args.map(function(a) { return typeof a === 'string' ? a : JSON.stringify(a); }).join(' ') + '\n';
    try {
        var existing = '';
        try { existing = fs.readFileSync(logFile, 'utf8'); } catch {}
        var lines = existing.split('\n');
        if (lines.length > LOG_MAX) {
            lines = lines.slice(lines.length - LOG_MAX);
            fs.writeFileSync(logFile, lines.join('\n'), 'utf8');
        }
        fs.appendFileSync(logFile, line, 'utf8');
    } catch {}
    process.stdout.write(line);
}

function s(v) { return v == null ? '' : String(v); }

function settingsToObj(arr) {
    var out = {};
    for (var i = 0; i < (arr || []).length; i++) {
        var obj = arr[i];
        if (obj && typeof obj === 'object') {
            var k = Object.keys(obj)[0];
            if (k) out[k] = obj[k];
        }
    }
    return out;
}

function nowStr() {
    var d = new Date();
    var pad = function(n) { return n < 10 ? '0' + n : n; };
    return pad(d.getDate()) + '.' + pad(d.getMonth() + 1) + '.' + d.getFullYear() +
           ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

var TPClient = new TouchPortalAPI.Client();

var settings       = { clientId: '1513616012593991731', clientSecret: '' };
var rpc            = null;
var reconnectTimer = null;
var tpReady        = false;
var currentChId    = null;
var lastPushed     = '';

var state = {
    connected:   false,
    channelName: '',
    members:     []
};

// ── Push states to Touch Portal ──────────────────────────────────────────────

function pushStates() {
    if (!tpReady) return;

    var memberStr = state.members.join('\n');
    var status    = state.connected ? 'Verbunden' : 'Nicht verbunden';
    var channel   = state.channelName || 'Kein Channel';
    var debug     = 'Ch: ' + channel + ' | ' + state.members.length + ' Members';

    var key = status + '|' + channel + '|' + memberStr + '|' + state.members.length;
    if (key === lastPushed) return;
    lastPushed = key;

    TPClient.stateUpdateMany([
        { id: S_STATUS,  value: status },
        { id: S_CHANNEL, value: channel },
        { id: S_MEMBERS, value: memberStr },
        { id: S_COUNT,   value: String(state.members.length) },
        { id: S_CHECK,   value: nowStr() },
        { id: S_DEBUG,   value: debug }
    ]);
    log('States pushed:', debug);
}

function setError(msg) {
    if (tpReady) TPClient.stateUpdate(S_ERROR, s(msg));
    log('ERROR:', msg);
}

// ── Refresh channel data via RPC ─────────────────────────────────────────────

async function refreshChannel() {
    if (!rpc) return;
    try {
        var vc = await rpc.request('GET_SELECTED_VOICE_CHANNEL');
        if (vc && vc.id) {
            state.channelName = s(vc.name);
            state.members = (vc.voice_states || []).map(function(vs) {
                var name = s(vs.nick || (vs.user && vs.user.global_name) || (vs.user && vs.user.username) || 'Unknown');
                var tags = '';
                if (vs.voice_state) {
                    if (vs.voice_state.self_mute || vs.voice_state.mute) tags += ' [M]';
                    if (vs.voice_state.self_deaf || vs.voice_state.deaf) tags += ' [D]';
                    if (vs.voice_state.self_video)                       tags += ' [V]';
                }
                return name + tags;
            });
            await subscribeChannel(vc.id);
        } else {
            state.channelName = '';
            state.members     = [];
            currentChId       = null;
        }
        if (tpReady) TPClient.stateUpdate(S_ERROR, '');
        pushStates();
    } catch (e) {
        log('refreshChannel error:', e.message);
        setError('refreshChannel: ' + e.message);
    }
}

// ── Subscribe/unsubscribe to VOICE_STATE events for a channel ─────────────────

async function subscribeChannel(channelId) {
    if (!rpc) return;
    if (channelId === currentChId) return;

    var EVENTS = ['VOICE_STATE_CREATE', 'VOICE_STATE_UPDATE', 'VOICE_STATE_DELETE'];

    // Unsubscribe from previous channel
    if (currentChId) {
        for (var i = 0; i < EVENTS.length; i++) {
            try { await rpc.unsubscribe(EVENTS[i], { channel_id: currentChId }); } catch {}
        }
        log('Unsubscribed from channel', currentChId);
    }

    currentChId = channelId;

    // Subscribe to new channel
    for (var j = 0; j < EVENTS.length; j++) {
        try {
            await rpc.subscribe(EVENTS[j], { channel_id: channelId });
            log('Subscribed to', EVENTS[j], 'ch:', channelId);
        } catch (e) {
            log('Subscribe', EVENTS[j], 'error:', e.message);
        }
    }
}

// ── RPC connection ────────────────────────────────────────────────────────────

async function connectRPC() {
    if (rpc) return;
    if (!settings.clientId)     { log('No clientId - check settings');     return; }
    if (!settings.clientSecret) { log('No clientSecret - check settings'); return; }

    log('Connecting to Discord RPC...');
    try {
        rpc = new DiscordRPC.Client({ transport: 'ipc' });

        rpc.on('disconnected', function() {
            log('RPC disconnected');
            rpc          = null;
            currentChId  = null;
            state        = { connected: false, channelName: '', members: [] };
            lastPushed   = '';
            pushStates();
            scheduleReconnect();
        });

        rpc.on('ready', async function() {
            var user = rpc.user ? rpc.user.username : '?';
            log('RPC ready! User:', user);
            state.connected = true;

            // Subscribe to channel select
            try {
                await rpc.subscribe('VOICE_CHANNEL_SELECT', {});
                log('Subscribed to VOICE_CHANNEL_SELECT');
            } catch (e) {
                log('VOICE_CHANNEL_SELECT subscribe error:', e.message);
            }

            // Load current channel
            await refreshChannel();
        });

        rpc.on('VOICE_CHANNEL_SELECT', async function(data) {
            log('VOICE_CHANNEL_SELECT: channel_id=' + (data.channel_id || 'null'));
            if (data.channel_id) {
                // Joined or changed channel
                await refreshChannel();
            } else {
                // Left voice
                if (currentChId) {
                    var EVENTS = ['VOICE_STATE_CREATE', 'VOICE_STATE_UPDATE', 'VOICE_STATE_DELETE'];
                    for (var i = 0; i < EVENTS.length; i++) {
                        try { await rpc.unsubscribe(EVENTS[i], { channel_id: currentChId }); } catch {}
                    }
                }
                currentChId       = null;
                state.channelName = '';
                state.members     = [];
                if (tpReady) TPClient.stateUpdate(S_ERROR, '');
                pushStates();
            }
        });

        rpc.on('VOICE_STATE_CREATE', async function(data) {
            var who = data && data.user ? s(data.user.username) : '?';
            log('VOICE_STATE_CREATE:', who);
            await refreshChannel();
        });

        rpc.on('VOICE_STATE_UPDATE', async function(data) {
            var who = data && data.user ? s(data.user.username) : '?';
            log('VOICE_STATE_UPDATE:', who);
            await refreshChannel();
        });

        rpc.on('VOICE_STATE_DELETE', async function(data) {
            var who = data && data.user ? s(data.user.username) : '?';
            log('VOICE_STATE_DELETE:', who);
            await refreshChannel();
        });

        await rpc.login({
            clientId:     settings.clientId,
            clientSecret: settings.clientSecret,
            scopes:       ['identify', 'rpc', 'rpc.voice.read'],
            redirectUri:  'http://127.0.0.1',
            prompt:       'none'
        });
        log('RPC login OK');

    } catch (e) {
        log('RPC connect failed:', e.message || String(e));
        rpc             = null;
        state.connected = false;
        lastPushed      = '';
        pushStates();
        setError(s(e.message));
        scheduleReconnect();
    }
}

function scheduleReconnect() {
    if (reconnectTimer) return;
    log('Reconnect in 10s...');
    reconnectTimer = setTimeout(function() { reconnectTimer = null; connectRPC(); }, 10000);
}

async function disconnectRPC() {
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
    if (!rpc) return;
    try { await rpc.destroy(); } catch {}
    rpc = null;
}

// ── Touch Portal events ──────────────────────────────────────────────────────

TPClient.on('Info', function(data) {
    log('TP Info received - pairing done');
    tpReady = true;

    if (data && data.settings) {
        var v = settingsToObj(data.settings);
        if (v['Application ID'] && s(v['Application ID']).trim())
            settings.clientId     = s(v['Application ID']).trim();
        if (v['Client Secret']  && s(v['Client Secret']).trim())
            settings.clientSecret = s(v['Client Secret']).trim();
    }
    log('clientId:', settings.clientId, '| secret:', settings.clientSecret ? 'SET' : 'MISSING');

    pushStates();
    if (settings.clientId && settings.clientSecret && !rpc) connectRPC();
});

TPClient.on('Settings', async function(data) {
    try {
        var v    = settingsToObj(data);
        var prev = { clientId: settings.clientId, clientSecret: settings.clientSecret };

        if (v['Application ID'] && s(v['Application ID']).trim())
            settings.clientId     = s(v['Application ID']).trim();
        if (v['Client Secret'])
            settings.clientSecret = s(v['Client Secret']).trim();

        log('Settings updated - clientId:', settings.clientId);

        if (prev.clientId !== settings.clientId || prev.clientSecret !== settings.clientSecret) {
            log('Credentials changed, reconnecting...');
            await disconnectRPC();
        }
        if (settings.clientId && settings.clientSecret && !rpc) connectRPC();
    } catch (e) { log('Settings error:', e.message); }
});

TPClient.on('Action', async function(msg) {
    try {
        if (msg && msg.actionId === A_REFRESH) {
            log('Manual refresh requested');
            lastPushed = '';
            await refreshChannel();
        }
    } catch (e) { log('Action error:', e.message); }
});

TPClient.on('ClosePlugin', async function() {
    log('ClosePlugin - shutting down');
    try { await disconnectRPC(); } catch {}
    process.exit(0);
});

log('=== WalhallaDiscordChannelViewer starting ===');
TPClient.connect({ pluginId: pluginId });
