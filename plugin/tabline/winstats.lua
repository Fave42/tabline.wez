-- Windows RAM/CPU sampler shared by the `ram` and `cpu` components.
--
-- Why: `wmic` is gone on current Windows 11 builds, and Get-CimInstance needs
-- about 2 s per call on managed machines. wezterm.run_child_process blocks the
-- GUI thread, so a synchronous call would freeze the window on every update.
--
-- How: a hidden PowerShell reads RAM (GlobalMemoryStatusEx) and CPU load
-- (GetSystemTimes) from kernel32 and writes "<epoch> <total_kb> <avail_kb> <cpu%>"
-- to %TEMP%. It is started with wezterm.background_child_process (non-blocking)
-- at most once per interval. Each update only reads that small file.
local wezterm = require('wezterm')

local M = {}

local MIN_INTERVAL = 5 -- seconds between sampler launches
local STALE_AFTER = 60 -- seconds after which a sample is considered dead

local out_file = (os.getenv('TEMP') or os.getenv('TMP') or 'C:\\Windows\\Temp') .. '\\wezterm-tabline-stats.txt'

local PS_SCRIPT = [=[
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
  Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class WS { [StructLayout(LayoutKind.Sequential)] public struct MS { public uint dwLength; public uint dwMemoryLoad; public ulong TotalPhys; public ulong AvailPhys; public ulong TotalPF; public ulong AvailPF; public ulong TotalVirt; public ulong AvailVirt; public ulong AvailExt; } [DllImport("kernel32.dll")] public static extern bool GlobalMemoryStatusEx(ref MS m); [DllImport("kernel32.dll")] public static extern bool GetSystemTimes(out long i, out long k, out long u); }'
  $m = New-Object WS+MS
  $m.dwLength = [System.Runtime.InteropServices.Marshal]::SizeOf($m)
  [void][WS]::GlobalMemoryStatusEx([ref]$m)
  $i1 = 0; $k1 = 0; $u1 = 0; $i2 = 0; $k2 = 0; $u2 = 0
  [void][WS]::GetSystemTimes([ref]$i1, [ref]$k1, [ref]$u1)
  Start-Sleep -Milliseconds 250
  [void][WS]::GetSystemTimes([ref]$i2, [ref]$k2, [ref]$u2)
  $total = ($k2 - $k1) + ($u2 - $u1)
  $cpu = 0.0
  if ($total -gt 0) { $cpu = 100.0 * ($total - ($i2 - $i1)) / $total }
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  $line = [string]::Format($inv, '{0} {1} {2} {3:0.0}', [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), [long]($m.TotalPhys / 1024), [long]($m.AvailPhys / 1024), $cpu)
  [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'wezterm-tabline-stats.txt'), $line)
} catch { }
]=]

-- wezterm.base64_encode is not available in WezTerm 20240203, so encode here.
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    local c1, c2, c3, c4 = (n >> 18) & 63, (n >> 12) & 63, (n >> 6) & 63, n & 63
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or '=')
      .. (c and B64:sub(c4 + 1, c4 + 1) or '=')
  end
  return table.concat(out)
end

-- -EncodedCommand takes base64 of UTF-16LE; the script is pure ASCII.
local ps_encoded = base64((PS_SCRIPT:gsub('.', '%0\0')))

local last_spawn = 0
local last_read = 0
local cache = nil

local function read_sample()
  local f = io.open(out_file, 'r')
  if not f then
    return
  end
  local text = f:read('*a')
  f:close()
  local ts, total, avail, cpu = (text or ''):match('^%s*(%d+) (%d+) (%d+) ([%d%.,]+)')
  if not ts then
    return
  end
  ts, total, avail, cpu = tonumber(ts), tonumber(total), tonumber(avail), tonumber((cpu:gsub(',', '.')))
  if ts and total and avail and cpu then
    cache = { ts = ts, total_kb = total, avail_kb = avail, cpu = cpu }
  end
end

--- Returns { total_kb, avail_kb, cpu } or nil if no fresh sample is available.
--- Never raises and never blocks.
function M.get(interval)
  local ok, result = pcall(function()
    local now = os.time()
    if now - last_spawn >= math.max(tonumber(interval) or MIN_INTERVAL, MIN_INTERVAL) then
      last_spawn = now
      wezterm.background_child_process {
        'powershell.exe',
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-EncodedCommand',
        ps_encoded,
      }
    end
    if now ~= last_read then
      last_read = now
      read_sample()
    end
    if cache and now - cache.ts <= STALE_AFTER then
      return cache
    end
  end)
  if ok then
    return result
  end
end

return M
