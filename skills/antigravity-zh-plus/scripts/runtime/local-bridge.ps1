[CmdletBinding()]
param(
    [int]$Port = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$BridgeRuntimeVersion = '1.3.0'
$ToolDir = $PSScriptRoot
$ConfigPath = Join-Path $ToolDir 'thought-config.json'
$StateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'antigravity-hans-guard'
if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) {
    New-Item -Path $StateDir -ItemType Directory -Force | Out-Null
}
$LogPath = Join-Path $StateDir 'launcher.log'
$BridgeEndpointFile = Join-Path $StateDir 'bridge-endpoint.json'
$BridgeStopSignalFile = Join-Path $StateDir 'bridge-stop.signal'

$BridgeMutexName = 'Local\AntigravityHansBridgeMutex'
$BridgeStopEventName = 'Local\AntigravityHansBridgeStopEvent'
$LauncherMutexName = 'Local\AntigravityHansLauncherMutex'

function Write-BridgeLog {
    param([string]$Message)
    try {
        $line = "[{0}] [LocalBridge] {1}{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($LogPath, $line, [Text.Encoding]::UTF8)
    } catch {}
}

function New-RandomHexToken {
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
    try {
        $rng.GetBytes($bytes)
        return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    } finally {
        $rng.Dispose()
    }
}

function Test-BridgeStopRequested {
    param([System.Threading.EventWaitHandle]$CancelEvent)
    if (Test-Path -LiteralPath $BridgeStopSignalFile -PathType Leaf) { return $true }
    if ($null -ne $CancelEvent) {
        try { if ($CancelEvent.WaitOne(0)) { return $true } } catch {}
    }
    return $false
}

function Ensure-BridgeConfigValues {
    param([System.Threading.EventWaitHandle]$CancelEvent)
    $lchMutex = New-Object System.Threading.Mutex($false, $LauncherMutexName)
    $locked = $false
    try {
        $handles = if ($null -ne $CancelEvent) {
            [System.Threading.WaitHandle[]]@($lchMutex, $CancelEvent)
        } else {
            [System.Threading.WaitHandle[]]@($lchMutex)
        }
        try {
            $idx = [System.Threading.WaitHandle]::WaitAny($handles, 10000)
            if ($idx -eq 0) { $locked = $true }
            elseif ($idx -eq 1) { return $null }
        } catch [System.Threading.AbandonedMutexException] {
            $locked = $true
        }
        if (-not $locked) {
            throw 'Timed out acquiring LauncherMutex for bridge config initialization.'
        }
        if (Test-BridgeStopRequested -CancelEvent $CancelEvent) {
            return $null
        }

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $cfg = [ordered]@{
            enabled      = $true
            provider     = 'auto'
            bridgePort   = 47831
            bridgeToken  = ''
            llmApiKey    = ''
            llmBaseUrl   = 'https://open.bigmodel.cn/api/paas/v4/chat/completions'
            llmModel     = 'glm-4-flash'
            geminiApiKey = ''
            geminiModel  = 'gemini-3.5-flash-lite'
        }
        $dirty = $false
        if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
            $raw = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json
                if ($null -ne $parsed) {
                    foreach ($p in $parsed.PSObject.Properties) {
                        $cfg[$p.Name] = $p.Value
                    }
                }
            }
        } else {
            $dirty = $true
        }

        $curPort = 0
        if ($null -ne $cfg['bridgePort'] -and [int]::TryParse([string]$cfg['bridgePort'], [ref]$curPort) -and $curPort -ge 1024 -and $curPort -le 65535) {
            $cfg['bridgePort'] = $curPort
        } else {
            $cfg['bridgePort'] = 47831
            $dirty = $true
        }

        $curToken = [string]$cfg['bridgeToken']
        if ([string]::IsNullOrWhiteSpace($curToken) -or $curToken.Trim().Length -lt 24) {
            $cfg['bridgeToken'] = New-RandomHexToken
            $dirty = $true
        } else {
            $cfg['bridgeToken'] = $curToken.Trim()
        }

        if ($dirty) {
            $tmp = "$ConfigPath.tmp.$PID.$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
            try {
                [IO.File]::WriteAllText($tmp, ($cfg | ConvertTo-Json -Depth 6), $utf8NoBom)
                if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
                    [IO.File]::Replace($tmp, $ConfigPath, [NullString]::Value)
                } else {
                    [IO.File]::Move($tmp, $ConfigPath)
                }
            } finally {
                if (Test-Path -LiteralPath $tmp -PathType Leaf) {
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
            }
        }
        return $cfg
    } finally {
        if ($locked) {
            try { $lchMutex.ReleaseMutex() } catch {}
        }
        $lchMutex.Dispose()
    }
}

