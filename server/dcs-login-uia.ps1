# dcs-login-uia.ps1 v4 - Win32 driver with proper error surfacing
$log = 'C:\dcs-state\uia-login.log'
function L([string]$m) { Add-Content $log ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
L '--- v4 win32 run ---'
try {
    try {
        Add-Type -Namespace W -Name U -MemberDefinition @"
[DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hDlg, int id);
[DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr SendMessageText(IntPtr h, uint msg, IntPtr w, string l);
[DllImport("user32.dll", EntryPoint="SendMessageW")] public static extern IntPtr SendMessagePtr(IntPtr h, uint msg, IntPtr w, IntPtr l);
"@
    } catch { if (-not ([System.Management.Automation.PSTypeName]'W.U').Type) { throw } }

    $cred = Get-Content 'C:\dcs-state\.dcslogin' | ConvertFrom-Json

    $hwnd = [IntPtr]::Zero
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline -and $hwnd -eq [IntPtr]::Zero) {
        $hwnd = [W.U]::FindWindowW('#32770', 'DCS Login')
        if ($hwnd -eq [IntPtr]::Zero) { Start-Sleep -Seconds 5 }
    }
    if ($hwnd -eq [IntPtr]::Zero) { L 'v4 FAIL: no DCS Login window'; exit 1 }
    L "v4: hwnd=$hwnd"

    $user = [W.U]::GetDlgItem($hwnd, 1000)
    $pass = [W.U]::GetDlgItem($hwnd, 1001)
    if ($user -eq [IntPtr]::Zero -or $pass -eq [IntPtr]::Zero) { L 'v4 FAIL: edits missing'; exit 1 }

    [void][W.U]::SendMessageText($user, 0x000C, [IntPtr]::Zero, [string]$cred.u)
    [void][W.U]::SendMessageText($pass, 0x000C, [IntPtr]::Zero, [string]$cred.p)
    $ul = [W.U]::SendMessagePtr($user, 0x000E, [IntPtr]::Zero, [IntPtr]::Zero)
    $pl = [W.U]::SendMessagePtr($pass, 0x000E, [IntPtr]::Zero, [IntPtr]::Zero)
    L "v4: set user_len=$ul pass_len=$pl"

    foreach ($id in 1004, 1005) {
        $cb = [W.U]::GetDlgItem($hwnd, $id)
        if ($cb -ne [IntPtr]::Zero) {
            $st = [W.U]::SendMessagePtr($cb, 0x00F0, [IntPtr]::Zero, [IntPtr]::Zero)
            if ([int64]$st -eq 0) { [void][W.U]::SendMessagePtr($cb, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) }
            L "v4: checkbox $id state=$([W.U]::SendMessagePtr($cb, 0x00F0, [IntPtr]::Zero, [IntPtr]::Zero))"
        }
    }

    [void][W.U]::SendMessagePtr([W.U]::GetDlgItem($hwnd, 1), 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
    L 'v4: clicked Log In'
    Start-Sleep -Seconds 12
    if ([W.U]::FindWindowW('#32770', 'DCS Login') -eq [IntPtr]::Zero) { L 'v4 SUCCESS: dialog closed' }
    else { L 'v4 WARN: dialog still open' }
} catch {
    L "v4 EXCEPTION: $($_.Exception.Message)"
    exit 1
}