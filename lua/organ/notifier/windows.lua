-- Windows notifier backend.
--
-- Strategy:
--   * One-time install: copy Organ.ico to %APPDATA%\organ\, write notify.ps1
--     (the toast-rendering helper), and create a Start Menu shortcut at
--     %APPDATA%\Microsoft\Windows\Start Menu\Programs\Organ.lnk with the
--     AppUserModelID (AUMID) property set via IPropertyStore. The AUMID is
--     what Windows uses to attribute toast notifications — without a
--     shortcut carrying it, toasts appear under "Windows PowerShell"
--     branding. With it, they appear as "Organ" with our icon.
--   * Per reminder: Register-ScheduledTask (PowerShell) with a one-shot
--     trigger at the fire time, action invokes notify.ps1 with title+body.
--     Survives reboot natively (Windows scheduled tasks persist).
--   * Cancel: Unregister-ScheduledTask by task name.
--
-- Requires Windows 10+ (toast notifications). PowerShell 5.1+ ships with
-- Win10 by default. No third-party modules required.

local M = {}

local TASK_PREFIX = "Organ-Reminder-"
local AUMID = "Sh.Organ.Notifier"

local function appdata()
  return os.getenv("APPDATA") or (vim.uv.os_homedir() .. "/AppData/Roaming")
end

local function install_dir()
  return appdata() .. "\\organ"
end
local function ico_path()
  return install_dir() .. "\\Organ.ico"
end
local function notify_script()
  return install_dir() .. "\\notify.ps1"
end
local function shortcut_path()
  return appdata() .. "\\Microsoft\\Windows\\Start Menu\\Programs\\Organ.lnk"
end
local function marker_path()
  return install_dir() .. "\\.installed"
end

local function source_ico()
  local hits = vim.api.nvim_get_runtime_file("assets/icons/Organ.ico", false)
  return hits[1]
end

local function powershell(...)
  return { "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", ... }
end

local function run(cmd, opts)
  return vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait()
end

-- The notify.ps1 helper. Invoked by each scheduled task to render the
-- toast under our AUMID. Reads title/body from arguments.
local NOTIFY_PS1 = [[
param([string]$Title, [string]$Body)
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] | Out-Null

$xml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$([System.Security.SecurityElement]::Escape($Title))</text>
      <text>$([System.Security.SecurityElement]::Escape($Body))</text>
    </binding>
  </visual>
</toast>
"@

$xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
$xmlDoc.LoadXml($xml)

$toast = [Windows.UI.Notifications.ToastNotification]::new($xmlDoc)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(']] .. AUMID .. [[').Show($toast)
]]