if (-not ('AgyZhPlus.LocalTranslationBridge' -as [type])) {
    $csharpSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace AgyZhPlus
{
    public sealed class BridgeConfigSnapshot
    {
        public bool Enabled = true;
        public string Provider = "auto";
        public string BridgeToken = "";
        public string LlmApiKey = "";
        public string LlmBaseUrl = "https://open.bigmodel.cn/api/paas/v4/chat/completions";
        public string LlmModel = "glm-4-flash";
        public string GeminiApiKey = "";
        public string GeminiModel = "gemini-3.5-flash-lite";
    }

    public sealed class LocalTranslationBridge : IDisposable
    {
        private static readonly Regex AllowedOriginRegex = new Regex(
            @"^(?:https?://(?:127\.0\.0\.1|localhost)(?::\d+)?|vscode-file://[^\s]*)$",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        private readonly string _configPath;
        private readonly TcpListener _listener;
        private readonly SemaphoreSlim _connectionGate;
        private readonly SemaphoreSlim _concurrencyGate;
        private readonly HttpClient _directClient;
        private readonly HttpClient _defaultClient;
        private readonly CancellationTokenSource _shutdownCts;
        private readonly object _cfgLock = new object();

        private DateTime _lastCfgWriteUtc = DateTime.MinValue;
        private BridgeConfigSnapshot _cachedCfg = new BridgeConfigSnapshot();
        private volatile bool _stopped;

        public int BoundPort { get; private set; }

        public LocalTranslationBridge(string configPath, int preferredPort)
        {
            _configPath = configPath;
            _connectionGate = new SemaphoreSlim(16, 16);
            _concurrencyGate = new SemaphoreSlim(4, 4);
            _shutdownCts = new CancellationTokenSource();

            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;

            HttpClientHandler directHandler = new HttpClientHandler();
            directHandler.UseProxy = false;
            directHandler.UseCookies = false;
            directHandler.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            _directClient = new HttpClient(directHandler);
            _directClient.Timeout = TimeSpan.FromSeconds(30);

            HttpClientHandler defaultHandler = new HttpClientHandler();
            defaultHandler.UseProxy = true;
            defaultHandler.UseCookies = false;
            defaultHandler.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            _defaultClient = new HttpClient(defaultHandler);
            _defaultClient.Timeout = TimeSpan.FromSeconds(30);

            _listener = BindLoopbackWithFallback(preferredPort);
            BoundPort = ((IPEndPoint)_listener.LocalEndpoint).Port;
            ReloadConfigIfNeeded(true);
        }

        private static TcpListener BindLoopbackWithFallback(int preferredPort)
        {
            List<int> candidates = new List<int>();
            if (preferredPort >= 1024 && preferredPort <= 65535)
            {
                candidates.Add(preferredPort);
            }
            for (int p = 47831; p <= 47839; p++)
            {
                if (!candidates.Contains(p)) candidates.Add(p);
            }

            SocketException lastEx = null;
            foreach (int port in candidates)
            {
                TcpListener candidate = new TcpListener(IPAddress.Loopback, port);
                try
                {
                    candidate.Server.ExclusiveAddressUse = true;
                    candidate.Start(32);
                    return candidate;
                }
                catch (SocketException ex)
                {
                    lastEx = ex;
                    try { candidate.Stop(); } catch { }
                }
            }
            if (lastEx != null) throw lastEx;
            throw new InvalidOperationException("Unable to bind loopback translation bridge.");
        }

        public void StartAcceptLoop()
        {
            Task.Run((Func<Task>)AcceptLoopAsync);
        }

        private async Task AcceptLoopAsync()
        {
            while (!_stopped)
            {
                TcpClient client = null;
                try
                {
                    client = await _listener.AcceptTcpClientAsync().ConfigureAwait(false);
                    if (_stopped || !_connectionGate.Wait(0))
                    {
                        try { client.Close(); } catch { }
                        continue;
                    }
                    Task ignored = HandleBoundedClientAsync(client);
                }
                catch (ObjectDisposedException)
                {
                    if (client != null) { try { client.Close(); } catch { } }
                    break;
                }
                catch (SocketException)
                {
                    if (client != null) { try { client.Close(); } catch { } }
                    if (_stopped) break;
                }
                catch
                {
                    if (client != null) { try { client.Close(); } catch { } }
                }
            }
        }

        private async Task HandleBoundedClientAsync(TcpClient client)
        {
            try
            {
                await HandleClientAsync(client).ConfigureAwait(false);
            }
            catch
            {
            }
            finally
            {
                try { _connectionGate.Release(); } catch { }
            }
        }

        private static bool IsSafeLlmEndpointUri(string rawUrl, out Uri parsedUri)
        {
            parsedUri = null;
            if (string.IsNullOrWhiteSpace(rawUrl)) return false;
            if (!Uri.TryCreate(rawUrl.Trim(), UriKind.Absolute, out parsedUri)) return false;
            if (string.Equals(parsedUri.Scheme, "https", StringComparison.OrdinalIgnoreCase)) return true;
            if (string.Equals(parsedUri.Scheme, "http", StringComparison.OrdinalIgnoreCase) &&
                (string.Equals(parsedUri.Host, "127.0.0.1", StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(parsedUri.Host, "localhost", StringComparison.OrdinalIgnoreCase)))
            {
                return true;
            }
            return false;
        }

        private BridgeConfigSnapshot ReloadConfigIfNeeded(bool force)
        {
            lock (_cfgLock)
            {
                try
                {
                    if (!File.Exists(_configPath)) return _cachedCfg;
                    DateTime wt = File.GetLastWriteTimeUtc(_configPath);
                    if (!force && wt == _lastCfgWriteUtc) return _cachedCfg;

                    string raw = File.ReadAllText(_configPath, Encoding.UTF8);
                    JavaScriptSerializer ser = new JavaScriptSerializer();
                    ser.MaxJsonLength = 262144;
                    Dictionary<string, object> dict = ser.DeserializeObject(raw) as Dictionary<string, object>;
                    if (dict != null)
                    {
                        BridgeConfigSnapshot snap = new BridgeConfigSnapshot();
                        snap.Enabled = ReadBool(dict, "enabled", true);
                        snap.Provider = ReadStr(dict, "provider", "auto").ToLowerInvariant();
                        snap.BridgeToken = ReadStr(dict, "bridgeToken", "");
                        snap.LlmApiKey = ReadStr(dict, "llmApiKey", "");
                        snap.LlmBaseUrl = ReadStr(dict, "llmBaseUrl", "https://open.bigmodel.cn/api/paas/v4/chat/completions");
                        snap.LlmModel = ReadStr(dict, "llmModel", "glm-4-flash");
                        snap.GeminiApiKey = ReadStr(dict, "geminiApiKey", "");
                        snap.GeminiModel = ReadStr(dict, "geminiModel", "gemini-3.5-flash-lite");
                        _cachedCfg = snap;
                        _lastCfgWriteUtc = wt;
                    }
                }
                catch
                {
                }
                return _cachedCfg;
            }
        }

        private static string ReadStr(Dictionary<string, object> d, string key, string fallback)
        {
            object v;
            if (d.TryGetValue(key, out v) && v != null)
            {
                string s = Convert.ToString(v).Trim();
                return s.Length > 0 ? s : fallback;
            }
            return fallback;
        }

        private static bool ReadBool(Dictionary<string, object> d, string key, bool fallback)
        {
            object v;
            if (d.TryGetValue(key, out v) && v != null)
            {
                if (v is bool) return (bool)v;
                string s = Convert.ToString(v).Trim();
                if (string.Equals(s, "true", StringComparison.OrdinalIgnoreCase)) return true;
                if (string.Equals(s, "false", StringComparison.OrdinalIgnoreCase)) return false;
            }
            return fallback;
        }

        private static bool FixedTimeEqualsAscii(string a, string b)
        {
            if (string.IsNullOrEmpty(a) || string.IsNullOrEmpty(b)) return false;
            byte[] ba = Encoding.UTF8.GetBytes(a);
            byte[] bb = Encoding.UTF8.GetBytes(b);
            if (ba.Length != bb.Length) return false;
            int diff = 0;
            for (int i = 0; i < ba.Length; i++)
            {
                diff |= (ba[i] ^ bb[i]);
            }
            return diff == 0;
        }

        private static int FindHeaderEnd(byte[] buffer, int length)
        {
            for (int i = 0; i <= length - 4; i++)
            {
                if (buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10)
                {
                    return i;
                }
            }
            return -1;
        }

        private async Task HandleClientAsync(TcpClient client)
        {
            using (client)
            {
                NetworkStream stream = client.GetStream();

                byte[] headerBuf = new byte[16384];
                int totalRead = 0;
                int headerEnd = -1;

                while (totalRead < headerBuf.Length)
                {
                    int n = await ReadWithTimeoutAsync(client, stream, headerBuf, totalRead, headerBuf.Length - totalRead, 5000, _shutdownCts.Token).ConfigureAwait(false);
                    if (n <= 0) return;
                    totalRead += n;
                    headerEnd = FindHeaderEnd(headerBuf, totalRead);
                    if (headerEnd >= 0) break;
                }

                if (headerEnd < 0)
                {
                    await WriteJsonResponseAsync(client, stream, 400, null, "{\"ok\":false,\"error\":\"Header too large\"}").ConfigureAwait(false);
                    return;
                }

                string headerText = Encoding.ASCII.GetString(headerBuf, 0, headerEnd);
                string[] lines = headerText.Split(new string[] { "\r\n" }, StringSplitOptions.None);
                if (lines.Length == 0) return;

                string[] reqParts = lines[0].Split(' ');
                if (reqParts.Length < 2) return;
                string method = reqParts[0].ToUpperInvariant();
                string rawPath = reqParts[1];
                int qPos = rawPath.IndexOf('?');
                string path = qPos >= 0 ? rawPath.Substring(0, qPos) : rawPath;

                Dictionary<string, string> headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int i = 1; i < lines.Length; i++)
                {
                    int colon = lines[i].IndexOf(':');
                    if (colon > 0)
                    {
                        string hk = lines[i].Substring(0, colon).Trim();
                        string hv = lines[i].Substring(colon + 1).Trim();
                        headers[hk] = hv;
                    }
                }

                string origin = headers.ContainsKey("Origin") ? headers["Origin"] : "";
                bool isLocalCli = headers.ContainsKey("X-Agy-Local-Cli") && headers["X-Agy-Local-Cli"] == "1";
                string corsOriginToEcho = null;

                if (!string.IsNullOrEmpty(origin))
                {
                    if (!AllowedOriginRegex.IsMatch(origin))
                    {
                        await WriteJsonResponseAsync(client, stream, 403, null, "{\"ok\":false,\"error\":\"Forbidden origin\"}").ConfigureAwait(false);
                        return;
                    }
                    corsOriginToEcho = origin;
                }
                else if (!isLocalCli && method != "GET")
                {
                    await WriteJsonResponseAsync(client, stream, 403, null, "{\"ok\":false,\"error\":\"Missing origin\"}").ConfigureAwait(false);
                    return;
                }

                if (method == "OPTIONS")
                {
                    await WriteOptionsResponseAsync(client, stream, corsOriginToEcho).ConfigureAwait(false);
                    return;
                }

                if (method == "GET" && path == "/health")
                {
                    await WriteJsonResponseAsync(client, stream, 200, corsOriginToEcho, "{\"ok\":true,\"port\":" + BoundPort + "}").ConfigureAwait(false);
                    return;
                }

                if (method != "POST" || path != "/translate")
                {
                    await WriteJsonResponseAsync(client, stream, 404, corsOriginToEcho, "{\"ok\":false,\"error\":\"Not found\"}").ConfigureAwait(false);
                    return;
                }

                if (headers.ContainsKey("Transfer-Encoding"))
                {
                    await WriteJsonResponseAsync(client, stream, 400, corsOriginToEcho, "{\"ok\":false,\"error\":\"Chunked encoding not supported\"}").ConfigureAwait(false);
                    return;
                }

                int contentLength = 0;
                if (!headers.ContainsKey("Content-Length") || !int.TryParse(headers["Content-Length"], out contentLength) || contentLength <= 0 || contentLength > 65536)
                {
                    await WriteJsonResponseAsync(client, stream, 413, corsOriginToEcho, "{\"ok\":false,\"error\":\"Invalid Content-Length\"}").ConfigureAwait(false);
                    return;
                }

                byte[] bodyBytes = new byte[contentLength];
                int bodyStart = headerEnd + 4;
                int alreadyReadBody = totalRead - bodyStart;
                if (alreadyReadBody > 0)
                {
                    int toCopy = Math.Min(alreadyReadBody, contentLength);
                    Buffer.BlockCopy(headerBuf, bodyStart, bodyBytes, 0, toCopy);
                }

                int offset = Math.Max(0, Math.Min(alreadyReadBody, contentLength));
                while (offset < contentLength)
                {
                    int n = await ReadWithTimeoutAsync(client, stream, bodyBytes, offset, contentLength - offset, 5000, _shutdownCts.Token).ConfigureAwait(false);
                    if (n <= 0)
                    {
                        await WriteJsonResponseAsync(client, stream, 400, corsOriginToEcho, "{\"ok\":false,\"error\":\"Unexpected EOF\"}").ConfigureAwait(false);
                        return;
                    }
                    offset += n;
                }

                BridgeConfigSnapshot cfg = ReloadConfigIfNeeded(false);
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                serializer.MaxJsonLength = 262144;

                Dictionary<string, object> payload = null;
                bool jsonMalformed = false;
                try
                {
                    string bodyStr = Encoding.UTF8.GetString(bodyBytes);
                    payload = serializer.DeserializeObject(bodyStr) as Dictionary<string, object>;
                }
                catch
                {
                    jsonMalformed = true;
                }

                if (jsonMalformed || payload == null)
                {
                    await WriteJsonResponseAsync(client, stream, 400, corsOriginToEcho, "{\"ok\":false,\"error\":\"Malformed JSON\"}").ConfigureAwait(false);
                    return;
                }

                string headerToken = headers.ContainsKey("X-Agy-Bridge-Token") ? headers["X-Agy-Bridge-Token"] : "";
                string bodyToken = ReadStr(payload, "token", "");
                string candidateToken = !string.IsNullOrEmpty(bodyToken) ? bodyToken : headerToken;

                if (!FixedTimeEqualsAscii(candidateToken, cfg.BridgeToken))
                {
                    await WriteJsonResponseAsync(client, stream, 401, corsOriginToEcho, "{\"ok\":false,\"error\":\"Invalid bridge token\"}").ConfigureAwait(false);
                    return;
                }

                if (!cfg.Enabled)
                {
                    await WriteJsonResponseAsync(client, stream, 200, corsOriginToEcho, "{\"ok\":false,\"error\":\"Disabled\"}").ConfigureAwait(false);
                    return;
                }

                List<string> texts = ExtractStringList(payload, "texts");
                if (texts == null || texts.Count == 0 || texts.Count > 12)
                {
                    await WriteJsonResponseAsync(client, stream, 400, corsOriginToEcho, "{\"ok\":false,\"error\":\"Invalid texts batch count\"}").ConfigureAwait(false);
                    return;
                }

                int totalChars = 0;
                for (int i = 0; i < texts.Count; i++)
                {
                    if (texts[i] == null || texts[i].Length == 0 || texts[i].Length > 4000)
                    {
                        await WriteJsonResponseAsync(client, stream, 400, corsOriginToEcho, "{\"ok\":false,\"error\":\"Invalid paragraph length\"}").ConfigureAwait(false);
                        return;
                    }
                    totalChars += texts[i].Length;
                }
                if (totalChars > 12000)
                {
                    await WriteJsonResponseAsync(client, stream, 413, corsOriginToEcho, "{\"ok\":false,\"error\":\"Batch too large\"}").ConfigureAwait(false);
                    return;
                }

                bool entered = await _concurrencyGate.WaitAsync(3000, _shutdownCts.Token).ConfigureAwait(false);
                if (!entered)
                {
                    await WriteJsonResponseAsync(client, stream, 429, corsOriginToEcho, "{\"ok\":false,\"error\":\"Bridge busy\"}").ConfigureAwait(false);
                    return;
                }

                string okJson = null;
                string errJson = null;
                try
                {
                    Tuple<string, List<string>> result = await TranslateBatchWithFallbackAsync(cfg, texts, serializer, _shutdownCts.Token).ConfigureAwait(false);
                    Dictionary<string, object> respObj = new Dictionary<string, object>();
                    respObj["ok"] = true;
                    respObj["engine"] = result.Item1;
                    respObj["translations"] = result.Item2;
                    okJson = serializer.Serialize(respObj);
                }
                catch (Exception ex)
                {
                    Dictionary<string, object> errObj = new Dictionary<string, object>();
                    errObj["ok"] = false;
                    errObj["error"] = ex.Message;
                    errJson = serializer.Serialize(errObj);
                }
                finally
                {
                    _concurrencyGate.Release();
                }

                if (okJson != null)
                {
                    await WriteJsonResponseAsync(client, stream, 200, corsOriginToEcho, okJson).ConfigureAwait(false);
                }
                else
                {
                    await WriteJsonResponseAsync(client, stream, 502, corsOriginToEcho, errJson).ConfigureAwait(false);
                }
            }
        }

        private static async Task<int> ReadWithTimeoutAsync(TcpClient client, NetworkStream stream, byte[] buf, int offset, int count, int timeoutMs, CancellationToken shutdownCt)
        {
            using (CancellationTokenSource timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(shutdownCt))
            {
                timeoutCts.CancelAfter(timeoutMs);
                Task<int> readTask = stream.ReadAsync(buf, offset, count, timeoutCts.Token);
                Task delayTask = Task.Delay(timeoutMs, timeoutCts.Token);
                Task finished = await Task.WhenAny(readTask, delayTask).ConfigureAwait(false);
                if (finished != readTask)
                {
                    try { client.Close(); } catch { }
                    throw new TimeoutException("Socket read timed out.");
                }
                return await readTask.ConfigureAwait(false);
            }
        }

        private static async Task WriteBytesWithTimeoutAsync(TcpClient client, NetworkStream stream, byte[] data, int timeoutMs, CancellationToken shutdownCt)
        {
            using (CancellationTokenSource timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(shutdownCt))
            {
                timeoutCts.CancelAfter(timeoutMs);
                Task writeTask = stream.WriteAsync(data, 0, data.Length, timeoutCts.Token);
                Task delayTask = Task.Delay(timeoutMs, timeoutCts.Token);
                Task finished = await Task.WhenAny(writeTask, delayTask).ConfigureAwait(false);
                if (finished != writeTask)
                {
                    try { client.Close(); } catch { }
                    throw new TimeoutException("Socket write timed out.");
                }
                await writeTask.ConfigureAwait(false);
            }
        }

        private static List<string> ExtractStringList(Dictionary<string, object> obj, string key)
        {
            object raw;
            if (!obj.TryGetValue(key, out raw) || raw == null) return null;
            IEnumerable enumerable = raw as IEnumerable;
            if (enumerable == null || raw is string) return null;
            List<string> list = new List<string>();
            foreach (object item in enumerable)
            {
                list.Add(item == null ? "" : Convert.ToString(item));
            }
            return list;
        }

        private async Task<Tuple<string, List<string>>> TranslateBatchWithFallbackAsync(
            BridgeConfigSnapshot cfg,
            List<string> texts,
            JavaScriptSerializer ser,
            CancellationToken shutdownCt)
        {
            string prov = cfg.Provider;
            bool hasLlmKey = !string.IsNullOrWhiteSpace(cfg.LlmApiKey);
            bool hasGemKey = !string.IsNullOrWhiteSpace(cfg.GeminiApiKey);

            if (prov == "local-llm")
            {
                string localUrl = (string.IsNullOrWhiteSpace(cfg.LlmBaseUrl) || cfg.LlmBaseUrl.IndexOf("bigmodel.cn", StringComparison.OrdinalIgnoreCase) >= 0)
                    ? "http://127.0.0.1:11434/v1/chat/completions"
                    : cfg.LlmBaseUrl;
                string localModel = (string.IsNullOrWhiteSpace(cfg.LlmModel) || string.Equals(cfg.LlmModel, "glm-4-flash", StringComparison.OrdinalIgnoreCase))
                    ? "qwen2.5:3b"
                    : cfg.LlmModel;
                Uri localUri;
                if (IsSafeLlmEndpointUri(localUrl, out localUri))
                {
                    try
                    {
                        using (CancellationTokenSource localCts = CancellationTokenSource.CreateLinkedTokenSource(shutdownCt))
                        {
                            localCts.CancelAfter(20000);
                            List<string> tr = await TranslateViaOpenAiCompatAsync(
                                _directClient,
                                localUri.AbsoluteUri,
                                cfg.LlmApiKey,
                                localModel,
                                texts,
                                ser,
                                localCts.Token).ConfigureAwait(false);
                            return Tuple.Create("local-llm:" + localModel, tr);
                        }
                    }
                    catch
                    {
                    }
                }
            }
            else if (prov == "zhipu" || (prov == "auto" && hasLlmKey && cfg.LlmBaseUrl.IndexOf("bigmodel.cn", StringComparison.OrdinalIgnoreCase) >= 0))
            {
                if (hasLlmKey)
                {
                    try
                    {
                        using (CancellationTokenSource llmCts = CancellationTokenSource.CreateLinkedTokenSource(shutdownCt))
                        {
                            llmCts.CancelAfter(10000);
                            List<string> tr = await TranslateViaOpenAiCompatAsync(
                                _directClient,
                                "https://open.bigmodel.cn/api/paas/v4/chat/completions",
                                cfg.LlmApiKey,
                                string.IsNullOrWhiteSpace(cfg.LlmModel) ? "glm-4-flash" : cfg.LlmModel,
                                texts,
                                ser,
                                llmCts.Token).ConfigureAwait(false);
                            return Tuple.Create("zhipu:" + cfg.LlmModel, tr);
                        }
                    }
                    catch
                    {
                    }
                }
            }
            else if (prov == "openai-compat" || (prov == "auto" && hasLlmKey))
            {
                Uri u;
                if (hasLlmKey && IsSafeLlmEndpointUri(cfg.LlmBaseUrl, out u))
                {
                    bool isDomesticOrLocal =
                        u.Host.EndsWith(".cn", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(u.Host, "127.0.0.1", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(u.Host, "localhost", StringComparison.OrdinalIgnoreCase) ||
                        u.Host.IndexOf("deepseek.com", StringComparison.OrdinalIgnoreCase) >= 0 ||
                        u.Host.IndexOf("aliyuncs.com", StringComparison.OrdinalIgnoreCase) >= 0;
                    HttpClient primary = isDomesticOrLocal ? _directClient : _defaultClient;
                    try
                    {
                        using (CancellationTokenSource llmCts = CancellationTokenSource.CreateLinkedTokenSource(shutdownCt))
                        {
                            llmCts.CancelAfter(10000);
                            List<string> tr = await TranslateViaOpenAiCompatAsync(
                                primary,
                                u.AbsoluteUri,
                                cfg.LlmApiKey,
                                string.IsNullOrWhiteSpace(cfg.LlmModel) ? "Qwen/Qwen2.5-7B-Instruct" : cfg.LlmModel,
                                texts,
                                ser,
                                llmCts.Token).ConfigureAwait(false);
                            return Tuple.Create("openai-compat:" + cfg.LlmModel, tr);
                        }
                    }
                    catch
                    {
                    }
                }
            }
            else if (prov == "gemini" || (prov == "auto" && hasGemKey))
            {
                if (hasGemKey)
                {
                    try
                    {
                        using (CancellationTokenSource gemCts = CancellationTokenSource.CreateLinkedTokenSource(shutdownCt))
                        {
                            gemCts.CancelAfter(10000);
                            List<string> tr = await TranslateViaGeminiBatchAsync(cfg.GeminiApiKey, cfg.GeminiModel, texts, ser, gemCts.Token).ConfigureAwait(false);
                            return Tuple.Create("gemini:" + cfg.GeminiModel, tr);
                        }
                    }
                    catch
                    {
                    }
                }
            }

            using (CancellationTokenSource directCts = CancellationTokenSource.CreateLinkedTokenSource(shutdownCt))
            {
                directCts.CancelAfter(7500);
                List<string> directRes = await TranslateViaTranSmartDirectAsync(texts, ser, directCts.Token).ConfigureAwait(false);
                return Tuple.Create("transmart-direct", directRes);
            }
        }

        private async Task<List<string>> TranslateViaTranSmartDirectAsync(List<string> texts, JavaScriptSerializer ser, CancellationToken ct)
        {
            string clientKey = "browser-chrome-122.0.0-Windows_10-agy-" + Guid.NewGuid().ToString("N").Substring(0, 10);
            Dictionary<string, object> reqBody = new Dictionary<string, object>();
            Dictionary<string, object> header = new Dictionary<string, object>();
            header["fn"] = "auto_translation";
            header["client_key"] = clientKey;
            reqBody["header"] = header;
            reqBody["type"] = "plain";
            reqBody["model_category"] = "normal";

            Dictionary<string, object> source = new Dictionary<string, object>();
            source["lang"] = "en";
            source["text_list"] = texts;
            reqBody["source"] = source;

            Dictionary<string, object> target = new Dictionary<string, object>();
            target["lang"] = "zh";
            reqBody["target"] = target;

            string json = ser.Serialize(reqBody);
            using (HttpRequestMessage msg = new HttpRequestMessage(HttpMethod.Post, "https://transmart.qq.com/api/imt"))
            {
                msg.Content = new StringContent(json, Encoding.UTF8, "application/json");
                msg.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
                using (HttpResponseMessage resp = await _directClient.SendAsync(msg, ct).ConfigureAwait(false))
                {
                    if (!resp.IsSuccessStatusCode)
                    {
                        throw new InvalidOperationException("TranSmart HTTP " + (int)resp.StatusCode);
                    }
                    string respStr = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    Dictionary<string, object> data = ser.DeserializeObject(respStr) as Dictionary<string, object>;
                    if (data == null) throw new InvalidOperationException("Empty TranSmart response");
                    List<string> outList = ExtractStringList(data, "auto_translation");
                    if (outList == null || outList.Count != texts.Count)
                    {
                        throw new InvalidOperationException("TranSmart output count mismatch");
                    }
                    return outList;
                }
            }
        }

        private async Task<List<string>> TranslateViaOpenAiCompatAsync(
            HttpClient client,
            string endpointUrl,
            string apiKey,
            string model,
            List<string> texts,
            JavaScriptSerializer ser,
            CancellationToken ct)
        {
            Uri checkedUri;
            if (!IsSafeLlmEndpointUri(endpointUrl, out checkedUri))
            {
                throw new InvalidOperationException("Refusing insecure non-HTTPS remote LLM URL.");
            }

            string sysPrompt =
                "你是专业AI技术思考流中英翻译器。输入是一个JSON字符串数组，请将每一项英文准确、简练地译为简体中文。" +
                "必须100%原封不动保留所有形如 __C0__、__K1__ 的双下划线占位符（严禁增删或改写字母编号）。" +
                "只输出严格合法的JSON数组（如 [\"译文1\",\"译文2\"]），数组长度必须与输入完全一致，不要输出Markdown代码块或任何多余解释。";

            string userJson = ser.Serialize(texts);
            Dictionary<string, object> body = new Dictionary<string, object>();
            body["model"] = model;
            body["temperature"] = 0.1;
            List<Dictionary<string, string>> messages = new List<Dictionary<string, string>>();
            Dictionary<string, string> mSys = new Dictionary<string, string>();
            mSys["role"] = "system";
            mSys["content"] = sysPrompt;
            messages.Add(mSys);
            Dictionary<string, string> mUsr = new Dictionary<string, string>();
            mUsr["role"] = "user";
            mUsr["content"] = userJson;
            messages.Add(mUsr);
            body["messages"] = messages;

            using (HttpRequestMessage req = new HttpRequestMessage(HttpMethod.Post, checkedUri))
            {
                if (!string.IsNullOrWhiteSpace(apiKey))
                {
                    req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + apiKey);
                }
                req.Content = new StringContent(ser.Serialize(body), Encoding.UTF8, "application/json");
                using (HttpResponseMessage resp = await client.SendAsync(req, ct).ConfigureAwait(false))
                {
                    if (!resp.IsSuccessStatusCode)
                    {
                        throw new InvalidOperationException("LLM HTTP " + (int)resp.StatusCode);
                    }
                    string raw = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    Dictionary<string, object> parsed = ser.DeserializeObject(raw) as Dictionary<string, object>;
                    string content = ExtractChatCompletionText(parsed);
                    List<string> arr = ParseJsonArrayFromModelText(content, ser);
                    if (arr == null || arr.Count != texts.Count)
                    {
                        throw new InvalidOperationException("LLM array count mismatch");
                    }
                    return arr;
                }
            }
        }

        private async Task<List<string>> TranslateViaGeminiBatchAsync(
            string apiKey,
            string model,
            List<string> texts,
            JavaScriptSerializer ser,
            CancellationToken ct)
        {
            string sysPrompt =
                "将输入的JSON英文字符串数组逐项准确简练地译为简体中文，原封不动保留所有形如 __C0__ 的双下划线占位符。" +
                "只输出等长的JSON字符串数组（如 [\"译文1\",\"译文2\"]），不要Markdown代码块或解释。";

            Dictionary<string, object> body = new Dictionary<string, object>();
            body["model"] = string.IsNullOrWhiteSpace(model) ? "gemini-3.5-flash-lite" : model;
            body["store"] = false;
            Dictionary<string, object> genCfg = new Dictionary<string, object>();
            genCfg["thinking_level"] = "minimal";
            body["generation_config"] = genCfg;
            body["system_instruction"] = sysPrompt;
            body["input"] = ser.Serialize(texts);

            using (HttpRequestMessage req = new HttpRequestMessage(HttpMethod.Post, "https://generativelanguage.googleapis.com/v1beta/interactions"))
            {
                req.Headers.TryAddWithoutValidation("x-goog-api-key", apiKey);
                req.Headers.TryAddWithoutValidation("Api-Revision", "2026-05-20");
                req.Content = new StringContent(ser.Serialize(body), Encoding.UTF8, "application/json");
                using (HttpResponseMessage resp = await _defaultClient.SendAsync(req, ct).ConfigureAwait(false))
                {
                    if (!resp.IsSuccessStatusCode)
                    {
                        throw new InvalidOperationException("Gemini HTTP " + (int)resp.StatusCode);
                    }
                    string raw = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    Dictionary<string, object> parsed = ser.DeserializeObject(raw) as Dictionary<string, object>;
                    string content = ExtractGeminiInteractionsText(parsed);
                    List<string> arr = ParseJsonArrayFromModelText(content, ser);
                    if (arr == null || arr.Count != texts.Count)
                    {
                        throw new InvalidOperationException("Gemini array count mismatch");
                    }
                    return arr;
                }
            }
        }

        private static string ExtractChatCompletionText(Dictionary<string, object> root)
        {
            if (root == null || !root.ContainsKey("choices")) return "";
            IEnumerable choices = root["choices"] as IEnumerable;
            if (choices == null) return "";
            foreach (object ch in choices)
            {
                Dictionary<string, object> chDict = ch as Dictionary<string, object>;
                if (chDict != null && chDict.ContainsKey("message"))
                {
                    Dictionary<string, object> msg = chDict["message"] as Dictionary<string, object>;
                    if (msg != null && msg.ContainsKey("content") && msg["content"] != null)
                    {
                        return Convert.ToString(msg["content"]).Trim();
                    }
                }
            }
            return "";
        }

        private static string ExtractGeminiInteractionsText(Dictionary<string, object> root)
        {
            if (root == null || !root.ContainsKey("steps")) return "";
            IEnumerable steps = root["steps"] as IEnumerable;
            if (steps == null) return "";
            StringBuilder sb = new StringBuilder();
            foreach (object st in steps)
            {
                Dictionary<string, object> stDict = st as Dictionary<string, object>;
                if (stDict == null) continue;
                string t = ReadStr(stDict, "type", "");
                if (t != "model_output" || !stDict.ContainsKey("content")) continue;
                IEnumerable contentArr = stDict["content"] as IEnumerable;
                if (contentArr == null) continue;
                foreach (object c in contentArr)
                {
                    Dictionary<string, object> cDict = c as Dictionary<string, object>;
                    if (cDict != null && cDict.ContainsKey("text") && cDict["text"] != null)
                    {
                        sb.Append(Convert.ToString(cDict["text"]));
                    }
                }
            }
            return sb.ToString().Trim();
        }

        private static List<string> ParseJsonArrayFromModelText(string rawText, JavaScriptSerializer ser)
        {
            if (string.IsNullOrWhiteSpace(rawText)) return null;
            string s = rawText.Trim();
            int firstBracket = s.IndexOf('[');
            int lastBracket = s.LastIndexOf(']');
            if (firstBracket < 0 || lastBracket <= firstBracket) return null;
            string slice = s.Substring(firstBracket, (lastBracket - firstBracket) + 1);
            object obj = ser.DeserializeObject(slice);
            IEnumerable enumerable = obj as IEnumerable;
            if (enumerable == null || obj is string) return null;
            List<string> list = new List<string>();
            foreach (object item in enumerable)
            {
                list.Add(item == null ? "" : Convert.ToString(item).Trim());
            }
            return list;
        }

        private async Task WriteOptionsResponseAsync(TcpClient client, NetworkStream stream, string corsOrigin)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("HTTP/1.1 204 No Content\r\n");
            if (!string.IsNullOrEmpty(corsOrigin))
            {
                sb.Append("Access-Control-Allow-Origin: ").Append(corsOrigin).Append("\r\n");
                sb.Append("Vary: Origin\r\n");
                sb.Append("Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n");
                sb.Append("Access-Control-Allow-Headers: Content-Type, X-Agy-Bridge-Token\r\n");
                sb.Append("Access-Control-Allow-Private-Network: true\r\n");
                sb.Append("Access-Control-Max-Age: 86400\r\n");
            }
            sb.Append("Content-Length: 0\r\nConnection: close\r\n\r\n");
            byte[] bytes = Encoding.ASCII.GetBytes(sb.ToString());
            await WriteBytesWithTimeoutAsync(client, stream, bytes, 5000, _shutdownCts.Token).ConfigureAwait(false);
        }

        private async Task WriteJsonResponseAsync(TcpClient client, NetworkStream stream, int statusCode, string corsOrigin, string jsonBody)
        {
            string statusText = statusCode == 200 ? "OK" :
                                statusCode == 400 ? "Bad Request" :
                                statusCode == 401 ? "Unauthorized" :
                                statusCode == 403 ? "Forbidden" :
                                statusCode == 404 ? "Not Found" :
                                statusCode == 413 ? "Payload Too Large" :
                                statusCode == 429 ? "Too Many Requests" : "Bad Gateway";

            byte[] payloadBytes = Encoding.UTF8.GetBytes(jsonBody ?? "{}");
            StringBuilder sb = new StringBuilder();
            sb.Append("HTTP/1.1 ").Append(statusCode).Append(' ').Append(statusText).Append("\r\n");
            sb.Append("Content-Type: application/json; charset=utf-8\r\n");
            if (!string.IsNullOrEmpty(corsOrigin))
            {
                sb.Append("Access-Control-Allow-Origin: ").Append(corsOrigin).Append("\r\n");
                sb.Append("Vary: Origin\r\n");
                sb.Append("Access-Control-Allow-Private-Network: true\r\n");
            }
            sb.Append("Cache-Control: no-store\r\n");
            sb.Append("Content-Length: ").Append(payloadBytes.Length).Append("\r\n");
            sb.Append("Connection: close\r\n\r\n");

            byte[] headerBytes = Encoding.ASCII.GetBytes(sb.ToString());
            byte[] combined = new byte[headerBytes.Length + payloadBytes.Length];
            Buffer.BlockCopy(headerBytes, 0, combined, 0, headerBytes.Length);
            Buffer.BlockCopy(payloadBytes, 0, combined, headerBytes.Length, payloadBytes.Length);
            await WriteBytesWithTimeoutAsync(client, stream, combined, 5000, _shutdownCts.Token).ConfigureAwait(false);
        }

        public void Dispose()
        {
            _stopped = true;
            try { _shutdownCts.Cancel(); } catch { }
            try { _listener.Stop(); } catch { }
            try { _directClient.Dispose(); } catch { }
            try { _defaultClient.Dispose(); } catch { }
            try { _concurrencyGate.Dispose(); } catch { }
            try { _connectionGate.Dispose(); } catch { }
            try { _shutdownCts.Dispose(); } catch { }
        }
    }
}
'@
    Add-Type -TypeDefinition $csharpSource -ReferencedAssemblies @('System.Net.Http', 'System.Web.Extensions') -Language CSharp
}

$bridgeMutex = New-Object System.Threading.Mutex($false, $BridgeMutexName)
$ownsBridge = $false
$publishedEndpoint = $false
$stopEvent = $null
$bridgeInstance = $null

try {
    try {
        $ownsBridge = $bridgeMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $ownsBridge = $true
    }
    if (-not $ownsBridge) {
        return
    }

    $stopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $BridgeStopEventName)
    if (Test-BridgeStopRequested -CancelEvent $stopEvent) {
        return
    }

    $cfg = Ensure-BridgeConfigValues -CancelEvent $stopEvent
    if ($null -eq $cfg -or (Test-BridgeStopRequested -CancelEvent $stopEvent)) {
        return
    }

    $prefPort = if ($Port -ge 1024 -and $Port -le 65535) { $Port } else { [int]$cfg['bridgePort'] }
    $bridgeInstance = New-Object AgyZhPlus.LocalTranslationBridge($ConfigPath, $prefPort)
    if (Test-BridgeStopRequested -CancelEvent $stopEvent) {
        return
    }

    $boundPort = [int]$bridgeInstance.BoundPort
    $bridgeInstance.StartAcceptLoop()

    $epMeta = ([ordered]@{
        pid        = $PID
        port       = $boundPort
        version    = $BridgeRuntimeVersion
        startedUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress)
    [IO.File]::WriteAllText($BridgeEndpointFile, $epMeta, [Text.Encoding]::UTF8)
    $publishedEndpoint = $true

    if ($boundPort -ne [int]$cfg['bridgePort']) {
        $lch = New-Object System.Threading.Mutex($false, $LauncherMutexName)
        $hasLch = $false
        try {
            try { $hasLch = $lch.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $hasLch = $true }
            if ($hasLch -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
                $curObj = ([IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
                if ($null -ne $curObj) {
                    $map = [ordered]@{}
                    foreach ($pr in $curObj.PSObject.Properties) { $map[$pr.Name] = $pr.Value }
                    $map['bridgePort'] = $boundPort
                    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                    $tmpCfg = "$ConfigPath.tmp.$PID.$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
                    [IO.File]::WriteAllText($tmpCfg, ($map | ConvertTo-Json -Depth 6), $utf8NoBom)
                    [IO.File]::Replace($tmpCfg, $ConfigPath, [NullString]::Value)
                }
            }
        } finally {
            if ($hasLch) { try { $lch.ReleaseMutex() } catch {} }
            $lch.Dispose()
        }
    }

    Write-BridgeLog -Message "本地免代理直连翻译桥已启动 (v$BridgeRuntimeVersion, PID: $PID, 监听: 127.0.0.1:$boundPort)。"

    while ($true) {
        if ($stopEvent.WaitOne(2000)) { break }
        if (Test-Path -LiteralPath $BridgeStopSignalFile -PathType Leaf) { break }
    }

    Write-BridgeLog -Message "本地免代理直连翻译桥已正常退出 (PID: $PID)。"
} catch {
    Write-BridgeLog -Message "本地免代理直连翻译桥异常退出: $($_.Exception.Message)"
    throw
} finally {
    if ($null -ne $bridgeInstance) {
        try { $bridgeInstance.Dispose() } catch {}
    }
    if ($ownsBridge -and $publishedEndpoint -and (Test-Path -LiteralPath $BridgeEndpointFile -PathType Leaf)) {
        try {
            $curEp = ([IO.File]::ReadAllText($BridgeEndpointFile, [Text.Encoding]::UTF8)) | ConvertFrom-Json
            if ($null -ne $curEp -and [int]$curEp.pid -eq $PID) {
                Remove-Item -LiteralPath $BridgeEndpointFile -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    if ($null -ne $stopEvent) {
        $stopEvent.Dispose()
    }
    if ($ownsBridge) {
        try { $bridgeMutex.ReleaseMutex() } catch {}
    }
    $bridgeMutex.Dispose()
}
