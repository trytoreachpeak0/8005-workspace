#Requires -Version 7
<#
.SYNOPSIS
    Read-only look at the onboard HMI screen: one screenshot of the desktop, one PrintWindow image
    per HMI window, and the UI Automation tree of every HMI window as JSON. Runs ON the vehicle,
    inside the interactive desktop session. Deployed and launched by 17-capture-hmi-screen.ps1.

.DESCRIPTION
    Test and field tooling only (workspace#16). Never part of an onboard package; nothing starts it
    but an explicit 17-capture-hmi-screen.ps1 call.

    Read-only by construction. The only UI Automation calls are property reads (Current.*), tree
    walking and pattern *reads* (ValuePattern.Current.Value, TogglePattern.Current.ToggleState).
    Nothing here focuses, invokes, types, selects, expands, sends mouse or keyboard input, or brings a
    window forward. Graphics.CopyFromScreen and PrintWindow read pixels and change no state.
    The self-test in 17-capture-hmi-screen.ps1 scans this file for any call that would, by name.

    The script is started hidden (wscript, window style 0), so it creates no visible window and
    does not take the foreground. It records the foreground window at its start and at its end;
    if either belongs to this process tree, the result says so (focusDisturbed).

    Password boxes (UIA IsPassword) are never read, and their rectangles are painted black in both
    images before anything is written to disk.

    Writes <Stamp>-uia.json whatever happens, so the control host never has to guess from silence;
    images are written only when they were captured.
#>
param(
    [string] $OutputDirectory,
    [string] $Stamp,
    [string] $ProcessName = 'SQCD.Agv.Wpf',
    # Off-vehicle test only: one process by id instead of by name.
    [int] $ProcessId = 0,
    [int] $MaxNodes = 4000,
    [int] $MaxDepth = 40
)

$ErrorActionPreference = 'Stop'

# First act, before anything slow: tells the control host "ran but never finished" from "never ran".
# Carries TickCount64, a clock the system time cannot move, for comparing with the launch and preflight.
if ($MyInvocation.InvocationName -ne '.' -and $OutputDirectory -and $Stamp) {
    Set-Content -LiteralPath (Join-Path $OutputDirectory "$Stamp.started") -Encoding utf8NoBOM `
        -Value ('{0} tick={1}' -f [DateTimeOffset]::Now.ToString('o'), [Environment]::TickCount64)
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
if (-not ('HmiCapture.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace HmiCapture {
    public sealed class WindowInfo {
        public long Handle; public int ProcessId; public bool Visible; public bool Minimized;
        public string Title; public string ClassName; public long Owner;
        public int Left, Top, Right, Bottom; public int ZOrder;
    }

    public static class Native {
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
        [DllImport("user32.dll")] static extern IntPtr SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr h, int index, StringBuilder info, int length, out int needed);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);

        // Asks for per-monitor v2 so screen coordinates, UIA rectangles and bitmap pixels agree under scaling.
        // It returned false on agv02 (2026-10-11: pwsh had already set its awareness), so the result records
        // whether it took; at that vehicle's 100% scaling the three agree either way.
        public static bool MakeDpiAware() { return SetProcessDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero; }


        // "Default" when the user's desktop takes input; null with an error when it is the secure
        // (Winlogon) desktop. Not a lock test on its own: on agv02 (Windows 10 22H2, 2026-10-11) the lock
        // screen read "Default", because its curtain (LockApp) lives on the user's desktop. LogonUI in the
        // session is what caught that lock; both are recorded and either one counts.
        public static string InputDesktopName(out int error) {
            error = 0;
            IntPtr h = OpenInputDesktop(0, false, 0x0001 /* DESKTOP_READOBJECTS */);
            if (h == IntPtr.Zero) { error = Marshal.GetLastWin32Error(); return null; }
            try {
                var sb = new StringBuilder(256); int needed;
                return GetUserObjectInformation(h, 2 /* UOI_NAME */, sb, sb.Capacity * 2, out needed) ? sb.ToString() : null;
            } finally { CloseDesktop(h); }
        }

        public static long Foreground() { return GetForegroundWindow().ToInt64(); }

        public static int ProcessOf(long hwnd) { uint pid; GetWindowThreadProcessId(new IntPtr(hwnd), out pid); return (int)pid; }

        // Every top-level window in z-order, visible or not: a MessageBox owned by a hidden window
        // is exactly the case a visible-only listing misses.
        public static List<WindowInfo> TopLevelWindows() {
            var list = new List<WindowInfo>(); int z = 0;
            EnumWindows((h, l) => {
                uint pid; GetWindowThreadProcessId(h, out pid);
                var title = new StringBuilder(512); GetWindowText(h, title, title.Capacity);
                var cls = new StringBuilder(256); GetClassName(h, cls, cls.Capacity);
                RECT r; GetWindowRect(h, out r);
                list.Add(new WindowInfo {
                    Handle = h.ToInt64(), ProcessId = (int)pid, Visible = IsWindowVisible(h), Minimized = IsIconic(h),
                    Title = title.ToString(), ClassName = cls.ToString(), Owner = GetWindow(h, 4 /* GW_OWNER */).ToInt64(),
                    Left = r.Left, Top = r.Top, Right = r.Right, Bottom = r.Bottom, ZOrder = z++ });
                return true;
            }, IntPtr.Zero);
            return list;
        }

        public static bool PrintWindowTo(long hwnd, IntPtr hdc) { return PrintWindow(new IntPtr(hwnd), hdc, 2 /* PW_RENDERFULLCONTENT */); }

        public static int[] VirtualScreenBounds() {
            return new[] { GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79) };
        }
    }
}
'@
}

<# Pixels of the screen area [left, top, width, height]. Graphics.CopyFromScreen reads, nothing more. #>
function Get-ScreenBitmap {
    param([int[]] $Area)
    $bitmap = [System.Drawing.Bitmap]::new($Area[2], $Area[3])
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen($Area[0], $Area[1], 0, 0, [System.Drawing.Size]::new($Area[2], $Area[3])) } finally { $graphics.Dispose() }
    return $bitmap
}

<#
    One window's own surface through PrintWindow(PW_RENDERFULLCONTENT), so an occluded window still comes
    out whole. $null when the window refuses.
#>
function Get-WindowBitmap {
    param([long] $Handle, [int] $Width, [int] $Height)
    if ($Width -le 0 -or $Height -le 0) { return $null }
    $bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $hdc = $graphics.GetHdc()
    try { $ok = [HmiCapture.Native]::PrintWindowTo($Handle, $hdc) } finally { $graphics.ReleaseHdc($hdc); $graphics.Dispose() }
    if ($ok) { return $bitmap }
    $bitmap.Dispose()
    return $null
}

<# True when every sampled pixel has the same colour: a black secure desktop, a blank capture. #>
function Test-UniformBitmap {
    param([System.Drawing.Bitmap] $Bitmap)
    $stepX = [Math]::Max(1, [int]($Bitmap.Width / 64)); $stepY = [Math]::Max(1, [int]($Bitmap.Height / 64))
    $first = $Bitmap.GetPixel(0, 0).ToArgb()
    for ($y = 0; $y -lt $Bitmap.Height; $y += $stepY) {
        for ($x = 0; $x -lt $Bitmap.Width; $x += $stepX) {
            if ($Bitmap.GetPixel($x, $y).ToArgb() -ne $first) { return $false }
        }
    }
    return $true
}

function Set-BlackRectangle {
    param([System.Drawing.Bitmap] $Bitmap, [int] $Left, [int] $Top, [int] $Width, [int] $Height)
    $graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
    try { $graphics.FillRectangle([System.Drawing.Brushes]::Black, $Left, $Top, $Width, $Height) } finally { $graphics.Dispose() }
}

<#
    One UIA element as a plain record. Property reads only. A password box is marked and its value is
    never read. Returns $null when the element went away while being read.
#>
function Read-UiaNode {
    param([System.Windows.Automation.AutomationElement] $Element)
    try {
        $c = $Element.Current
        $rect = $c.BoundingRectangle
        $node = [ordered]@{
            controlType  = $c.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            name         = $c.Name
            automationId = $c.AutomationId
            className    = $c.ClassName
            isEnabled    = $c.IsEnabled
            isOffscreen  = $c.IsOffscreen
            hasFocus     = $c.HasKeyboardFocus
            isPassword   = $c.IsPassword
            rect         = if ($rect.IsEmpty) { $null } else { @([int]$rect.X, [int]$rect.Y, [int]$rect.Width, [int]$rect.Height) }
        }
        if (-not $c.IsPassword) {
            $pattern = $null
            if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref] $pattern)) {
                $node.value = $pattern.Current.Value
            }
        }
        $pattern = $null
        if ($Element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref] $pattern)) {
            $node.toggleState = "$($pattern.Current.ToggleState)"
        }
        return $node
    } catch [System.Windows.Automation.ElementNotAvailableException] {
        return $null
    }
}

<#
    Depth-first walk of the control view under $Root. $Budget is a one-element array so the node cap
    is shared across every window. Returns the root record with children, or $null.
#>
function Read-UiaTree {
    param([System.Windows.Automation.AutomationElement] $Root, [int[]] $Budget, [int] $MaxDepth, [int] $Depth = 0)
    if ($Budget[0] -le 0) { return $null }
    $node = Read-UiaNode $Root
    if (-not $node) { return $null }
    $Budget[0]--
    if ($Depth -ge $MaxDepth) { $node.truncated = 'depth'; return $node }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $children = [System.Collections.Generic.List[object]]::new()
    try {
        $child = $walker.GetFirstChild($Root)
        while ($child) {
            if ($Budget[0] -le 0) { $node.truncated = 'nodes'; break }
            $sub = Read-UiaTree -Root $child -Budget $Budget -MaxDepth $MaxDepth -Depth ($Depth + 1)
            if ($sub) { $children.Add($sub) }
            $child = $walker.GetNextSibling($child)
        }
    } catch [System.Windows.Automation.ElementNotAvailableException] {
        $node.truncated = 'element-gone'
    }
    if ($children.Count) { $node.children = $children.ToArray() }
    return $node
}

<# Every node of a tree, depth-first. #>
function Get-UiaNodes {
    param($Node)
    if (-not $Node) { return }
    $Node
    foreach ($child in @($Node.children)) { Get-UiaNodes $child }
}

<# What a person would read off the screen, in tree order: non-empty names and values of on-screen nodes. #>
function Get-VisibleTexts {
    param([object[]] $Trees)
    $texts = [System.Collections.Generic.List[string]]::new()
    foreach ($tree in $Trees) {
        foreach ($n in Get-UiaNodes $tree) {
            if ($n.isOffscreen) { continue }
            # A button's name and the text block inside it say the same thing; keep one.
            if (-not [string]::IsNullOrWhiteSpace($n.name) -and ($texts.Count -eq 0 -or $texts[-1] -cne $n.name)) { $texts.Add($n.name) }
            if ($n.Contains('value') -and -not [string]::IsNullOrWhiteSpace($n.value) -and $n.value -ne $n.name) { $texts.Add($n.value) }
        }
    }
    return $texts.ToArray()
}

function Get-WindowRecord {
    param([HmiCapture.WindowInfo] $Window, [hashtable] $Names)
    return [ordered]@{
        handle    = '0x{0:X}' -f $Window.Handle
        process   = $Names[$Window.ProcessId] ?? "$($Window.ProcessId)"
        processId = $Window.ProcessId
        title     = $Window.Title
        className = $Window.ClassName
        visible   = $Window.Visible
        minimized = $Window.Minimized
        owner     = if ($Window.Owner) { '0x{0:X}' -f $Window.Owner } else { $null }
        rect      = @($Window.Left, $Window.Top, ($Window.Right - $Window.Left), ($Window.Bottom - $Window.Top))
        zOrder    = $Window.ZOrder
    }
}

<#
    Whether the desktop is locked, from three signals; any one is enough. Pure, so -SelfTest covers each.
      * the input desktop is not "Default" (the Winlogon secure desktop, e.g. a sign-in prompt);
      * LogonUI runs in this session;
      * the foreground process is LockApp, the Windows 10 lock screen curtain.
    The first alone misses the plain lock screen: on agv02 at 2026-10-11 20:04 the lock read "Default",
    and LogonUI was what caught it (LockApp was in the foreground too).
#>
function Get-LockState {
    param([string] $InputDesktop, [int] $OpenError, [bool] $LogonUiInSession, [string] $ForegroundProcess)
    $signals = @(
        if ($InputDesktop -ne 'Default') { 'inputDesktop' }
        if ($LogonUiInSession) { 'logonUi' }
        if ($ForegroundProcess -eq 'LockApp') { 'lockAppForeground' }
    )
    return [ordered]@{
        inputDesktop      = $InputDesktop
        openError         = $OpenError
        logonUiInSession  = $LogonUiInSession
        foregroundProcess = $ForegroundProcess
        lockSignals       = $signals
        locked            = $signals.Count -gt 0
    }
}

# Dot-sourced by the self-test: define the functions and stop.
if ($MyInvocation.InvocationName -eq '.') { return }

$sessionId = (Get-Process -Id $PID).SessionId
$ownTree = @($PID; (Get-CimInstance Win32_Process -Filter "ProcessId = $PID").ParentProcessId)
$result = [ordered]@{
    tool             = 'agv-capture-hmi-screen'
    host             = $env:COMPUTERNAME
    user             = $env:USERNAME
    sessionId        = $sessionId
    vehicleClock     = [DateTimeOffset]::Now.ToString('o')
    tickCount64      = [Environment]::TickCount64
    processName      = $ProcessName
    errors           = [System.Collections.Generic.List[string]]::new()
}
$names = @{}
Get-Process | Where-Object SessionId -eq $sessionId | ForEach-Object { $names[$_.Id] = $_.ProcessName }

try {
    if ([string]::IsNullOrWhiteSpace($OutputDirectory) -or [string]::IsNullOrWhiteSpace($Stamp)) { throw '-OutputDirectory and -Stamp are required.' }
    $result.dpiAware = [HmiCapture.Native]::MakeDpiAware()

    $fg = [HmiCapture.Native]::Foreground()
    $result.foregroundAtStart = [ordered]@{ handle = '0x{0:X}' -f $fg; process = $names[[HmiCapture.Native]::ProcessOf($fg)] }
    $result.focusDisturbed = [HmiCapture.Native]::ProcessOf($fg) -in $ownTree

    $desktopError = 0
    $desktopName = [HmiCapture.Native]::InputDesktopName([ref] $desktopError)
    $logonUi = @(Get-Process -Name LogonUI -ErrorAction SilentlyContinue | Where-Object SessionId -eq $sessionId)
    $result.desktop = Get-LockState -InputDesktop $desktopName -OpenError $desktopError -LogonUiInSession ($logonUi.Count -gt 0) `
        -ForegroundProcess $result.foregroundAtStart.process

    $hmi = @(($ProcessId ? (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) : (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) | Where-Object SessionId -eq $sessionId)
    $result.hmi = [ordered]@{
        running   = $hmi.Count -gt 0
        processes = @($hmi | ForEach-Object { [ordered]@{ id = $_.Id; startTime = $_.StartTime.ToString('o'); responding = $_.Responding } })
    }

    # 1. Pixels first, before the UIA walk can take time.
    $virtual = [HmiCapture.Native]::VirtualScreenBounds()
    $result.virtualScreen = $virtual
    $screen = $null
    try { $screen = Get-ScreenBitmap $virtual } catch { $result.errors.Add("screen: $($_.Exception.Message)") }

    $windows = [HmiCapture.Native]::TopLevelWindows()
    $hmiIds = @($hmi | ForEach-Object Id)
    $hmiWindows = @($windows | Where-Object { $_.ProcessId -in $hmiIds })
    $windowImages = @{}
    foreach ($w in @($hmiWindows | Where-Object { $_.Visible -and -not $_.Minimized })) {
        try {
            $image = Get-WindowBitmap $w.Handle ($w.Right - $w.Left) ($w.Bottom - $w.Top)
            if ($image) { $windowImages[$w.Handle] = $image } else { $result.errors.Add(('window 0x{0:X}: PrintWindow refused' -f $w.Handle)) }
        } catch { $result.errors.Add(('window 0x{0:X}: {1}' -f $w.Handle, $_.Exception.Message)) }
    }

    # 2. The UIA tree of every HMI window, hidden ones included.
    # [int[]] from the start: passing an object[] to the [int[]] parameter would copy it and lose the count.
    [int[]] $budget = @($MaxNodes)
    # Windows every GUI process owns and nobody reads: listed, not walked.
    $plumbingClasses = 'IME', 'MSCTFIME UI', 'GDI+ Hook Window Class', 'tooltips_class32', 'TabletPenServiceHelperClass'
    $trees = [System.Collections.Generic.List[object]]::new()
    foreach ($w in $hmiWindows) {
        $record = Get-WindowRecord $w $names
        if ($w.ClassName -in $plumbingClasses) { $trees.Add($record); continue }
        try {
            $element = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr] $w.Handle)
            $record.uia = Read-UiaTree -Root $element -Budget $budget -MaxDepth $MaxDepth
        } catch { $record.uiaError = $_.Exception.Message }
        $trees.Add($record)
    }
    $result.hmiWindows = $trees.ToArray()
    $result.uiaNodeCount = $MaxNodes - $budget[0]
    $result.uiaTruncated = $budget[0] -le 0
    $result.visibleTexts = Get-VisibleTexts @($trees | Where-Object { $_.visible -and -not $_.minimized } | ForEach-Object { $_.uia })
    try {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        $result.focusedElement = Read-UiaNode $focused
    } catch { $result.focusedElement = $null }

    # Everything else on the desktop that is visible: a dialog from another process belongs to the screen too.
    $result.desktopWindows = @($windows | Where-Object { $_.Visible -and $_.Title } | ForEach-Object { Get-WindowRecord $_ $names })

    # 3. Mask password boxes, then write the images.
    $passwordRects = @($trees | ForEach-Object { Get-UiaNodes $_.uia } | Where-Object { $_.isPassword -and $_.rect })
    $result.maskedPasswordBoxes = $passwordRects.Count
    $images = [System.Collections.Generic.List[object]]::new()
    if ($screen) {
        foreach ($p in $passwordRects) { Set-BlackRectangle $screen ($p.rect[0] - $virtual[0]) ($p.rect[1] - $virtual[1]) $p.rect[2] $p.rect[3] }
        $blank = Test-UniformBitmap $screen
        $file = "$Stamp-screen.png"
        $screen.Save((Join-Path $OutputDirectory $file), [System.Drawing.Imaging.ImageFormat]::Png)
        $images.Add([ordered]@{ kind = 'screen'; file = $file; width = $screen.Width; height = $screen.Height; uniform = $blank })
        $result.screenUniform = $blank
        $screen.Dispose()
    }
    $n = 0
    foreach ($w in $hmiWindows) {
        $image = $windowImages[$w.Handle]
        if (-not $image) { continue }
        foreach ($p in $passwordRects) { Set-BlackRectangle $image ($p.rect[0] - $w.Left) ($p.rect[1] - $w.Top) $p.rect[2] $p.rect[3] }
        $file = "$Stamp-window-$((++$n)).png"
        $image.Save((Join-Path $OutputDirectory $file), [System.Drawing.Imaging.ImageFormat]::Png)
        $images.Add([ordered]@{ kind = 'window'; file = $file; handle = '0x{0:X}' -f $w.Handle; title = $w.Title; width = $image.Width; height = $image.Height; uniform = (Test-UniformBitmap $image) })
        $image.Dispose()
    }
    $result.images = $images.ToArray()

    $fg = [HmiCapture.Native]::Foreground()
    $result.foregroundAtEnd = [ordered]@{ handle = '0x{0:X}' -f $fg; process = $names[[HmiCapture.Native]::ProcessOf($fg)] }
    $result.focusDisturbed = $result.focusDisturbed -or ([HmiCapture.Native]::ProcessOf($fg) -in $ownTree)
} catch {
    $result.errors.Add("fatal: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())")
}
$result.finishedAt = [DateTimeOffset]::Now.ToString('o')
$json = $result | ConvertTo-Json -Depth 100
# Written last and under its final name in one step: the control host polls for this file.
$temp = Join-Path $OutputDirectory "$Stamp-uia.json.partial"
Set-Content -LiteralPath $temp -Value $json -Encoding utf8NoBOM
Move-Item -LiteralPath $temp -Destination (Join-Path $OutputDirectory "$Stamp-uia.json") -Force