-- Installer that creates the Start Menu shortcut and sets its AUMID via
-- IPropertyStore. Runs once on first schedule. Marker file prevents re-run.
local function shortcut_installer_ps1()
  return string.format(
    [[
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct PROPERTYKEY {
  public Guid fmtid;
  public uint pid;
}

[ComImport]
[Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore {
  int GetCount(out uint cProps);
  int GetAt(uint iProp, out PROPERTYKEY pkey);
  int GetValue([In] ref PROPERTYKEY key, [Out] out object pv);
  int SetValue([In] ref PROPERTYKEY key, [In] ref object pv);
  int Commit();
}

public class ShellHelper {
  [DllImport("shell32.dll")]
  public static extern int SHGetPropertyStoreFromParsingName(
    [MarshalAs(UnmanagedType.LPWStr)] string pszPath,
    IntPtr zeroWorks, int flags,
    ref Guid riid,
    [Out, MarshalAs(UnmanagedType.Interface)] out IPropertyStore ppv);
}
"@

$shortcut = '%s'
$icon     = '%s'
$AppId    = '%s'

# 1. Create the .lnk
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($shortcut)
$sc.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$sc.IconLocation = $icon
$sc.Description = 'Organ.nvim notifications'
$sc.Save()

# 2. Set the AppUserModelID property on the shortcut
$iid = [Guid]'886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99'
$store = $null
$hr = [ShellHelper]::SHGetPropertyStoreFromParsingName(
  $shortcut, [IntPtr]::Zero, 2, [ref]$iid, [ref]$store)
if ($hr -ne 0) { throw "SHGetPropertyStoreFromParsingName failed: 0x$($hr.ToString('X'))" }

$key = New-Object PROPERTYKEY
$key.fmtid = [Guid]'9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3'
$key.pid = 5

$value = [object]$AppId
$store.SetValue([ref]$key, [ref]$value) | Out-Null
$store.Commit() | Out-Null
[Runtime.InteropServices.Marshal]::ReleaseComObject($store) | Out-Null

Write-Output "AUMID set on $shortcut"
]],
    shortcut_path():gsub("'", "''"),
    ico_path():gsub("'", "''"),
    AUMID
  )
end

-- One-time install ----------------------------------------------------------

local function ensure_install()
  if vim.fn.filereadable(marker_path()) == 1 then
    return true
  end

  vim.fn.mkdir(install_dir(), "p")

  -- Copy icon
  local src = source_ico()
  if not src then
    return false, "Organ.ico not found on runtimepath (assets/icons/Organ.ico)"
  end
  local copied, cerr = vim.uv.fs_copyfile(src, ico_path())
  if not copied then
    return false, "icon copy: " .. tostring(cerr)
  end

  -- Write notify.ps1
  local fd, err = io.open(notify_script(), "w")
  if not fd then
    return false, "notify.ps1 write: " .. tostring(err)
  end
  fd:write(NOTIFY_PS1)
  fd:close()

  -- Run shortcut installer
  local installer_path = install_dir() .. "\\install-shortcut.ps1"
  local sfd, serr = io.open(installer_path, "w")
  if not sfd then
    return false, "installer write: " .. tostring(serr)
  end
  sfd:write(shortcut_installer_ps1())
  sfd:close()

  local r = run(powershell("-File", installer_path))
  if r.code ~= 0 then
    return false, "shortcut installer failed: " .. (r.stderr or r.stdout or "unknown")
  end

  -- Marker
  local mfd = io.open(marker_path(), "w")
  if mfd then
    mfd:write(os.time())
    mfd:close()
  end
  return true
end

-- Schedule helpers ----------------------------------------------------------

local function uuid()
  local r = math.random
  return string.format("%x%x%x", os.time(), r(0, 0xfffff), r(0, 0xfffff))
end

local function ps_quote(s)
  return "'" .. tostring(s or ""):gsub("'", "''") .. "'"
end

-- Public --------------------------------------------------------------------

-- Test/diagnostic accessors. Underscore-prefixed; not part of the stable API.
M._ps_quote = ps_quote
M._notify_ps1 = NOTIFY_PS1
M._aumid = AUMID

function M.schedule(entry)
  local ok, ierr = ensure_install()
  if not ok then
    return nil, ierr
  end

  local task_name = TASK_PREFIX .. uuid()
  local at = os.date("%Y-%m-%dT%H:%M:%S", entry.at)

  -- We invoke notify.ps1 via powershell.exe with title+body args.
  -- All quoting goes through PowerShell single-quote escaping.
  local action_args = string.format(
    "-NoProfile -ExecutionPolicy Bypass -File %s -Title %s -Body %s",
    ps_quote(notify_script()),
    ps_quote(entry.title or ""),
    ps_quote(entry.body or "")
  )

  local script = string.format(
    [[
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument %s
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date '%s')
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName '%s' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
]],
    ps_quote(action_args),
    at,
    task_name
  )

  local r = run(powershell("-Command", script))
  if r.code ~= 0 then
    return nil, "Register-ScheduledTask: " .. (r.stderr or r.stdout or "unknown")
  end
  return task_name
end

function M.cancel(handle)
  if type(handle) ~= "string" then
    return false, "no handle"
  end
  local script = string.format(
    "Unregister-ScheduledTask -TaskName '%s' -Confirm:$false -ErrorAction SilentlyContinue",
    handle:gsub("'", "''")
  )
  run(powershell("-Command", script))
  return true
end

function M.cancel_all()
  local script = string.format(
    [[
Get-ScheduledTask -TaskName '%s*' -ErrorAction SilentlyContinue |
  Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
]],
    TASK_PREFIX
  )
  run(powershell("-Command", script))
  return true
end

function M.status()
  local function which(cmd)
    local r = run({ "where.exe", cmd })
    return r.code == 0
  end
  local count_script = string.format(
    "(Get-ScheduledTask -TaskName '%s*' -ErrorAction SilentlyContinue | Measure-Object).Count",
    TASK_PREFIX
  )
  local r = run(powershell("-Command", count_script))
  local count = tonumber((r.stdout or ""):match("(%d+)")) or 0

  return {
    powershell = which("powershell.exe"),
    schtasks = which("schtasks.exe"),
    install_dir = install_dir(),
    shortcut_path = shortcut_path(),
    installed = vim.fn.filereadable(marker_path()) == 1,
    icon_installed = vim.fn.filereadable(ico_path()) == 1,
    source_ico = source_ico(),
    aumid = AUMID,
    scheduled_tasks = count,
  }
end

return M
