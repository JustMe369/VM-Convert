<#
.SYNOPSIS
    VM Converter Pro Elite - By Codefyhub Technologies
    (Production Edition - V26)
.DESCRIPTION
    Convert Proxmox VMA.ZST <-> VMware VMDK/QCOW2 via Docker.
    Now with pre-flight validation, atomic output, watchdog, real
    progress, job history, CLI/headless mode, multi-threaded qemu,
    log levels, settings, toast notifications, and support bundles.
.PARAMETER InputPath
    Path to the source file. When supplied, the GUI is pre-filled.
    Combine with -Headless for scripting.
.PARAMETER OutputPath
    Desired output file name (extension is normalised). Only the file name
    is used: the output is ALWAYS written next to the source file, because
    that is the folder Docker bind-mounts. Any directory you supply is
    ignored (a warning is printed in headless mode).
.PARAMETER Direction
    PveToVm | VmToPve | Auto (default; inferred from extension).
.PARAMETER Headless
    Run without GUI. Exit code: 0=SUCCESS, 1=FAILED, 2=CANCELLED,
    3=UNCERTAIN. Logs are written to stdout.
.PARAMETER Force
    Overwrite existing output without prompting (headless auto-Yes).
.PARAMETER Quiet
    Suppress toast notifications and the post-job summary dialog.
.EXAMPLE
    .\VM-Convert.ps1
    .\VM-Convert.ps1 -InputPath "D:\VMs\web01.vma.zst"
    .\VM-Convert.ps1 -InputPath "D:\VMs\web01.vmdk" -Headless -Force
.NOTES
    V26 fixes:
      [S1] Preflight probe no longer swallows apk stderr. Install failures
           are categorised and demoted to warnings (conversion retries with
           a visible error); parse failures still hard-abort.
      [S2] Cancel during preflight returns Reason='cancelled' instead of
           masquerading as a validation error.
      [S3] Invoke-SafeProcess re-checks HasExited before killing - a natural
           success racing with the Cancel click is no longer reported as
           CANCELLED.
      [S4] Validation-failure dialogs are suppressed once the form begins
           closing.
    V25 fixes (Tier 1 - post-V24 audit):
      [R1] Segment rename uses Move-Item -Force (reliable overwrite)
      [R2] Extent regex restricted to RW/RDONLY/NOACCESS lines
      [R3] .lck detection catches files AND directories
      [R4] Cancel race: $wasKilled flag
      [R5] Toast icon leak fixed via per-timer Tag reference
      [R6] Toolbar controls disabled during conversion
      [R7] Show-SummaryDialog: unused param removed, Open Folder guarded
      [R8] Version aligned
    V24 adds (Tier 1):
      [#1] Pre-flight source validation (zstd magic / qemu-img info)
      [#2] Disk-space watchdog during conversion
      [#3] Atomic output via .partial temp filename (VM->PVE)
      [#4] Structured job history (vmconvert.history.json)
      [#5] Toast + taskbar flash on completion
      [#6] Post-conversion summary dialog (the "receipt")
      [#7] Log levels (DEBUG/INFO/WARN/ERROR) + live filter
    V24 adds (Tier 2):
      [#8] CLI / headless mode (-InputPath, -Headless, -Force, -Quiet)
      [#9] Real progress percentage (parses qemu-img `(NN/100%)`)
      [#10] File-lock detection on the source and split segments
      [#11] qemu-img speed presets (Safe / Balanced / Fast)
      [#12] Settings dialog + vmconvert.settings.json
      [#13] One-click support bundle (system+log+container -> .zip)
    All V21/V22/V23 fixes retained.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)] [string]$InputPath,
    [Parameter(Mandatory=$false)] [string]$OutputPath,
    [Parameter(Mandatory=$false)]
    [ValidateSet('PveToVm','VmToPve','Auto')] [string]$Direction = 'Auto',
    [switch]$Headless,
    [switch]$Force,
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ============================================================
#  0. VERSION + SCRIPT DIRECTORY
# ============================================================
$ScriptVersion = "3.12.00"
$ScriptBuild   = "2026-10-21"
$ScriptAuthor  = "Codefyhub Technologies"
$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# ============================================================
#  1. CONFIGURATION (defaults; overridable via settings.json)
# ============================================================
$script:ConfigPveToVmImage             = "astroicers/zst2vmdk:latest"
$script:ConfigVmToPveImage             = "ubuntu:22.04"
$script:ConfigToolsImage               = "alpine:3.19"
$script:ConfigShowDetailedProgress     = $false
$script:ConfigAutoCleanupLeftovers     = $true
$script:ConfigKeepIntermediatesOnFailure = $false
$script:ConfigMinOutputBytes           = 1MB
$script:ConfigMinLogLevel              = 'INFO'
$script:ConfigQemuMode                 = 'Balanced'
$script:ConfigRunPreflight             = $true
$script:ConfigShowSummaryDialog        = $true
$script:ConfigToastOnComplete          = $true
$script:ConfigWatchdogMinFreeBytes     = [long](2GB)
$script:ConfigSettingsFile             = Join-Path $script:ScriptDir 'vmconvert.settings.json'
$script:ConfigHistoryFile              = Join-Path $script:ScriptDir 'vmconvert.history.json'

# ============================================================
#  2. LOAD SETTINGS
# ============================================================
function Load-Settings {
    $script:SettingsLoadError = $null
    if (-not (Test-Path -LiteralPath $script:ConfigSettingsFile)) { return }
    $s = $null
    try {
        $s = Get-Content -LiteralPath $script:ConfigSettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $script:SettingsLoadError = $_.Exception.Message
        return
    }
    if ($null -eq $s) { return }

    # Each property applied on its own - one bad value must not silently
    # revert every setting listed after it.
    $bad = New-Object System.Collections.Generic.List[string]

    if ($null -ne $s.PSObject.Properties['PveToVmImage']) { try { $script:ConfigPveToVmImage = [string]$s.PveToVmImage } catch { $null = $bad.Add('PveToVmImage') } }
    if ($null -ne $s.PSObject.Properties['VmToPveImage']) { try { $script:ConfigVmToPveImage = [string]$s.VmToPveImage } catch { $null = $bad.Add('VmToPveImage') } }
    if ($null -ne $s.PSObject.Properties['ToolsImage'])   { try { $script:ConfigToolsImage   = [string]$s.ToolsImage }   catch { $null = $bad.Add('ToolsImage') } }
    if ($null -ne $s.PSObject.Properties['MinOutputBytes']) { try { $script:ConfigMinOutputBytes = [long]$s.MinOutputBytes } catch { $null = $bad.Add('MinOutputBytes') } }
    if ($null -ne $s.PSObject.Properties['MinLogLevel'])  { try { $script:ConfigMinLogLevel  = [string]$s.MinLogLevel }  catch { $null = $bad.Add('MinLogLevel') } }
    if ($null -ne $s.PSObject.Properties['QemuMode'])     { try { $script:ConfigQemuMode     = [string]$s.QemuMode }     catch { $null = $bad.Add('QemuMode') } }
    if ($null -ne $s.PSObject.Properties['RunPreflight'])        { try { $script:ConfigRunPreflight        = [bool]$s.RunPreflight }        catch { $null = $bad.Add('RunPreflight') } }
    if ($null -ne $s.PSObject.Properties['ShowSummaryDialog'])   { try { $script:ConfigShowSummaryDialog   = [bool]$s.ShowSummaryDialog }   catch { $null = $bad.Add('ShowSummaryDialog') } }
    if ($null -ne $s.PSObject.Properties['ToastOnComplete'])     { try { $script:ConfigToastOnComplete     = [bool]$s.ToastOnComplete }     catch { $null = $bad.Add('ToastOnComplete') } }
    if ($null -ne $s.PSObject.Properties['WatchdogMinFreeGB'])   { try { $script:ConfigWatchdogMinFreeBytes = [long]([double]$s.WatchdogMinFreeGB * 1GB) } catch { $null = $bad.Add('WatchdogMinFreeGB') } }
    if ($null -ne $s.PSObject.Properties['ShowDetailedProgress']) { try { $script:ConfigShowDetailedProgress = [bool]$s.ShowDetailedProgress } catch { $null = $bad.Add('ShowDetailedProgress') } }
    if ($null -ne $s.PSObject.Properties['AutoCleanupLeftovers']) { try { $script:ConfigAutoCleanupLeftovers = [bool]$s.AutoCleanupLeftovers } catch { $null = $bad.Add('AutoCleanupLeftovers') } }
    if ($null -ne $s.PSObject.Properties['KeepIntermediatesOnFailure']) { try { $script:ConfigKeepIntermediatesOnFailure = [bool]$s.KeepIntermediatesOnFailure } catch { $null = $bad.Add('KeepIntermediatesOnFailure') } }

    # Range / vocabulary checks so a hand-edited file cannot disable the
    # safety net or leave an unknown mode.
    if ($script:ConfigMinOutputBytes -lt 1) {
        $null = $bad.Add('MinOutputBytes'); $script:ConfigMinOutputBytes = 1MB
    }
    if ($script:ConfigWatchdogMinFreeBytes -le 0) {
        $null = $bad.Add('WatchdogMinFreeGB'); $script:ConfigWatchdogMinFreeBytes = [long](2GB)
    }
    if (@('DEBUG','INFO','WARN','ERROR') -notcontains $script:ConfigMinLogLevel) {
        $null = $bad.Add('MinLogLevel'); $script:ConfigMinLogLevel = 'INFO'
    }
    if (@('Safe','Balanced','Fast') -notcontains $script:ConfigQemuMode) {
        $null = $bad.Add('QemuMode'); $script:ConfigQemuMode = 'Balanced'
    }

    if ($bad.Count -gt 0) {
        $script:SettingsLoadError = "Ignored invalid value(s) for: " + (($bad | Select-Object -Unique) -join ', ')
    }
}

function Save-Settings {
    try {
        $data = [ordered]@{
            PveToVmImage               = $script:ConfigPveToVmImage
            VmToPveImage               = $script:ConfigVmToPveImage
            ToolsImage                 = $script:ConfigToolsImage
            MinOutputBytes             = $script:ConfigMinOutputBytes
            MinLogLevel                = $script:ConfigMinLogLevel
            QemuMode                   = $script:ConfigQemuMode
            RunPreflight               = $script:ConfigRunPreflight
            ShowSummaryDialog          = $script:ConfigShowSummaryDialog
            ToastOnComplete            = $script:ConfigToastOnComplete
            WatchdogMinFreeGB          = [math]::Round($script:ConfigWatchdogMinFreeBytes / 1GB, 2)
            ShowDetailedProgress       = $script:ConfigShowDetailedProgress
            AutoCleanupLeftovers       = $script:ConfigAutoCleanupLeftovers
            KeepIntermediatesOnFailure = $script:ConfigKeepIntermediatesOnFailure
        }
        # Temp-file + rename so an interrupted write cannot truncate settings.
        $tmp = $script:ConfigSettingsFile + '.tmp'
        $data | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:ConfigSettingsFile -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

Load-Settings

# ============================================================
#  3. THEME
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$colorBg             = [System.Drawing.ColorTranslator]::FromHtml("#0D0F14")
$colorPanel          = [System.Drawing.ColorTranslator]::FromHtml("#171B24")
$colorCard           = $colorPanel
$colorBorderSoft     = [System.Drawing.ColorTranslator]::FromHtml("#1F2531")
$colorBorder         = [System.Drawing.ColorTranslator]::FromHtml("#2A3140")
$colorText           = [System.Drawing.ColorTranslator]::FromHtml("#E6EAF2")
$colorTextMuted      = [System.Drawing.ColorTranslator]::FromHtml("#8A93A6")
$colorAccent         = [System.Drawing.ColorTranslator]::FromHtml("#2F6FED")
$colorAccentHover    = [System.Drawing.ColorTranslator]::FromHtml("#4A85F5")
$colorAccentSoft     = [System.Drawing.ColorTranslator]::FromHtml("#1B2740")
$colorSuccess        = [System.Drawing.ColorTranslator]::FromHtml("#3FB950")
$colorError          = [System.Drawing.ColorTranslator]::FromHtml("#F85149")
$colorWarning        = [System.Drawing.ColorTranslator]::FromHtml("#D9A441")
$colorCancel         = [System.Drawing.ColorTranslator]::FromHtml("#C0392B")
$colorCancelHover    = [System.Drawing.ColorTranslator]::FromHtml("#DD4B3E")
$colorLogBg          = [System.Drawing.ColorTranslator]::FromHtml("#090B0F")
$colorDropZone       = [System.Drawing.ColorTranslator]::FromHtml("#11141B")
$colorDropZoneHover  = [System.Drawing.ColorTranslator]::FromHtml("#18243A")

$glyphArrow    = [string][char]0x2192
$glyphDot      = [string][char]0x25CF
$glyphGear     = [string][char]0x2699
$glyphSwap     = [string][char]0x21C4
$glyphMinus    = [string][char]0x2013
$glyphCross    = [string][char]0x2715

function Set-RoundedRegion {
    param(
        [System.Windows.Forms.Control]$Control,
        [int]$Radius = 8
    )
    try {
        if ($null -eq $Control) { return }
        if ($Control.Width -le 0 -or $Control.Height -le 0) { return }
        $d = $Radius * 2
        if ($Control.Width -le $d -or $Control.Height -le $d) { return }
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc(($Control.Width - $d), 0, $d, $d, 270, 90)
        $path.AddArc(($Control.Width - $d), ($Control.Height - $d), $d, $d, 0, 90)
        $path.AddArc(0, ($Control.Height - $d), $d, $d, 90, 90)
        $path.CloseFigure()
        $Control.Region = New-Object System.Drawing.Region($path)
        $path.Dispose()
    } catch { }
}

$cardPaint = {
    param($s, $e)
    try {
        $cfg = $s.Tag
        $radius = [int]$cfg.Radius
        $d = $radius * 2
        $w = $s.ClientSize.Width - 1
        $h = $s.ClientSize.Height - 1
        if ($w -le $d -or $h -le $d) { return }
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $p.AddArc(0, 0, $d, $d, 180, 90)
        $p.AddArc(($w - $d), 0, $d, $d, 270, 90)
        $p.AddArc(($w - $d), ($h - $d), $d, $d, 0, 90)
        $p.AddArc(0, ($h - $d), $d, $d, 90, 90)
        $p.CloseFigure()
        $pen = New-Object System.Drawing.Pen($cfg.Border, 1)
        $g.DrawPath($pen, $p)
        $pen.Dispose()
        $p.Dispose()
    } catch { }
}

$hoverIn  = { param($s, $e) if ($s.Enabled) { $s.BackColor = $s.Tag.Hover } }
$hoverOut = { param($s, $e) if ($s.Enabled) { $s.BackColor = $s.Tag.Base  } }

function Set-FlatButton {
    param(
        [System.Windows.Forms.Button]$Button,
        [System.Drawing.Color]$Back = $colorPanel,
        [System.Drawing.Color]$HoverBack = $colorBorder,
        [System.Drawing.Color]$Fore = $colorText,
        [System.Drawing.Color]$BorderColor = $colorBorder,
        [int]$BorderSize = 0,
        [int]$Radius = 8,
        [System.Windows.Forms.Cursor]$Cursor = [System.Windows.Forms.Cursors]::Hand
    )
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize  = $BorderSize
    $Button.FlatAppearance.BorderColor = $BorderColor
    $Button.BackColor = $Back
    $Button.ForeColor = $Fore
    $Button.Cursor    = $Cursor
    $Button.Tag       = @{ Base = $Back; Hover = $HoverBack }
    Set-RoundedRegion -Control $Button -Radius $Radius
    $Button.Add_MouseEnter($hoverIn)
    $Button.Add_MouseLeave($hoverOut)
}

function Set-Card {
    param(
        [System.Windows.Forms.Control]$Control,
        [int]$Radius = 10,
        [System.Drawing.Color]$Back = $colorPanel,
        [System.Drawing.Color]$BorderColor = $colorBorder
    )
    $Control.BackColor = $Back
    $Control.Tag       = @{ Radius = $Radius; Border = $BorderColor }
    Set-RoundedRegion -Control $Control -Radius $Radius
    $Control.Add_Paint($cardPaint)
}

function Update-DirectionTiles {
    $pveActive = $rbPveToVm.Checked
    $btnDirPve.BackColor = if ($pveActive) { $colorAccentSoft } else { $colorPanel }
    $btnDirPve.ForeColor = if ($pveActive) { $colorText } else { $colorTextMuted }
    $btnDirPve.FlatAppearance.BorderSize  = if ($pveActive) { 2 } else { 1 }
    $btnDirPve.FlatAppearance.BorderColor = if ($pveActive) { $colorAccent } else { $colorBorder }

    $vmActive = $rbVmToPve.Checked
    $btnDirVm.BackColor = if ($vmActive) { $colorAccentSoft } else { $colorPanel }
    $btnDirVm.ForeColor = if ($vmActive) { $colorText } else { $colorTextMuted }
    $btnDirVm.FlatAppearance.BorderSize  = if ($vmActive) { 2 } else { 1 }
    $btnDirVm.FlatAppearance.BorderColor = if ($vmActive) { $colorAccent } else { $colorBorder }
}

# ============================================================
#  4. GLOBALS
# ============================================================
$script:CurrentProcess         = $null
$script:CancelRequested        = $false
$script:ConversionStart        = $null
$script:ContainerName          = $null
$script:LastProcessOutput      = ''
$script:FormIsClosing          = $false
$script:AnsiRx                 = [regex]'\x1b\[[0-9;?]*[a-zA-Z]'
$script:MaxOutputCapture       = 1MB
$script:LogLineCount           = 0
$script:HeadlessMode           = $false
$script:QuietMode              = $false
$script:ForceOverwrite         = $false
$script:CurrentProgressPercent = -1
$script:WatchdogDirectory      = $null
$script:WatchdogMinFreeBytes   = [long](2GB)
$script:WatchdogLastCheck      = [DateTime]::MinValue
$script:WatchdogTripped        = $false
$script:LastJobResult          = $null

# ============================================================
#  5. FORM
# ============================================================
$form                    = New-Object System.Windows.Forms.Form
$form.Text               = "VM Converter Pro v$ScriptVersion"
$form.Size               = New-Object System.Drawing.Size(820, 895)
$form.MinimumSize        = New-Object System.Drawing.Size(820, 895)
$form.StartPosition      = "CenterScreen"
$form.FormBorderStyle    = [System.Windows.Forms.FormBorderStyle]::None
$form.BackColor          = $colorBg
$form.ForeColor          = $colorText
$form.AllowDrop          = $true
$form.KeyPreview         = $true
$form.Font               = New-Object System.Drawing.Font("Segoe UI", 9)

# ============================================================
#  6. TITLE BAR
# ============================================================
$titleBar                = New-Object System.Windows.Forms.Panel
$titleBar.Size           = New-Object System.Drawing.Size(820, 48)
$titleBar.BackColor      = $colorBg
$titleBar.Dock           = [System.Windows.Forms.DockStyle]::Top
$form.Controls.Add($titleBar)

$titleAccent             = New-Object System.Windows.Forms.Panel
$titleAccent.Size        = New-Object System.Drawing.Size(820, 2)
$titleAccent.BackColor   = $colorAccent
$titleAccent.Dock        = [System.Windows.Forms.DockStyle]::Bottom
$titleBar.Controls.Add($titleAccent)

$lblTitle                = New-Object System.Windows.Forms.Label
$lblTitle.Text           = "VM CONVERTER PRO v$ScriptVersion  -  $ScriptAuthor"
$lblTitle.Font           = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor      = $colorText
$lblTitle.Location       = New-Object System.Drawing.Point(22, 15)
$lblTitle.AutoSize       = $false
$lblTitle.Size           = New-Object System.Drawing.Size(620, 22)
$lblTitle.AutoEllipsis   = $true
$lblTitle.TextAlign      = [System.Drawing.ContentAlignment]::MiddleLeft
$titleBar.Controls.Add($lblTitle)

$btnSettings             = New-Object System.Windows.Forms.Button
$btnSettings.Text        = $glyphGear
$btnSettings.Size        = New-Object System.Drawing.Size(44, 44)
$btnSettings.Location    = New-Object System.Drawing.Point(680, 2)
$btnSettings.Font        = New-Object System.Drawing.Font("Segoe UI", 12)
Set-FlatButton -Button $btnSettings -Back $colorBg -HoverBack $colorBorderSoft -Fore $colorTextMuted -BorderSize 0 -Radius 6
$titleBar.Controls.Add($btnSettings)

$btnClose                = New-Object System.Windows.Forms.Button
$btnClose.Text           = $glyphCross
$btnClose.Size           = New-Object System.Drawing.Size(44, 44)
$btnClose.Location       = New-Object System.Drawing.Point(772, 2)
$btnClose.Font           = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
Set-FlatButton -Button $btnClose -Back $colorBg -HoverBack $colorCancel -Fore $colorText -BorderSize 0 -Radius 6
$btnClose.Add_Click({ $form.Close() })
$titleBar.Controls.Add($btnClose)

$btnMinimize             = New-Object System.Windows.Forms.Button
$btnMinimize.Text        = $glyphMinus
$btnMinimize.Size        = New-Object System.Drawing.Size(44, 44)
$btnMinimize.Location    = New-Object System.Drawing.Point(726, 2)
$btnMinimize.Font        = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
Set-FlatButton -Button $btnMinimize -Back $colorBg -HoverBack $colorBorderSoft -Fore $colorTextMuted -BorderSize 0 -Radius 6
$btnMinimize.Add_Click({ $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized })
$titleBar.Controls.Add($btnMinimize)

$script:drag       = $false
$script:startMouse = [System.Drawing.Point]::Empty
$script:startForm  = [System.Drawing.Point]::Empty

$dragDown = {
    $script:drag       = $true
    $script:startMouse = [System.Windows.Forms.Cursor]::Position
    $script:startForm  = $form.Location
}
$dragMove = {
    if ($script:drag) {
        $cur = [System.Windows.Forms.Cursor]::Position
        $form.Location = New-Object System.Drawing.Point(
            ($script:startForm.X + ($cur.X - $script:startMouse.X)),
            ($script:startForm.Y + ($cur.Y - $script:startMouse.Y))
        )
    }
}
$dragUp = { $script:drag = $false }

foreach ($ctrl in @($titleBar, $titleAccent, $lblTitle)) {
    $ctrl.Add_MouseDown($dragDown)
    $ctrl.Add_MouseMove($dragMove)
    $ctrl.Add_MouseUp($dragUp)
}

# ============================================================
#  7. DOCKER STATUS
# ============================================================
$pDockerStatus               = New-Object System.Windows.Forms.Panel
$pDockerStatus.Location      = New-Object System.Drawing.Point(20, 62)
$pDockerStatus.Size          = New-Object System.Drawing.Size(320, 32)
Set-Card -Control $pDockerStatus -Radius 10
$form.Controls.Add($pDockerStatus)

$lblDockerDot                = New-Object System.Windows.Forms.Label
$lblDockerDot.Text           = $glyphDot
$lblDockerDot.Font           = New-Object System.Drawing.Font("Segoe UI", 11)
$lblDockerDot.ForeColor      = $colorWarning
$lblDockerDot.Location       = New-Object System.Drawing.Point(14, 5)
$lblDockerDot.AutoSize       = $true
$pDockerStatus.Controls.Add($lblDockerDot)

$lblDockerStatus             = New-Object System.Windows.Forms.Label
$lblDockerStatus.Text        = "Checking Docker Engine..."
$lblDockerStatus.Font        = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblDockerStatus.ForeColor   = $colorWarning
$lblDockerStatus.Location    = New-Object System.Drawing.Point(36, 8)
$lblDockerStatus.AutoSize    = $true
$pDockerStatus.Controls.Add($lblDockerStatus)

# ============================================================
#  8. DIRECTION GROUP
# ============================================================
$grpMode                 = New-Object System.Windows.Forms.Panel
$grpMode.Location        = New-Object System.Drawing.Point(20, 106)
$grpMode.Size            = New-Object System.Drawing.Size(780, 100)
Set-Card -Control $grpMode -Radius 12
$form.Controls.Add($grpMode)

$lblDirTitle             = New-Object System.Windows.Forms.Label
$lblDirTitle.Text        = "1.  SELECT CONVERSION DIRECTION"
$lblDirTitle.Font        = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblDirTitle.ForeColor   = $colorTextMuted
$lblDirTitle.Location    = New-Object System.Drawing.Point(18, 10)
$lblDirTitle.AutoSize    = $true
$grpMode.Controls.Add($lblDirTitle)

$rbPveToVm               = New-Object System.Windows.Forms.RadioButton
$rbPveToVm.Text          = "Proxmox (.vma.zst)  -->  VMware (.vmdk)"
$rbPveToVm.Location      = New-Object System.Drawing.Point(18, 34)
$rbPveToVm.Size          = New-Object System.Drawing.Size(340, 24)
$rbPveToVm.Font          = New-Object System.Drawing.Font("Segoe UI", 10)
$rbPveToVm.Checked       = $true
$rbPveToVm.Visible       = $false
$grpMode.Controls.Add($rbPveToVm)

$rbVmToPve               = New-Object System.Windows.Forms.RadioButton
$rbVmToPve.Text          = "VMware (.vmdk)  -->  Proxmox (.qcow2)"
$rbVmToPve.Location      = New-Object System.Drawing.Point(398, 34)
$rbVmToPve.Size          = New-Object System.Drawing.Size(340, 24)
$rbVmToPve.Font          = New-Object System.Drawing.Font("Segoe UI", 10)
$rbVmToPve.Visible       = $false
$grpMode.Controls.Add($rbVmToPve)

$btnDirPve               = New-Object System.Windows.Forms.Button
$btnDirPve.Text          = "Proxmox (.vma.zst)  -->  VMware (.vmdk)"
$btnDirPve.Font          = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnDirPve.Location      = New-Object System.Drawing.Point(18, 34)
$btnDirPve.Size          = New-Object System.Drawing.Size(372, 52)
$btnDirPve.FlatStyle     = 'Flat'
$btnDirPve.FlatAppearance.BorderSize  = 2
$btnDirPve.FlatAppearance.BorderColor = $colorAccent
$btnDirPve.BackColor     = $colorAccentSoft
$btnDirPve.ForeColor     = $colorText
$btnDirPve.Cursor        = [System.Windows.Forms.Cursors]::Hand
$grpMode.Controls.Add($btnDirPve)

$btnDirVm                = New-Object System.Windows.Forms.Button
$btnDirVm.Text           = "VMware (.vmdk)  -->  Proxmox (.qcow2)"
$btnDirVm.Font           = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnDirVm.Location       = New-Object System.Drawing.Point(398, 34)
$btnDirVm.Size           = New-Object System.Drawing.Size(372, 52)
$btnDirVm.FlatStyle      = 'Flat'
$btnDirVm.FlatAppearance.BorderSize  = 1
$btnDirVm.FlatAppearance.BorderColor = $colorBorder
$btnDirVm.BackColor      = $colorPanel
$btnDirVm.ForeColor      = $colorTextMuted
$btnDirVm.Cursor         = [System.Windows.Forms.Cursors]::Hand
$grpMode.Controls.Add($btnDirVm)

$btnDirPve.Add_Click({ $rbPveToVm.Checked = $true })
$btnDirVm.Add_Click({ $rbVmToPve.Checked  = $true })

$tileHoverIn  = {
    param($s, $e)
    $active = (($s -eq $btnDirPve) -and $rbPveToVm.Checked) -or (($s -eq $btnDirVm) -and $rbVmToPve.Checked)
    if (-not $active) { $s.BackColor = $colorBorderSoft; $s.ForeColor = $colorText }
}
$tileHoverOut = { param($s, $e) Update-DirectionTiles }

foreach ($tile in @($btnDirPve, $btnDirVm)) {
    Set-RoundedRegion -Control $tile -Radius 9
    $tile.Add_MouseEnter($tileHoverIn)
    $tile.Add_MouseLeave($tileHoverOut)
}
Update-DirectionTiles

# ============================================================
#  9. DROP ZONE
# ============================================================
$dropZone                = New-Object System.Windows.Forms.Panel
$dropZone.Location       = New-Object System.Drawing.Point(20, 218)
$dropZone.Size           = New-Object System.Drawing.Size(780, 88)
Set-Card -Control $dropZone -Radius 12 -Back $colorDropZone -BorderColor $colorBorder
$dropZone.AllowDrop      = $true
$form.Controls.Add($dropZone)

$lblDropText             = New-Object System.Windows.Forms.Label
$lblDropText.Text        = "DRAG & DROP YOUR FILE HERE`nOR CLICK TO BROWSE"
$lblDropText.Font        = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$lblDropText.ForeColor   = $colorTextMuted
$lblDropText.BackColor   = [System.Drawing.Color]::Transparent
$lblDropText.TextAlign   = "MiddleCenter"
$lblDropText.Dock        = [System.Windows.Forms.DockStyle]::Fill
$lblDropText.Cursor      = [System.Windows.Forms.Cursors]::Hand
$lblDropText.AllowDrop   = $true
$dropZone.Controls.Add($lblDropText)

$txtFilePath             = New-Object System.Windows.Forms.TextBox
$txtFilePath.Location    = New-Object System.Drawing.Point(20, 314)
$txtFilePath.Size        = New-Object System.Drawing.Size(780, 26)
$txtFilePath.BackColor   = $colorPanel
$txtFilePath.ForeColor   = $colorSuccess
$txtFilePath.ReadOnly    = $true
$txtFilePath.BorderStyle = 'FixedSingle'
$txtFilePath.Font        = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($txtFilePath)

# ============================================================
#  10. OUTPUT NAME
# ============================================================
$lblOutput               = New-Object System.Windows.Forms.Label
$lblOutput.Text          = "2.  CUSTOM OUTPUT FILENAME"
$lblOutput.Location      = New-Object System.Drawing.Point(20, 352)
$lblOutput.Size          = New-Object System.Drawing.Size(300, 18)
$lblOutput.Font          = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblOutput.ForeColor     = $colorTextMuted
$form.Controls.Add($lblOutput)

$txtOutputName           = New-Object System.Windows.Forms.TextBox
$txtOutputName.Location  = New-Object System.Drawing.Point(20, 374)
$txtOutputName.Size      = New-Object System.Drawing.Size(780, 30)
$txtOutputName.BackColor = $colorPanel
$txtOutputName.ForeColor = [System.Drawing.Color]::White
$txtOutputName.BorderStyle = 'FixedSingle'
$txtOutputName.Font      = New-Object System.Drawing.Font("Segoe UI", 12)
$form.Controls.Add($txtOutputName)

# ============================================================
#  11. ACTION BUTTONS
# ============================================================
$btnConvert              = New-Object System.Windows.Forms.Button
$btnConvert.Text         = "START CONVERSION"
$btnConvert.Font         = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$btnConvert.Location     = New-Object System.Drawing.Point(20, 418)
$btnConvert.Size         = New-Object System.Drawing.Size(390, 52)
$btnConvert.BackColor    = $colorAccent
$btnConvert.ForeColor    = [System.Drawing.Color]::White
$btnConvert.FlatStyle    = 'Flat'
$btnConvert.FlatAppearance.BorderSize = 0
$btnConvert.Cursor       = [System.Windows.Forms.Cursors]::Hand
$btnConvert.Add_MouseEnter({ if ($btnConvert.Enabled) { $btnConvert.BackColor = $colorAccentHover } })
$btnConvert.Add_MouseLeave({ if ($btnConvert.Enabled) { $btnConvert.BackColor = $colorAccent } })
Set-RoundedRegion -Control $btnConvert -Radius 10
$form.Controls.Add($btnConvert)

$btnCancel               = New-Object System.Windows.Forms.Button
$btnCancel.Text          = "CANCEL"
$btnCancel.Font          = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnCancel.Location      = New-Object System.Drawing.Point(418, 418)
$btnCancel.Size          = New-Object System.Drawing.Size(140, 52)
$btnCancel.BackColor     = $colorCancel
$btnCancel.ForeColor     = [System.Drawing.Color]::White
$btnCancel.FlatStyle     = 'Flat'
$btnCancel.FlatAppearance.BorderSize = 0
$btnCancel.Visible       = $false
$btnCancel.Cursor        = [System.Windows.Forms.Cursors]::Hand
$btnCancel.Add_MouseEnter({ if ($btnCancel.Enabled) { $btnCancel.BackColor = $colorCancelHover } })
$btnCancel.Add_MouseLeave({ if ($btnCancel.Enabled) { $btnCancel.BackColor = $colorCancel } })
Set-RoundedRegion -Control $btnCancel -Radius 10
$form.Controls.Add($btnCancel)

$btnCopyLog              = New-Object System.Windows.Forms.Button
$btnCopyLog.Text         = "COPY LOG"
$btnCopyLog.Location     = New-Object System.Drawing.Point(566, 418)
$btnCopyLog.Size         = New-Object System.Drawing.Size(105, 52)
$btnCopyLog.Font         = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
Set-FlatButton -Button $btnCopyLog -Back $colorPanel -HoverBack $colorBorderSoft -Fore $colorText -BorderColor $colorBorder -BorderSize 1 -Radius 10
$form.Controls.Add($btnCopyLog)

$btnSaveLog              = New-Object System.Windows.Forms.Button
$btnSaveLog.Text         = "SAVE LOG"
$btnSaveLog.Location     = New-Object System.Drawing.Point(679, 418)
$btnSaveLog.Size         = New-Object System.Drawing.Size(105, 52)
$btnSaveLog.Font         = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
Set-FlatButton -Button $btnSaveLog -Back $colorPanel -HoverBack $colorBorderSoft -Fore $colorText -BorderColor $colorBorder -BorderSize 1 -Radius 10
$form.Controls.Add($btnSaveLog)

# ============================================================
#  12. TOOLBAR (log level / qemu mode / history / support)
# ============================================================
$lblLogLevel             = New-Object System.Windows.Forms.Label
$lblLogLevel.Text        = "Log:"
$lblLogLevel.Location    = New-Object System.Drawing.Point(20, 491)
$lblLogLevel.Size        = New-Object System.Drawing.Size(30, 18)
$lblLogLevel.ForeColor   = $colorTextMuted
$form.Controls.Add($lblLogLevel)

$cmbLogLevel             = New-Object System.Windows.Forms.ComboBox
$cmbLogLevel.Location    = New-Object System.Drawing.Point(52, 487)
$cmbLogLevel.Size        = New-Object System.Drawing.Size(92, 24)
$cmbLogLevel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbLogLevel.BackColor   = $colorPanel
$cmbLogLevel.ForeColor   = $colorText
$cmbLogLevel.FlatStyle   = 'Flat'
$cmbLogLevel.Items.AddRange([string[]]@('DEBUG','INFO','WARN','ERROR'))
if ($cmbLogLevel.Items.Contains($script:ConfigMinLogLevel)) { $cmbLogLevel.SelectedItem = $script:ConfigMinLogLevel }
else { $cmbLogLevel.SelectedItem = 'INFO'; $script:ConfigMinLogLevel = 'INFO' }
$form.Controls.Add($cmbLogLevel)

$lblQemuMode             = New-Object System.Windows.Forms.Label
$lblQemuMode.Text        = "Speed:"
$lblQemuMode.Location    = New-Object System.Drawing.Point(162, 491)
$lblQemuMode.Size        = New-Object System.Drawing.Size(45, 18)
$lblQemuMode.ForeColor   = $colorTextMuted
$lblQemuMode.Visible     = $false
$form.Controls.Add($lblQemuMode)

$cmbQemuMode             = New-Object System.Windows.Forms.ComboBox
$cmbQemuMode.Location    = New-Object System.Drawing.Point(209, 487)
$cmbQemuMode.Size        = New-Object System.Drawing.Size(110, 24)
$cmbQemuMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbQemuMode.BackColor   = $colorPanel
$cmbQemuMode.ForeColor   = $colorText
$cmbQemuMode.FlatStyle   = 'Flat'
$cmbQemuMode.Items.AddRange([string[]]@('Safe','Balanced','Fast'))
if ($cmbQemuMode.Items.Contains($script:ConfigQemuMode)) { $cmbQemuMode.SelectedItem = $script:ConfigQemuMode }
else { $cmbQemuMode.SelectedItem = 'Balanced'; $script:ConfigQemuMode = 'Balanced' }
$cmbQemuMode.Visible     = $false
$form.Controls.Add($cmbQemuMode)

$btnHistory              = New-Object System.Windows.Forms.Button
$btnHistory.Text         = "HISTORY"
$btnHistory.Location     = New-Object System.Drawing.Point(420, 484)
$btnHistory.Size         = New-Object System.Drawing.Size(100, 28)
$btnHistory.Font         = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
Set-FlatButton -Button $btnHistory -Back $colorPanel -HoverBack $colorBorderSoft -Fore $colorText -BorderColor $colorBorder -BorderSize 1 -Radius 8
$form.Controls.Add($btnHistory)

$btnSupport              = New-Object System.Windows.Forms.Button
$btnSupport.Text         = "SUPPORT"
$btnSupport.Location     = New-Object System.Drawing.Point(528, 484)
$btnSupport.Size         = New-Object System.Drawing.Size(100, 28)
$btnSupport.Font         = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
Set-FlatButton -Button $btnSupport -Back $colorPanel -HoverBack $colorBorderSoft -Fore $colorText -BorderColor $colorBorder -BorderSize 1 -Radius 8
$form.Controls.Add($btnSupport)

$btnSettings2            = New-Object System.Windows.Forms.Button
$btnSettings2.Text       = "SETTINGS"
$btnSettings2.Location   = New-Object System.Drawing.Point(636, 484)
$btnSettings2.Size       = New-Object System.Drawing.Size(100, 28)
$btnSettings2.Font       = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
Set-FlatButton -Button $btnSettings2 -Back $colorPanel -HoverBack $colorBorderSoft -Fore $colorText -BorderColor $colorBorder -BorderSize 1 -Radius 8
$form.Controls.Add($btnSettings2)

# ============================================================
#  13. PROGRESS BAR + LOG
# ============================================================
$progressBar             = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location    = New-Object System.Drawing.Point(20, 524)
$progressBar.Size        = New-Object System.Drawing.Size(780, 6)
$progressBar.Style       = [System.Windows.Forms.ProgressBarStyle]::Marquee
$progressBar.MarqueeAnimationSpeed = 0
$progressBar.Minimum     = 0
$progressBar.Maximum     = 100
$progressBar.Value       = 0
$progressBar.Visible     = $false
$form.Controls.Add($progressBar)

$txtLog                  = New-Object System.Windows.Forms.RichTextBox
$txtLog.Location         = New-Object System.Drawing.Point(20, 540)
$txtLog.Size             = New-Object System.Drawing.Size(780, 340)
$txtLog.BackColor        = $colorLogBg
$txtLog.ForeColor        = $colorText
$txtLog.Font             = New-Object System.Drawing.Font("Consolas", 10)
$txtLog.ReadOnly         = $true
$txtLog.BorderStyle      = 'None'
$txtLog.WordWrap         = $false
$txtLog.DetectUrls       = $false
$form.Controls.Add($txtLog)
Set-RoundedRegion -Control $txtLog -Radius 10

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($btnConvert,    "Start the conversion  (Enter)")
$toolTip.SetToolTip($btnCancel,     "Cancel the running conversion  (Esc)")
$toolTip.SetToolTip($btnCopyLog,    "Copy the full log to the clipboard")
$toolTip.SetToolTip($btnSaveLog,    "Save the log to a file")
$toolTip.SetToolTip($btnHistory,    "View recent conversion history")
$toolTip.SetToolTip($btnSupport,    "Export a support bundle for troubleshooting")
$toolTip.SetToolTip($btnSettings,   "Open settings")
$toolTip.SetToolTip($btnSettings2,  "Open settings")
$toolTip.SetToolTip($dropZone,      "Drop a .vma.zst or .vmdk disk here, or click to browse")
$toolTip.SetToolTip($lblDropText,   "Drop a .vma.zst or .vmdk disk here, or click to browse")
$toolTip.SetToolTip($btnDirPve,     "Convert a Proxmox backup (.vma.zst) into a VMware disk (.vmdk)")
$toolTip.SetToolTip($btnDirVm,      "Convert a VMware disk (.vmdk) into a Proxmox disk (.qcow2)")
$toolTip.SetToolTip($cmbLogLevel,   "Minimum log verbosity shown in the log pane")
$toolTip.SetToolTip($cmbQemuMode,   "qemu-img worker performance profile")
$toolTip.SetToolTip($txtOutputName, "Output file name - the extension is added automatically")

# ============================================================
#  14. LOG LEVEL MAPPING
# ============================================================
function Get-LevelRank {
    param([string]$Level)
    switch ($Level.ToUpperInvariant()) {
        'DEBUG' { return 0 }
        'INFO'  { return 1 }
        'WARN'  { return 2 }
        'ERROR' { return 3 }
        default { return 1 }
    }
}

function Write-Log {
    param(
        [string]$Message,
        [System.Drawing.Color]$Color,
        [ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$Level
    )
    if ($script:FormIsClosing) { return }
    if ($null -eq $Message) { return }

    if (-not $PSBoundParameters.ContainsKey('Level')) {
        if     ($Color -eq $colorWarning)   { $Level = 'WARN'  }
        elseif ($Color -eq $colorError)     { $Level = 'ERROR' }
        elseif ($Color -eq $colorTextMuted) { $Level = 'DEBUG' }
        else                                { $Level = 'INFO'  }
    }
    if (-not $PSBoundParameters.ContainsKey('Color')) {
        switch ($Level) {
            'DEBUG' { $Color = $colorTextMuted }
            'WARN'  { $Color = $colorWarning   }
            'ERROR' { $Color = $colorError     }
            default { $Color = $colorText      }
        }
    }
    if ((Get-LevelRank $Level) -lt (Get-LevelRank $script:ConfigMinLogLevel)) { return }

    $prefix = switch ($Level) {
        'DEBUG' { '[DBG ] ' }
        'WARN'  { '[WARN] ' }
        'ERROR' { '[ERR ] ' }
        default { ''       }
    }

    foreach ($line in ($Message -split "[\r\n]+")) {
        if ($line -eq '') { continue }
        if (-not $script:ConfigShowDetailedProgress) {
            $pct = $null
            if     ($line -match '^\s*Convert:\s*(\d+)% done\.?\s*$')            { $pct = [int]$matches[1] }
            elseif ($line -match '^\s*\(\s*(\d+(?:\.\d+)?)\s*/100%\s*\)\s*$')    { $pct = [int][double]$matches[1] }
            if ($null -ne $pct -and $pct -lt 100 -and ($pct % 10) -ne 0) { continue }
        }
        $clean = $script:AnsiRx.Replace($line, '')
        if ($clean -eq '') { continue }
        if ($prefix -and $clean -notmatch '^\[') { $clean = "$prefix$clean" }

        if ($script:HeadlessMode) {
            [Console]::WriteLine("[$((Get-Date).ToString('HH:mm:ss'))] $clean")
            continue
        }

        $txtLog.SelectionStart  = $txtLog.Text.Length
        $txtLog.SelectionLength = 0
        $txtLog.SelectionColor  = $Color
        $txtLog.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $clean`n")
        $script:LogLineCount++
    }

    if ($script:HeadlessMode) { return }

    if ($script:LogLineCount -gt 5000) {
        try {
            $firstChar = $txtLog.GetFirstCharIndexFromLine(200)
            $cut       = $txtLog.GetFirstCharIndexFromLine(1000)
            if ($cut -gt 0 -and $firstChar -ge 0 -and $cut -gt $firstChar) {
                $txtLog.Select($firstChar, $cut - $firstChar)
                $txtLog.SelectedText = ''
                $script:LogLineCount -= 800
            }
        } catch { }
    }
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# ============================================================
#  15. SMALL HELPERS
# ============================================================
function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return ("{0:N2} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) { return $Span.ToString('hh\:mm\:ss') }
    return $Span.ToString('mm\:ss')
}

function Get-DiskFreeSpace {
    param([string]$Directory)
    try {
        $root  = [System.IO.Path]::GetPathRoot($Directory)
        $drive = [System.IO.DriveInfo]::new($root)
        return [long]$drive.AvailableFreeSpace
    } catch { return -1 }
}

function Show-Message {
    param(
        [string]$Text,
        [string]$Title,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information,
        [switch]$DefaultNo
    )
    if ($script:HeadlessMode) {
        Write-Log "[DIALOG] $Title - $Text" $colorWarning
        if ($Buttons -eq [System.Windows.Forms.MessageBoxButtons]::YesNo) {
            if ($script:ForceOverwrite -or -not $DefaultNo) { return [System.Windows.Forms.DialogResult]::Yes }
            Write-Log "[DIALOG] Declined - pass -Force to allow this in headless mode." $colorWarning
            return [System.Windows.Forms.DialogResult]::No
        }
        return [System.Windows.Forms.DialogResult]::OK
    }
    # Do not raise modal dialogs on a closing window - they appear as orphans.
    if ($script:FormIsClosing) {
        Write-Log "[DIALOG-SUPPRESSED] $Title - $Text" $colorWarning
        return [System.Windows.Forms.DialogResult]::OK
    }
    return [System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon)
}

function Set-ConversionProgress {
    param([int]$Percent)
    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $script:CurrentProgressPercent = $Percent
    if ($script:HeadlessMode) { return }
    try {
        if ($progressBar.Style -ne [System.Windows.Forms.ProgressBarStyle]::Continuous) {
            $progressBar.MarqueeAnimationSpeed = 0
            $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        }
        $progressBar.Value = $Percent
    } catch { }
}

# ============================================================
#  16. DOCKER / DISK / DISCOVERY HELPERS
# ============================================================
function Check-Docker {
    try {
        $null = & docker info 2>&1
        if ($LASTEXITCODE -eq 0) {
            if (-not $script:HeadlessMode) {
                $lblDockerStatus.Text      = "DOCKER ENGINE: READY"
                $lblDockerStatus.ForeColor = $colorSuccess
                $lblDockerDot.ForeColor    = $colorSuccess
            }
            return $true
        } else {
            if (-not $script:HeadlessMode) {
                $lblDockerStatus.Text      = "DOCKER ENGINE: NOT RUNNING"
                $lblDockerStatus.ForeColor = $colorError
                $lblDockerDot.ForeColor    = $colorError
            }
            return $false
        }
    } catch {
        if (-not $script:HeadlessMode) {
            $lblDockerStatus.Text      = "DOCKER ENGINE: NOT INSTALLED"
            $lblDockerStatus.ForeColor = $colorError
            $lblDockerDot.ForeColor    = $colorError
        }
        return $false
    }
}

function Initialize-Cleanup {
    try {
        $null = & docker info 2>&1
        if ($LASTEXITCODE -ne 0) { return 0 }
        # Only stopped leftovers; do not kill another instance's running job.
        $all = & docker ps -a --filter "status=exited" --filter "status=created" --format "{{.Names}}" 2>$null
        if (-not $all) { return 0 }
        $removed = 0
        foreach ($name in ($all -split "[\r\n]+")) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -notmatch '^vmconvert_[0-9a-f]{12}$') { continue }
            if ($name -eq $script:ContainerName) { continue }
            $null = & docker rm -f $name 2>&1
            if ($LASTEXITCODE -eq 0) { $removed++ }
        }
        return $removed
    } catch { return 0 }
}

function Ensure-DockerImage {
    param([string]$Image)
    try {
        $null = & docker image inspect $Image 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch { }
    if ($script:FormIsClosing) { return $false }

    Write-Log "Pulling Docker image: $Image  (first run may take several minutes)" $colorWarning
    $savedOutput = $script:LastProcessOutput
    $pullDir = [System.IO.Path]::GetTempPath()
    $rc = Invoke-SafeProcess -Exe "docker" -ArgsString "pull --quiet `"$Image`"" -WorkingDirectory $pullDir
    $script:LastProcessOutput = $savedOutput

    if ($rc -eq -1) { Write-Log "Image pull cancelled." $colorWarning; return $false }
    if ($rc -eq -3) {
        $null = & docker image inspect $Image 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Log "Image ready: $Image" $colorSuccess; return $true }
        Write-Log "Failed to pull image '$Image' (exit unreadable and image still missing)." $colorError
        return $false
    }
    if ($rc -ne 0) { Write-Log "Failed to pull image '$Image' (exit $rc)." $colorError; return $false }
    Write-Log "Image ready: $Image" $colorSuccess
    return $true
}

function Find-VDiskManager {
    $paths = @(
        "C:\Program Files (x86)\VMware\VMware Workstation\vmware-vdiskmanager.exe",
        "C:\Program Files\VMware\VMware Workstation\vmware-vdiskmanager.exe",
        "C:\Program Files (x86)\VMware\VMware Player\vmware-vdiskmanager.exe",
        "C:\Program Files\VMware\VMware Player\vmware-vdiskmanager.exe"
    )
    foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Test-ValidFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -eq '.' -or $Name -eq '..')      { return $false }
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        if ($Name.IndexOf($c) -ge 0) { return $false }
    }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $reserved = @('CON','PRN','AUX','NUL',
                  'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
                  'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9')
    if ($reserved -contains $stem.ToUpperInvariant()) { return $false }
    if ($stem -ne $stem.TrimEnd(' ', '.')) { return $false }
    return $true
}

function Get-SafeEnvValue {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value -replace '[\\"\r\n]', '')
}

function Test-FixedDrive {
    param([string]$Directory)
    try {
        $full  = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path
        $root  = [System.IO.Path]::GetPathRoot($full)
        $drive = [System.IO.DriveInfo]::new($root)
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
            return @{
                OK = $false
                Path = $full
                Reason = "Drive type is $($drive.DriveType). Docker Desktop can only bind-mount local fixed drives."
                Hint   = "Copy the file to a local fixed drive (e.g. C:\VMConvert\) and select it from there."
            }
        }
        return @{ OK = $true; Path = $full; Reason = ""; Hint = "" }
    } catch {
        return @{ OK = $false; Path = $Directory; Reason = "Cannot resolve path: $_"; Hint = "" }
    }
}

function Get-NormalizedOutputName {
    param([string]$Name, [string]$TargetExt)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $n = [System.IO.Path]::GetFileName($Name.Trim())
    if (-not $n) { return "" }
    $knownExt = '\.(vmdk|qcow2|vma|zst|raw|img|vdi|vhdx?|vhd|ova|ovf|partial)$'
    do {
        $before = $n
        $n = $n -replace $knownExt, ''
    } while ($n -ne $before)
    $n = $n.TrimEnd('.', ' ')
    if ([string]::IsNullOrWhiteSpace($n)) { return "" }
    return $n + $TargetExt
}

function Get-PveToVmLeftovers {
    param([string]$Directory, [string]$FileName)
    $base = $FileName -replace '\.vma\.zst$', ''
    $list = New-Object System.Collections.Generic.List[string]
    $vmaFile = [System.IO.Path]::Combine($Directory, "$base.vma")
    if (Test-Path -LiteralPath $vmaFile -PathType Leaf) { $list.Add($vmaFile) }
    $extractDir = [System.IO.Path]::Combine($Directory, $base)
    if (Test-Path -LiteralPath $extractDir -PathType Container) { $list.Add($extractDir) }
    return $list.ToArray()
}

function Get-SourceDiskInfo {
    param([string]$FilePath, [string]$Directory)
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    if ($baseName -match '^(.+)-s\d{3}$') { $baseName = $matches[1] }
    $splitRx  = '^' + [regex]::Escape($baseName) + '-s\d+\.vmdk$'
    $parts = @(
        Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $splitRx }
    )
    $fileItem = Get-Item -LiteralPath $FilePath -ErrorAction SilentlyContinue
    $fileSize = if ($fileItem) { [long]$fileItem.Length } else { [long]0 }
    if ($parts.Count -gt 0) {
        $total = [long](($parts | Measure-Object -Property Length -Sum).Sum)
        return @{
            IsSplit = $true; EffectiveSize = $total; PartCount = $parts.Count; DescriptorSize = $fileSize
        }
    }
    return @{
        IsSplit = $false; EffectiveSize = $fileSize; PartCount = 0; DescriptorSize = $fileSize
    }
}

function Rename-VmdkSet {
    param([string]$SourcePath, [string]$TargetPath)
    $srcDir  = [System.IO.Path]::GetDirectoryName($SourcePath)
    $tgtDir  = [System.IO.Path]::GetDirectoryName($TargetPath)
    $srcBase = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $tgtBase = [System.IO.Path]::GetFileNameWithoutExtension($TargetPath)

    if ($srcBase -match '^(.+)-s\d{3}$') { $srcBase = $matches[1] }
    if ($srcDir -eq $tgtDir -and $srcBase -eq $tgtBase) { return }

    $segments = @(Get-ChildItem -LiteralPath $srcDir -Filter "$srcBase-s*.vmdk" -File -ErrorAction SilentlyContinue)

    if ($segments.Count -eq 0) {
        Move-Item -LiteralPath $SourcePath -Destination $TargetPath -Force
        return
    }

    $descriptorPath = [System.IO.Path]::Combine($srcDir, "$srcBase.vmdk")
    if (-not (Test-Path -LiteralPath $descriptorPath)) {
        Write-Log "[WARN] Split VMDK '$srcBase' has no descriptor - renaming segments only." $colorWarning
        foreach ($seg in $segments) {
            $newSegName = $seg.Name -replace "^$([regex]::Escape($srcBase))-s", "$tgtBase-s"
            $dst = [System.IO.Path]::Combine($srcDir, $newSegName)
            try { Move-Item -LiteralPath $seg.FullName -Destination $dst -Force -ErrorAction Stop } catch {
                Write-Log "[WARN] Could not rename segment: $($seg.Name)" $colorWarning
            }
        }
        return
    }

    $descriptorContent = [System.IO.File]::ReadAllText($descriptorPath)

    # Only extent declaration lines (RW/RDONLY/NOACCESS) define the disk's
    # backing files. Matching every quoted ".vmdk" would also pick up
    # ddb.parentFileNameHint, which for a snapshot chain points elsewhere.
    $declaredNames = @($descriptorContent -split "[\r\n]+" |
                       Where-Object { $_ -match '^(RW|RDONLY|NOACCESS)\s' } |
                       ForEach-Object {
                           if ($_ -match '"([^"]+\.vmdk)"') { $matches[1] }
                       } |
                       Select-Object -Unique)
    $missing = @($declaredNames | Where-Object { -not (Test-Path -LiteralPath ([System.IO.Path]::Combine($srcDir, $_))) })
    if ($missing.Count -gt 0) {
        Write-Log "[WARN] Split VMDK '$srcBase' references missing extent(s): $($missing -join ', ') - leaving the set untouched." $colorWarning
        return
    }

    $newNames = @{}
    foreach ($seg in $segments) {
        $newSegName = $seg.Name -replace "^$([regex]::Escape($srcBase))-s", "$tgtBase-s"
        $newNames[$seg.Name] = $newSegName
        $descriptorContent = $descriptorContent -replace [regex]::Escape($seg.Name), $newSegName
    }

    # Rename as a unit. Move-Item -Force reliably overwrites an existing target;
    # Rename-Item -Force does not, so a stale output-sNNN.vmdk from an earlier
    # failed run would otherwise fail the whole conversion.
    $done = New-Object System.Collections.Generic.List[object]
    $failed = $false
    foreach ($seg in $segments) {
        try {
            $dst = [System.IO.Path]::Combine($srcDir, $newNames[$seg.Name])
            Move-Item -LiteralPath $seg.FullName -Destination $dst -Force -ErrorAction Stop
            $null = $done.Add($seg)
        } catch {
            Write-Log "[WARN] Could not rename segment '$($seg.Name)': $_" $colorWarning
            $failed = $true
            break
        }
    }
    if ($failed) {
        foreach ($seg in $done) {
            try {
                $cur = [System.IO.Path]::Combine($srcDir, $newNames[$seg.Name])
                Move-Item -LiteralPath $cur -Destination $seg.FullName -Force -ErrorAction Stop
            } catch { }
        }
        Write-Log "[WARN] Segment rename rolled back - the split set is unchanged." $colorWarning
        return
    }

    if (Test-Path -LiteralPath $TargetPath) { Remove-Item -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue }
    [System.IO.File]::WriteAllText($TargetPath, $descriptorContent, [System.Text.Encoding]::ASCII)
    Remove-Item -LiteralPath $descriptorPath -Force -ErrorAction SilentlyContinue
}

function Remove-Leftovers {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        try {
            if (Test-Path -LiteralPath $p -PathType Container) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
            }
        } catch { }
    }
}

# ============================================================
#  17. PREFLIGHT / LOCK / TOAST / SUMMARY / HISTORY / SUPPORT
# ============================================================
function Test-FileLocked {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $fs.Close()
        return $false
    } catch [System.IO.IOException] { return $true }
    catch { return $false }
}

function Test-SourceImage {
    param([string]$Directory, [string]$FileName, [string]$Direction)
    if (-not $script:ConfigRunPreflight) {
        return @{ OK = $true; Skipped = $true; Format = ''; VirtualSize = 0; Reason = 'disabled' }
    }
    if ($Direction -eq 'PveToVm') {
        try {
            $fullPath = [System.IO.Path]::Combine($Directory, $FileName)
            $fs = [System.IO.File]::OpenRead($fullPath)
            try {
                $buf = New-Object byte[] 4
                $n = $fs.Read($buf, 0, 4)
                if ($n -lt 4) {
                    return @{ OK = $false; Skipped = $false; Reason = "File too short to be a zstd archive"; Format = ''; VirtualSize = 0 }
                }
                if ($buf[0] -ne 0x28 -or $buf[1] -ne 0xB5 -or $buf[2] -ne 0x2F -or $buf[3] -ne 0xFD) {
                    $hex = '{0:X2} {1:X2} {2:X2} {3:X2}' -f $buf[0], $buf[1], $buf[2], $buf[3]
                    return @{ OK = $false; Skipped = $false; Reason = "Not a zstd archive (magic $hex, expected 28 B5 2F FD)"; Format = ''; VirtualSize = 0 }
                }
            } finally { $fs.Close() }
            return @{ OK = $true; Skipped = $false; Format = 'zstd-compressed VMA'; VirtualSize = 0 }
        } catch {
            return @{ OK = $false; Skipped = $false; Reason = "Could not read file header: $_"; Format = ''; VirtualSize = 0 }
        }
    }
    if ($Direction -eq 'VmToPve') {
        Write-Log "[preflight] Probing source with qemu-img info (via $($script:ConfigToolsImage))..." $colorTextMuted
        $prevOutput = $script:LastProcessOutput
        $script:LastProcessOutput = ''

        # The filename is passed as an env var, never interpolated into the
        # shell command, so a single quote in a name cannot close the quote.
        $srcSafe = Get-SafeEnvValue $FileName

        # apk stderr is NOT redirected: a silent apk failure was the biggest
        # cause of "probe failed (exit 1)" with no diagnostic. Every line
        # reaches the log and is categorised below.
        $inner = 'apk add --no-cache qemu-img || exit $?; qemu-img info --output=json "$SRC"'
        $probeArgs = "run --rm -e `"SRC=$srcSafe`" -v `"${Directory}:/data:ro`" -w /data $($script:ConfigToolsImage) sh -c `"$inner`""
        $rc = Invoke-SafeProcess -Exe docker -ArgsString $probeArgs -WorkingDirectory $Directory -SuppressStream
        $output = $script:LastProcessOutput
        $script:LastProcessOutput = $prevOutput

        # Distinct signal so the caller can map this to CANCELLED instead of
        # a misleading "validation failed" dialog.
        if ($rc -eq -1) {
            return @{ OK = $false; Skipped = $false; Reason = 'cancelled'; Format = ''; VirtualSize = 0 }
        }

        if ($rc -ne 0) {
            Write-Log "[preflight] qemu-img probe failed (exit $rc)." $colorWarning
            $diag = $output.Trim()
            if ($diag) {
                foreach ($l in (($diag -split "[\r\n]+") | Select-Object -First 20)) {
                    if ($l -ne '') { Write-Log "  $l" $colorWarning }
                }
            } else {
                Write-Log "  (no output captured - docker run itself may have failed)" $colorWarning
            }

            # Categorise. A failure to install qemu-img is a preflight-
            # infrastructure problem (network/DNS/disk), not a bad source disk.
            # Warn and let the conversion try - its install step is not silent.
            $parseFailed   = $output -match '(?im)(qemu-img:\s*could not open|qemu-img:\s*invalid|qemu-img:\s*error|not a supported disk|unknown format|invalid vmdk|corrupt|backing file.*not found)'
            $installFailed = $output -match '(?im)(apk|fetch https?://|temporary failure in name resolution|could not resolve|network is unreachable|connection refused|dial tcp|i/o timeout|tls handshake|pull access denied|manifest unknown|error response from daemon|no space left on device|unable to select packages)'

            if ($parseFailed) {
                return @{ OK = $false; Skipped = $false; Reason = "qemu-img could not read '$FileName' - the file may be corrupt, locked, or not a valid VMDK"; Format = ''; VirtualSize = 0 }
            }
            if ($installFailed) {
                Write-Log "[preflight] Could not install qemu-img in the tools container - likely a Docker network/DNS problem." $colorWarning
                Write-Log "           Continuing without preflight; the conversion will report the real error if it also fails." $colorWarning
                Write-Log "           If this keeps happening: restart Docker Desktop, or run 'docker pull $($script:ConfigToolsImage)' manually." $colorWarning
                return @{ OK = $true; Skipped = $true; Format = 'unknown'; VirtualSize = 0; Reason = 'preflight skipped: qemu-img install failed' }
            }
            return @{ OK = $false; Skipped = $false; Reason = "qemu-img info failed (exit $rc)"; Format = ''; VirtualSize = 0 }
        }

        try {
            $jsonText = $output.Trim()
            $brace = $jsonText.IndexOf('{')
            if ($brace -gt 0) { $jsonText = $jsonText.Substring($brace) }
            $json = $jsonText | ConvertFrom-Json
            $vsize = 0
            if ($null -ne $json.PSObject.Properties['virtual-size']) { $vsize = [long]$json.'virtual-size' }
            $fmt = ''
            if ($null -ne $json.PSObject.Properties['format']) { $fmt = [string]$json.format }
            Write-Log "[preflight] Source format '$fmt', virtual size $(Format-Bytes $vsize)." $colorText
            return @{ OK = $true; Skipped = $false; Format = $fmt; VirtualSize = $vsize }
        } catch {
            Write-Log "[preflight] Could not parse qemu-img output." $colorWarning
            return @{ OK = $true; Skipped = $true; Format = 'unknown'; VirtualSize = 0; Reason = "Could not parse qemu-img output" }
        }
    }
    return @{ OK = $true; Skipped = $true; Format = ''; VirtualSize = 0; Reason = 'unknown direction' }
}

function Show-Toast {
    param([string]$Title, [string]$Message)
    if ($script:HeadlessMode -or $script:QuietMode -or -not $script:ConfigToastOnComplete) { return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
        $tmpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $xml  = $tmpl.GetXml()
        $xml  = $xml -replace '<text id="1"></text>', "<text id=""1"">$([System.Security.SecurityElement]::Escape($Title))</text>"
        $xml  = $xml -replace '<text id="2"></text>', "<text id=""2"">$([System.Security.SecurityElement]::Escape($Message))</text>"
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType=WindowsRuntime] | Out-Null
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('VM Converter Pro').Show($toast)
        return
    } catch { }
    $ni = $null
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Information
        $ni.Visible = $true
        $ni.ShowBalloonTip(5000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::Info)

        # Attach the icon to the timer itself, not a shared slot: two quick
        # toasts would otherwise overwrite the single global reference and
        # orphan the first icon in the tray forever.
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 5200
        $timer.Tag = $ni
        $ni = $null
        $timer.Add_Tick({
            param($s, $e)
            $s.Stop(); $s.Dispose()
            if ($null -ne $s.Tag) {
                try { $s.Tag.Visible = $false } catch { }
                try { $s.Tag.Dispose() } catch { }
            }
        })
        $timer.Start()
    } catch {
        if ($ni) {
            try { $ni.Visible = $false } catch { }
            try { $ni.Dispose() } catch { }
        }
    }
}

function Get-HistoryEntries {
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $script:ConfigHistoryFile)) { return $out }
    $raw = $null
    try { $raw = Get-Content -LiteralPath $script:ConfigHistoryFile -Raw -Encoding UTF8 } catch { return $out }
    if (-not $raw -or -not $raw.Trim()) { return $out }
    $loaded = $null
    try { $loaded = $raw | ConvertFrom-Json } catch {
        $corrupt = $script:ConfigHistoryFile + '.corrupt'
        try {
            Move-Item -LiteralPath $script:ConfigHistoryFile -Destination $corrupt -Force -ErrorAction Stop
            Write-Log "History file was unreadable; kept a copy at '$corrupt' and started fresh." $colorWarning
        } catch { }
        return $out
    }

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($loaded)
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if ($null -eq $item) { continue }

        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) {
            foreach ($child in $item) { $queue.Enqueue($child) }
            continue
        }
        $names = @($item.PSObject.Properties.Name)
        if ($names -notcontains 'StartedUtc') {
            if ($names -contains 'value') {
                foreach ($child in @($item.value)) { $queue.Enqueue($child) }
            }
            continue
        }

        $h = @{}
        foreach ($prop in $item.PSObject.Properties) { $h[$prop.Name] = $prop.Value }
        $null = $out.Add([pscustomobject]@{
            StartedUtc  = [string]$h['StartedUtc']
            FinishedUtc = [string]$h['FinishedUtc']
            Source      = [string]$h['Source']
            Output      = [string]$h['Output']
            Direction   = [string]$h['Direction']
            SourceBytes = [long]$h['SourceBytes']
            OutputBytes = [long]$h['OutputBytes']
            DurationSec = [int]$h['DurationSec']
            Result      = [string]$h['Result']
            ExitCode    = [int]$h['ExitCode']
            ScriptVer   = [string]$h['ScriptVer']
        })
    }
    return $out
}

function Add-JobHistory {
    param([hashtable]$Entry)
    try {
        $list = @(Get-HistoryEntries)
        $list += [pscustomobject]@{
            StartedUtc  = $Entry.Started.ToUniversalTime().ToString('o')
            FinishedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Source      = $Entry.Source
            Output      = $Entry.Output
            Direction   = $Entry.Direction
            SourceBytes = $Entry.SourceBytes
            OutputBytes = $Entry.OutputBytes
            DurationSec = [int]$Entry.Duration.TotalSeconds
            Result      = $Entry.Result
            ExitCode    = $Entry.ExitCode
            ScriptVer   = $ScriptVersion
        }
        $list = @($list | Sort-Object -Property StartedUtc)
        $json = ConvertTo-Json -InputObject @($list | Select-Object -Last 200) -Depth 4
        $tmp = $script:ConfigHistoryFile + '.tmp'
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:ConfigHistoryFile -Force -ErrorAction Stop
    } catch { }
}

function Show-HistoryDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Conversion History"
    $dlg.Size            = New-Object System.Drawing.Size(780, 500)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $colorBg
    $dlg.ForeColor       = $colorText
    $dlg.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(10, 10)
    $grid.Size     = New-Object System.Drawing.Size(745, 410)
    $grid.BackgroundColor = $colorLogBg
    $grid.ForeColor = $colorText
    $grid.GridColor = $colorBorder
    $grid.DefaultCellStyle.BackColor = $colorLogBg
    $grid.DefaultCellStyle.ForeColor = $colorText
    $grid.DefaultCellStyle.SelectionBackColor = $colorAccent
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $colorPanel
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $colorText
    $grid.EnableHeadersVisualStyles = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.RowHeadersVisible = $false
    $dlg.Controls.Add($grid)

    foreach ($header in @('Finished (UTC)', 'Direction', 'Result', 'Size', 'Duration', 'Output')) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $header
        $null = $grid.Columns.Add($col)
    }

    $rows = @(Get-HistoryEntries | Select-Object -Last 50)
    foreach ($r in $rows) {
        $dur = try { [int]$r.DurationSec } catch { 0 }
        $null = $grid.Rows.Add(
            [string]$r.FinishedUtc,
            [string]$r.Direction,
            [string]$r.Result,
            (Format-Bytes ([long]$r.OutputBytes)),
            ("{0:mm\:ss}" -f [TimeSpan]::FromSeconds($dur)),
            [string]$r.Output
        )
    }

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text     = "CLOSE"
    $btnClose.Location = New-Object System.Drawing.Point(645, 430)
    $btnClose.Size     = New-Object System.Drawing.Size(110, 32)
    $btnClose.BackColor = $colorAccent
    $btnClose.ForeColor = [System.Drawing.Color]::White
    $btnClose.FlatStyle = 'Flat'
    $btnClose.FlatAppearance.BorderSize = 0
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnClose)

    $null = $dlg.ShowDialog()
    $dlg.Dispose()
}

function Export-SupportBundle {
    param([string]$Reason = 'User requested')
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $root  = Join-Path $env:TEMP "vcsb_$stamp"
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $dockerVer = try { (& docker --version 2>&1 | Out-String).Trim() } catch { 'not installed' }
        $sys = @"
VM Converter Pro v$ScriptVersion ($ScriptBuild) - Support Bundle
Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Reason    : $Reason

OS        : $([Environment]::OSVersion.VersionString)
PS        : $($PSVersionTable.PSVersion)
Docker    : $dockerVer
Free Space: $(Format-Bytes (Get-DiskFreeSpace $env:TEMP))
"@
        $sys | Set-Content -LiteralPath (Join-Path $root 'system.txt') -Encoding UTF8
        if (-not $script:HeadlessMode -and $txtLog) {
            $txtLog.Text | Set-Content -LiteralPath (Join-Path $root 'session.log') -Encoding UTF8
        }
        if ($script:ContainerName) {
            try { & docker logs $script:ContainerName 2>&1 | Set-Content -LiteralPath (Join-Path $root 'container.log') -Encoding UTF8 } catch { }
        }
        try { & docker info 2>&1 | Set-Content -LiteralPath (Join-Path $root 'docker-info.log') -Encoding UTF8 } catch { }

        $zip = Join-Path ([Environment]::GetFolderPath('Desktop')) "VMConverter_Support_$stamp.zip"
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip -Force
        return $zip
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-SummaryDialog {
    param(
        [string]$Result,
        [string]$OutputPath,
        [long]$OutputBytes,
        [TimeSpan]$Duration,
        [string]$VerifyNote
    )
    if ($script:HeadlessMode -or $script:QuietMode -or -not $script:ConfigShowSummaryDialog) { return }
    if ($script:FormIsClosing) { return }

    $title = switch ($Result) {
        'SUCCESS'   { "Conversion Successful"  }
        'UNCERTAIN' { "Conversion Uncertain"   }
        'FAILED'    { "Conversion Failed"      }
        'CANCELLED' { "Conversion Cancelled"   }
        default     { "Result"                 }
    }
    $icon = switch ($Result) {
        'SUCCESS'   { [System.Drawing.SystemIcons]::Information }
        'UNCERTAIN' { [System.Drawing.SystemIcons]::Warning     }
        default     { [System.Drawing.SystemIcons]::Error       }
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "VM Converter Pro"
    $dlg.Size            = New-Object System.Drawing.Size(560, 380)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $colorBg
    $dlg.ForeColor       = $colorText
    $dlg.Font            = New-Object System.Drawing.Font('Segoe UI', 10)

    $iconBox = New-Object System.Windows.Forms.PictureBox
    $iconBox.Image = $icon.ToBitmap()
    $iconBox.Location = New-Object System.Drawing.Point(20, 20)
    $iconBox.Size = New-Object System.Drawing.Size(48, 48)
    $iconBox.SizeMode = 'StretchImage'
    $dlg.Controls.Add($iconBox)

    $lblHead = New-Object System.Windows.Forms.Label
    $lblHead.Text = $title
    $lblHead.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $lblHead.ForeColor = switch ($Result) {
        'SUCCESS' { $colorSuccess } 'UNCERTAIN' { $colorWarning } default { $colorError }
    }
    $lblHead.Location = New-Object System.Drawing.Point(80, 25)
    $lblHead.Size = New-Object System.Drawing.Size(460, 40)
    $dlg.Controls.Add($lblHead)

    $throughput = if ($Duration.TotalSeconds -gt 0) { [long]($OutputBytes / $Duration.TotalSeconds) } else { 0 }
    $presentNote = if (-not $OutputPath) { 'n/a' }
                   elseif (Test-Path -LiteralPath $OutputPath) { 'yes' }
                   else { 'no - the file was removed' }
    $details = @"
Output     : $OutputPath
Present    : $presentNote
Size       : $(Format-Bytes $OutputBytes)
Duration   : $(Format-Duration $Duration)
Throughput : $(Format-Bytes $throughput)/s
Verify     : $VerifyNote
"@
    $lblBody = New-Object System.Windows.Forms.Label
    $lblBody.Text = $details
    $lblBody.Font = New-Object System.Drawing.Font('Consolas', 9)
    $lblBody.ForeColor = $colorText
    $lblBody.Location = New-Object System.Drawing.Point(80, 80)
    $lblBody.Size = New-Object System.Drawing.Size(460, 180)
    $dlg.Controls.Add($lblBody)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text     = "Open Folder"
    $btnOpen.Location = New-Object System.Drawing.Point(80, 280)
    $btnOpen.Size     = New-Object System.Drawing.Size(110, 34)
    $btnOpen.BackColor = $colorPanel
    $btnOpen.ForeColor = $colorText
    $btnOpen.FlatStyle = 'Flat'
    $btnOpen.FlatAppearance.BorderColor = $colorBorder
    $btnOpen.FlatAppearance.BorderSize = 1
    if (-not $OutputPath -or -not (Test-Path -LiteralPath $OutputPath)) {
        $btnOpen.Enabled = $false
    }
    $btnOpen.Add_Click({
        try { Start-Process explorer.exe -ArgumentList "/select,`"$($OutputPath -replace '/','\')`"" } catch { }
    })
    $dlg.Controls.Add($btnOpen)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text     = "Copy Path"
    $btnCopy.Location = New-Object System.Drawing.Point(200, 280)
    $btnCopy.Size     = New-Object System.Drawing.Size(100, 34)
    $btnCopy.BackColor = $colorPanel
    $btnCopy.ForeColor = $colorText
    $btnCopy.FlatStyle = 'Flat'
    $btnCopy.FlatAppearance.BorderColor = $colorBorder
    $btnCopy.FlatAppearance.BorderSize = 1
    $btnCopy.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($OutputPath) } catch { } })
    $dlg.Controls.Add($btnCopy)

    $btnDone = New-Object System.Windows.Forms.Button
    $btnDone.Text     = "Done"
    $btnDone.Location = New-Object System.Drawing.Point(430, 280)
    $btnDone.Size     = New-Object System.Drawing.Size(110, 34)
    $btnDone.BackColor = $colorAccent
    $btnDone.ForeColor = [System.Drawing.Color]::White
    $btnDone.FlatStyle = 'Flat'
    $btnDone.FlatAppearance.BorderSize = 0
    $btnDone.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnDone)

    $dlg.AcceptButton = $btnDone
    $null = $dlg.ShowDialog()
    $dlg.Dispose()
}

function Show-SettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Settings"
    $dlg.Size            = New-Object System.Drawing.Size(600, 640)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $colorBg
    $dlg.ForeColor       = $colorText
    $dlg.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

    function New-Row {
        param($labelText, $control)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $labelText
        $lbl.Location = New-Object System.Drawing.Point(15, ($script:SettingsRowY + 4))
        $lbl.Size = New-Object System.Drawing.Size(180, 20)
        $lbl.ForeColor = $colorText
        $dlg.Controls.Add($lbl)
        $control.Location = New-Object System.Drawing.Point(200, $script:SettingsRowY)
        $control.Size = New-Object System.Drawing.Size(370, 24)
        $dlg.Controls.Add($control)
        $script:SettingsRowY += 32
        return $control
    }

    $script:SettingsRowY = 15

    function New-Text($val) {
        $t = New-Object System.Windows.Forms.TextBox
        $t.Text = [string]$val
        $t.BackColor = $colorPanel
        $t.ForeColor = $colorText
        $t.BorderStyle = 'FixedSingle'
        return $t
    }
    function New-Check($val) {
        $c = New-Object System.Windows.Forms.CheckBox
        $c.Checked = [bool]$val
        $c.ForeColor = $colorText
        return $c
    }
    function New-Combo($val, $items) {
        $c = New-Object System.Windows.Forms.ComboBox
        $c.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        $c.BackColor = $colorPanel
        $c.ForeColor = $colorText
        $c.FlatStyle = 'Flat'
        foreach ($i in $items) { $null = $c.Items.Add($i) }
        $c.SelectedItem = $val
        return $c
    }

    $tbPve    = New-Row "PVE->VM image"       (New-Text $script:ConfigPveToVmImage)
    $tbVmPve  = New-Row "VM->PVE image"       (New-Text $script:ConfigVmToPveImage)
    $tbTools  = New-Row "Preflight tools img" (New-Text $script:ConfigToolsImage)
    $tbMinOut = New-Row "Min output (bytes)"  (New-Text $script:ConfigMinOutputBytes)
    $cmbLL    = New-Row "Min log level"       (New-Combo $script:ConfigMinLogLevel @('DEBUG','INFO','WARN','ERROR'))
    $cmbQm    = New-Row "Qemu mode"           (New-Combo $script:ConfigQemuMode @('Safe','Balanced','Fast'))
    $tbWatch  = New-Row "Watchdog min free (GB)" (New-Text ([math]::Round($script:ConfigWatchdogMinFreeBytes / 1GB, 2)))
    $cbPre    = New-Row "Run preflight"       (New-Check $script:ConfigRunPreflight)
    $cbSumm   = New-Row "Show summary dialog" (New-Check $script:ConfigShowSummaryDialog)
    $cbToast  = New-Row "Toast on complete"   (New-Check $script:ConfigToastOnComplete)
    $cbDet    = New-Row "Detailed progress"   (New-Check $script:ConfigShowDetailedProgress)
    $cbAuto   = New-Row "Auto cleanup leftovers" (New-Check $script:ConfigAutoCleanupLeftovers)
    $cbKeep   = New-Row "Keep intermediates on failure" (New-Check $script:ConfigKeepIntermediatesOnFailure)

    $lblFile = New-Object System.Windows.Forms.Label
    $lblFile.Text = "Settings file: $($script:ConfigSettingsFile)"
    $lblFile.Location = New-Object System.Drawing.Point(15, ($script:SettingsRowY + 5))
    $lblFile.Size = New-Object System.Drawing.Size(555, 20)
    $lblFile.ForeColor = $colorTextMuted
    $lblFile.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $dlg.Controls.Add($lblFile)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text     = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(360, ($script:SettingsRowY + 35))
    $btnSave.Size     = New-Object System.Drawing.Size(100, 34)
    $btnSave.BackColor = $colorAccent
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = 'Flat'
    $btnSave.FlatAppearance.BorderSize = 0
    $dlg.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(470, ($script:SettingsRowY + 35))
    $btnCancel.Size     = New-Object System.Drawing.Size(100, 34)
    $btnCancel.BackColor = $colorPanel
    $btnCancel.ForeColor = $colorText
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.FlatAppearance.BorderColor = $colorBorder
    $btnCancel.FlatAppearance.BorderSize = 1
    $btnCancel.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnCancel)

    $btnSave.Add_Click({
        $pveImg = $tbPve.Text.Trim()
        $vmImg  = $tbVmPve.Text.Trim()
        $tlImg  = $tbTools.Text.Trim()
        if (-not $pveImg -or -not $vmImg -or -not $tlImg) {
            $null = Show-Message -Text "Docker image names cannot be empty." -Title "Invalid Settings" -Buttons OK -Icon Warning
            return
        }
        $minOut = [long]0
        if (-not [long]::TryParse($tbMinOut.Text.Trim(), [ref]$minOut) -or $minOut -lt 1) {
            $null = Show-Message -Text "Min output must be a positive whole number of bytes." -Title "Invalid Settings" -Buttons OK -Icon Warning
            return
        }
        $watchGB = [double]0
        if (-not [double]::TryParse($tbWatch.Text.Trim(), [ref]$watchGB) -or $watchGB -le 0) {
            $null = Show-Message -Text "Watchdog minimum free space must be a positive number of GB." -Title "Invalid Settings" -Buttons OK -Icon Warning
            return
        }

        $script:ConfigPveToVmImage             = $pveImg
        $script:ConfigVmToPveImage             = $vmImg
        $script:ConfigToolsImage               = $tlImg
        $script:ConfigMinOutputBytes           = $minOut
        $script:ConfigMinLogLevel              = [string]$cmbLL.SelectedItem
        $script:ConfigQemuMode                 = [string]$cmbQm.SelectedItem
        $script:ConfigWatchdogMinFreeBytes     = [long]($watchGB * 1GB)
        $script:ConfigRunPreflight             = $cbPre.Checked
        $script:ConfigShowSummaryDialog        = $cbSumm.Checked
        $script:ConfigToastOnComplete          = $cbToast.Checked
        $script:ConfigShowDetailedProgress     = $cbDet.Checked
        $script:ConfigAutoCleanupLeftovers     = $cbAuto.Checked
        $script:ConfigKeepIntermediatesOnFailure = $cbKeep.Checked
        if (Save-Settings) { Write-Log "Settings saved." $colorSuccess } else { Write-Log "Failed to save settings." $colorError }
        $dlg.Close()
    })

    $null = $dlg.ShowDialog()
    $dlg.Dispose()

    if ($cmbLogLevel.Items.Contains($script:ConfigMinLogLevel)) { $cmbLogLevel.SelectedItem = $script:ConfigMinLogLevel }
    if ($cmbQemuMode.Items.Contains($script:ConfigQemuMode))    { $cmbQemuMode.SelectedItem = $script:ConfigQemuMode }
}

# ============================================================
#  18. INVOKE-SAFEPROCESS (progress + watchdog + log levels)
# ============================================================
function Stop-ConversionProcess {
    param([System.Diagnostics.Process]$Process)
    if ($script:ContainerName) {
        try {
            $rm = Start-Process -FilePath 'docker' -ArgumentList @('rm','-f',$script:ContainerName) -NoNewWindow -PassThru -RedirectStandardOutput 'NUL' -RedirectStandardError 'NUL' -ErrorAction Stop
            if (-not $rm.WaitForExit(5000)) { try { $rm.Kill() } catch { } }
        } catch { }
    }
    if ($null -ne $Process) {
        try {
            $tk = Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/T','/F','/PID',$Process.Id) -NoNewWindow -PassThru -RedirectStandardOutput 'NUL' -RedirectStandardError 'NUL' -ErrorAction Stop
            if (-not $tk.WaitForExit(5000)) { try { $tk.Kill() } catch { } }
        } catch { }
        try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }
        try { $null = $Process.WaitForExit(3000) } catch { }
    }
}

function Invoke-SafeProcess {
    param([string]$Exe, [string]$ArgsString, [string]$WorkingDirectory, [switch]$SuppressStream)
    $outFile = $null
    $errFile = $null
    $outStream = $null
    $errStream = $null
    $outTask = $null
    $errTask = $null
    $proc = $null
    try {
        $outFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $Exe
        $psi.Arguments              = $ArgsString
        $psi.WorkingDirectory       = $WorkingDirectory
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardInput  = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null = $proc.Start()
        $script:CurrentProcess = $proc
        $proc.StandardInput.Close()

        # ReadWrite sharing + unbuffered stream: otherwise Get-Content polls
        # fail with sharing violations and nothing shows until EOF.
        $outStream = New-Object System.IO.FileStream($outFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite, 1)
        $errStream = New-Object System.IO.FileStream($errFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite, 1)
        $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($outStream, 512)
        $errTask = $proc.StandardError.BaseStream.CopyToAsync($errStream, 512)

        $lastOut  = 0
        $lastErr  = 0
        $lastTick = [DateTime]::MinValue
        $script:WatchdogLastCheck = [DateTime]::MinValue

        # $wasKilled distinguishes "the user cancelled and we had to kill" from
        # "the process finished naturally as the click landed".
        $wasKilled = $false

        while (-not $proc.HasExited) {
            if ($script:CancelRequested) {
                # Refresh once before killing. If the process already exited
                # while we were sleeping, fall through to the normal exit-code
                # path so a genuine success is not downgraded to CANCELLED.
                $naturalExit = $false
                try {
                    $proc.Refresh()
                    $naturalExit = $proc.HasExited
                } catch { }
                if ($naturalExit) { break }
                Stop-ConversionProcess -Process $proc
                $wasKilled = $true
                break
            }

            if (Test-Path -LiteralPath $outFile) {
                $content = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($content -and $content.Length -gt $lastOut) {
                    $new = $content.Substring($lastOut)
                    $lastOut = $content.Length
                    $script:LastProcessOutput += $new
                    if (-not $SuppressStream) {
                        foreach ($l in ($new -split "[\r\n]+")) { if ($l -ne '') { Write-Log $l $colorText } }
                    }
                    if ($new -match 'Convert:\s*(\d+)%\s*done') {
                        Set-ConversionProgress -Percent ([int]$matches[1])
                    }
                }
            }
            if (Test-Path -LiteralPath $errFile) {
                $content = Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($content -and $content.Length -gt $lastErr) {
                    $new = $content.Substring($lastErr)
                    $lastErr = $content.Length
                    if (-not $SuppressStream) {
                        foreach ($l in ($new -split "[\r\n]+")) { if ($l -ne '') { Write-Log $l $colorWarning } }
                    }
                    if ($new -match '\((\d+(?:\.\d+)?)/100%\)') {
                        Set-ConversionProgress -Percent ([int][double]$matches[1])
                    }
                }
            }

            if ($script:LastProcessOutput.Length -gt $script:MaxOutputCapture) {
                $script:LastProcessOutput = $script:LastProcessOutput.Substring([int]($script:LastProcessOutput.Length - $script:MaxOutputCapture / 2))
            }

            if ($script:WatchdogDirectory -and -not $script:WatchdogTripped) {
                if (((Get-Date) - $script:WatchdogLastCheck).TotalSeconds -ge 5) {
                    $script:WatchdogLastCheck = Get-Date
                    $free = Get-DiskFreeSpace -Directory $script:WatchdogDirectory
                    if ($free -ge 0 -and $free -lt $script:WatchdogMinFreeBytes) {
                        Write-Log "[WATCHDOG] Free space fell to $(Format-Bytes $free) < $(Format-Bytes $script:WatchdogMinFreeBytes) - aborting to avoid corruption." $colorError
                        $script:WatchdogTripped = $true
                        $script:CancelRequested = $true
                    }
                }
            }

            if ($script:ConversionStart -and ((Get-Date) - $lastTick).TotalSeconds -ge 1 -and -not $script:HeadlessMode -and -not $script:FormIsClosing) {
                $lastTick = Get-Date
                $elapsed  = (Get-Date) - $script:ConversionStart
                $lblDockerStatus.Text      = "CONVERTING... $(Format-Duration $elapsed)"
                $lblDockerStatus.ForeColor = $colorWarning
            }

            try { [System.Windows.Forms.Application]::DoEvents() } catch { }
            Start-Sleep -Milliseconds 150
        }

        $streamWaitMs = 5000
        foreach ($task in @($outTask, $errTask)) {
            if ($null -eq $task) { continue }
            try { if (-not $task.Wait($streamWaitMs)) { $streamWaitMs = 0 } } catch { }
        }
        if ($outStream) { try { $outStream.Flush() } catch { } ; try { $outStream.Dispose() } catch { } ; $outStream = $null }
        if ($errStream) { try { $errStream.Flush() } catch { } ; try { $errStream.Dispose() } catch { } ; $errStream = $null }

        if (Test-Path -LiteralPath $outFile) {
            $content = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($content -and $content.Length -gt $lastOut) {
                $new = $content.Substring($lastOut)
                $script:LastProcessOutput += $new
                if (-not $SuppressStream) {
                    foreach ($l in ($new -split "[\r\n]+")) { if ($l -ne '') { Write-Log $l $colorText } }
                }
            }
        }
        if (Test-Path -LiteralPath $errFile) {
            $content = Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($content -and $content.Length -gt $lastErr) {
                $new = $content.Substring($lastErr)
                if (-not $SuppressStream) {
                    foreach ($l in ($new -split "[\r\n]+")) { if ($l -ne '') { Write-Log $l $colorWarning } }
                }
            }
        }

        if ($wasKilled) { return -1 }

        if (-not $proc) {
            Write-Log "[WARN] Process handle was lost; cannot read exit code." $colorWarning
            return -3
        }
        try { $null = $proc.WaitForExit(10000) } catch {
            Write-Log "[DIAG] WaitForExit() threw: $($_.Exception.Message)" $colorTextMuted
        }

        $code = $null
        $readError = $null
        for ($i = 0; $i -lt 30; $i++) {
            try {
                $proc.Refresh()
                if ($proc.HasExited) {
                    $c = $proc.ExitCode
                    if ($null -ne $c -and "$c" -ne '') { $code = [int]$c; break }
                }
            } catch { $readError = $_.Exception.Message }
            Start-Sleep -Milliseconds 100
        }
        if ($null -eq $code) {
            if ($readError) { Write-Log "[WARN] Could not read exit code ($readError); relying on markers." $colorWarning }
            else            { Write-Log "[WARN] Could not read exit code; relying on markers." $colorWarning }
            return -3
        }
        return [int]$code
    }
    catch {
        Write-Log "[FATAL] Could not start process: $_" $colorError
        return -2
    }
    finally {
        if ($outStream) { try { $outStream.Dispose() } catch { } }
        if ($errStream) { try { $errStream.Dispose() } catch { } }
        foreach ($tmp in @($outFile, $errFile)) {
            if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
}

# ============================================================
#  19. SET-FILE (drop / browse helper)
# ============================================================
function Set-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $fileName = [System.IO.Path]::GetFileName($Path)
    if ($fileName -match '^(.+)-s\d{3}\.vmdk$') {
        $baseName = $matches[1] + ".vmdk"
        $parent   = [System.IO.Path]::GetDirectoryName($Path)
        $main     = [System.IO.Path]::Combine($parent, $baseName)
        if (Test-Path -LiteralPath $main) {
            Write-Log "Selected split segment - switching to main descriptor: $baseName" $colorWarning
            $Path     = $main
            $fileName = $baseName
        }
    }
    $txtFilePath.Text = $Path
    if ($fileName.EndsWith(".vma.zst", [StringComparison]::OrdinalIgnoreCase)) {
        $rbPveToVm.Checked  = $true
        $txtOutputName.Text = Get-NormalizedOutputName -Name $fileName -TargetExt ".vmdk"
    } elseif ($fileName.EndsWith(".vmdk", [StringComparison]::OrdinalIgnoreCase)) {
        $rbVmToPve.Checked  = $true
        $txtOutputName.Text = Get-NormalizedOutputName -Name $fileName -TargetExt ".qcow2"
    }
}

function Promote-PartialOutput {
    param([string]$PartialPath, [string]$FinalPath)
    try {
        # Move-Item -Force is a single rename: atomic on the same volume and
        # overwrites the destination in one step.
        Move-Item -LiteralPath $PartialPath -Destination $FinalPath -Force -ErrorAction Stop
        return $true
    } catch {
        Write-Log "ERROR: Could not promote partial output: $_" $colorError
        return $false
    }
}

# ============================================================
#  20. INVOKE-CONVERSION (the main engine)
# ============================================================
function Invoke-Conversion {
    param(
        [string]$SourcePath,
        [string]$OutputName,
        [ValidateSet('PveToVm','VmToPve')][string]$Direction
    )

    $jobStart = Get-Date
    $jobResult = 'FAILED'
    $jobExit = 1
    $jobOutputPath = $null
    $jobOutputBytes = [long]0
    $srcSize = [long]0
    $verifyNote = 'not run'
    $conversionAttempted = $false

    $script:LastJobResult = $null

    try {
        if (-not (Check-Docker)) {
            if ($script:FormIsClosing) { return $null }
            $null = Show-Message -Text "Docker Desktop is not running or not installed.`n`nStart Docker Desktop and try again." -Title "Docker Required" -Buttons OK -Icon Error
            return $null
        }

        if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path -LiteralPath $SourcePath)) {
            if ($script:FormIsClosing) { return $null }
            $null = Show-Message -Text "Please select a valid source file first." -Title "No File Selected" -Buttons OK -Icon Warning
            return $null
        }

        $directory = [System.IO.Path]::GetDirectoryName($SourcePath)
        $fileName  = [System.IO.Path]::GetFileName($SourcePath)

        $driveCheck = Test-FixedDrive -Directory $directory
        if (-not $driveCheck.OK) {
            if ($script:FormIsClosing) { return $null }
            $hint = if ($driveCheck.Hint) { "`n`n$($driveCheck.Hint)" } else { "" }
            $null = Show-Message -Text "The source folder cannot be mounted by Docker:`n`n$($driveCheck.Reason)$hint" -Title "Unsupported Drive" -Buttons OK -Icon Error
            return $null
        }
        $directory = $driveCheck.Path

        # Headless split-segment redirect. Set-File does this for the GUI; the
        # headless path must reach qemu-img with the descriptor, not one slice.
        if ($fileName -match '^(.+)-s\d{3}\.vmdk$') {
            $descriptorName = $matches[1] + '.vmdk'
            $descriptorPath = [System.IO.Path]::Combine($directory, $descriptorName)
            if (Test-Path -LiteralPath $descriptorPath -PathType Leaf) {
                Write-Log "Selected split segment '$fileName' - switching to the descriptor '$descriptorName'." $colorWarning
                $SourcePath = $descriptorPath
                $fileName   = $descriptorName
            } else {
                if ($script:FormIsClosing) { return $null }
                $null = Show-Message -Text "'$fileName' is a segment of a split VMDK, and its descriptor '$descriptorName' was not found in the same folder.`n`nConverting a single segment would produce a truncated disk. Point the converter at the descriptor, or restore the missing file." -Title "Incomplete Split VMDK" -Buttons OK -Icon Error
                return $null
            }
        }

        # VMware locks: both .lck directories and .lck files (VMware uses both).
        $locks = @(Get-ChildItem -LiteralPath $directory -Filter "*.lck" -ErrorAction SilentlyContinue)
        if ($locks.Count -gt 0) {
            if ($script:FormIsClosing) { return $null }
            $null = Show-Message -Text "A VMware lock (.lck) was found in the source directory.`n`nPlease power off the VM in VMware and DELETE the .lck entry before converting." -Title "VMware Lock Detected" -Buttons OK -Icon Warning
            return $null
        }

        if (Test-FileLocked -Path $SourcePath) {
            if ($script:FormIsClosing) { return $null }
            $null = Show-Message -Text "The source file is locked by another process.`n`nClose any tool or VM using it and retry." -Title "File Locked" -Buttons OK -Icon Error
            return $null
        }
        $srcInfo = Get-SourceDiskInfo -FilePath $SourcePath -Directory $directory
        if ($srcInfo.IsSplit) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            foreach ($seg in @(Get-ChildItem -LiteralPath $directory -Filter "$baseName-s*.vmdk" -File -ErrorAction SilentlyContinue)) {
                if (Test-FileLocked -Path $seg.FullName) {
                    if ($script:FormIsClosing) { return $null }
                    $null = Show-Message -Text "Segment file is locked: $($seg.Name)`n`nClose any tool or VM using it and retry." -Title "File Locked" -Buttons OK -Icon Error
                    return $null
                }
            }
        }

        if ($Direction -eq 'PveToVm' -and $fileName -notmatch '\.vma\.zst$') {
            $r = Show-Message -Text "You selected 'Proxmox (.vma.zst) -> VMware (.vmdk)',`nbut the source file is not a .vma.zst archive:`n`n$fileName`n`nContinue anyway?" -Title "Direction Mismatch" -Buttons YesNo -Icon Warning
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return $null }
        }
        if ($Direction -eq 'VmToPve' -and $fileName -notmatch '\.vmdk$') {
            $r = Show-Message -Text "You selected 'VMware (.vmdk) -> Proxmox (.qcow2)',`nbut the source file is not a .vmdk disk:`n`n$fileName`n`nContinue anyway?" -Title "Direction Mismatch" -Buttons YesNo -Icon Warning
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return $null }
        }

        $targetExt = if ($Direction -eq 'PveToVm') { ".vmdk" } else { ".qcow2" }
        $outName = Get-NormalizedOutputName -Name $OutputName -TargetExt $targetExt
        if (-not (Test-ValidFileName $outName)) {
            if ($script:FormIsClosing) { return $null }
            $null = Show-Message -Text "The output filename is invalid or empty.`n`nPlease enter a name like 'myvm$targetExt'." -Title "Invalid Output Name" -Buttons OK -Icon Error
            return $null
        }
        $outputPath = [System.IO.Path]::Combine($directory, $outName)
        $cmpOut = [System.IO.Path]::GetFullPath($outputPath)
        $cmpSrc = [System.IO.Path]::GetFullPath($SourcePath)
        if ([string]::Equals($cmpOut, $cmpSrc, [StringComparison]::OrdinalIgnoreCase)) {
            if ($script:FormIsClosing) { return $null }
            $null = Show-Message -Text "Output cannot overwrite the source file." -Title "Invalid Output" -Buttons OK -Icon Error
            return $null
        }
        if (Test-Path -LiteralPath $outputPath) {
            $r = Show-Message -Text "File '$outName' already exists. Overwrite?" -Title "Confirm Overwrite" -Buttons YesNo -Icon Question -DefaultNo
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return $null }
        }

        $staleCount = Initialize-Cleanup

        if ($Direction -eq 'PveToVm') {
            $leftovers = @(Get-PveToVmLeftovers -Directory $directory -FileName $fileName)
            if ($leftovers.Count -gt 0) {
                $list = ($leftovers | ForEach-Object { "  - $_" }) -join "`n"
                if ($script:ConfigAutoCleanupLeftovers) {
                    Write-Log "Auto-removing leftover intermediate files from a previous run:" $colorWarning
                    foreach ($lo in $leftovers) { Write-Log "  - $lo" $colorTextMuted }
                } else {
                    $r = Show-Message -Text "Leftover files from a previous conversion attempt were found:`n`n$list`n`nThese block the converter. Delete them and continue?" -Title "Leftover Files" -Buttons YesNo -Icon Warning
                    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
                        Write-Log "Conversion cancelled - user declined to remove leftover files." $colorWarning
                        $jobResult = 'CANCELLED'; $jobExit = 2
                        return $null
                    }
                }
                foreach ($lo in $leftovers) {
                    try {
                        if (Test-Path -LiteralPath $lo -PathType Container) {
                            Remove-Item -LiteralPath $lo -Recurse -Force -ErrorAction Stop
                        } else {
                            Remove-Item -LiteralPath $lo -Force -ErrorAction Stop
                        }
                    } catch {
                        if ($script:FormIsClosing) { return $null }
                        $null = Show-Message -Text "Could not delete leftover: $lo`n`n$_`n`nPlease delete it manually and try again." -Title "Cleanup Failed" -Buttons OK -Icon Error
                        return $null
                    }
                }
            }
        }

        $srcSize = $srcInfo.EffectiveSize

        $preflight = Test-SourceImage -Directory $directory -FileName $fileName -Direction $Direction
        if (-not $preflight.OK) {
            # A user cancel produces Reason='cancelled'; report CANCELLED,
            # not a misleading "validation failed".
            if ($preflight.Reason -eq 'cancelled') {
                Write-Log "Preflight cancelled by user." $colorWarning
                $jobResult = 'CANCELLED'; $jobExit = 2
                return $null
            }
            if ($script:FormIsClosing) { return $null }
            $null = Show-Message -Text "Pre-flight validation failed:`n`n$($preflight.Reason)`n`nThe source file appears corrupt or mislabelled. Conversion would almost certainly fail." -Title "Source Validation Failed" -Buttons OK -Icon Error
            return $null
        }
        if (-not $preflight.Skipped -and $preflight.Format) {
            $vsize = if ($preflight.VirtualSize -gt 0) { " / virtual $(Format-Bytes $preflight.VirtualSize)" } else { "" }
            Write-Log "Pre-flight OK - format: $($preflight.Format)$vsize" $colorSuccess
        }

        $free = Get-DiskFreeSpace -Directory $directory
        if ($free -lt 0) {
            Write-Log "WARNING: could not determine free disk space." $colorWarning
        } else {
            if ($Direction -eq 'PveToVm') {
                $strict = [long]($srcSize * 4)
                $comfy  = [long]($srcSize * 10)
            } elseif ($srcInfo.IsSplit) {
                $strict = [long]($srcSize * 2.0)
                $comfy  = [long]($srcSize * 2.5)
            } else {
                $strict = [long]($srcSize * 1.0)
                $comfy  = [long]($srcSize * 1.5)
            }
            if ($free -lt $strict) {
                if ($script:FormIsClosing) { return $null }
                $null = Show-Message -Text "Not enough disk space.`n`nFree  : $(Format-Bytes $free)`nNeed  : $(Format-Bytes $strict) minimum`n`nThe conversion will almost certainly fail. Please free up space first." -Title "Insufficient Disk Space" -Buttons OK -Icon Error
                return $null
            } elseif ($free -lt $comfy) {
                $r = Show-Message -Text "Disk space is tight.`n`nFree  : $(Format-Bytes $free)`nWant  : $(Format-Bytes $comfy) recommended`n`nProceed anyway?" -Title "Disk Space Warning" -Buttons YesNo -Icon Warning
                if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return $null }
            }
        }

        # Lock UI - disable the toolbar too so opening Settings during a
        # conversion cannot silently change QemuMode / MinLogLevel under the
        # running job, and cannot freeze progress behind a modal dialog.
        if (-not $script:HeadlessMode) {
            $btnConvert.Enabled   = $false
            $btnConvert.Text      = "CONVERTING..."
            $btnConvert.BackColor = $colorBorder
            $btnCancel.Visible    = $true
            $btnCancel.Enabled    = $true
            $btnCancel.Text       = "CANCEL"
            $btnCancel.BackColor  = $colorCancel
            $btnHistory.Enabled   = $false
            $btnSupport.Enabled   = $false
            $btnSettings2.Enabled = $false
            $btnSettings.Enabled  = $false
            $progressBar.Visible  = $true
            $progressBar.MarqueeAnimationSpeed = 30
            $progressBar.Style    = [System.Windows.Forms.ProgressBarStyle]::Marquee
            $progressBar.Value    = 0
            $txtLog.Clear()
            $script:LogLineCount = 0
        }

        $script:CancelRequested = $false
        $script:CurrentProcess  = $null
        $script:ConversionStart = Get-Date
        $script:ContainerName   = "vmconvert_" + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $script:LastProcessOutput = ''
        $script:CurrentProgressPercent = -1
        $script:WatchdogDirectory = $directory
        $script:WatchdogMinFreeBytes = $script:ConfigWatchdogMinFreeBytes
        $script:WatchdogLastCheck = [DateTime]::MinValue
        $script:WatchdogTripped = $false

        $conversionAttempted = $true
        $conversionStartTime = Get-Date

        Write-Log "=== VM Converter Pro v$ScriptVersion ($ScriptBuild) - $ScriptAuthor ===" $colorAccent
        if ($staleCount -gt 0) { Write-Log "Cleaned up $staleCount stale container(s) before starting." $colorTextMuted }
        if ($srcInfo.IsSplit) {
            Write-Log "Source : $fileName  (split: $($srcInfo.PartCount) parts, $(Format-Bytes $srcSize) total)" $colorText
        } else {
            Write-Log "Source : $fileName  ($(Format-Bytes $srcSize))" $colorText
        }
        Write-Log "Output : $outName" $colorText
        Write-Log "Folder : $directory" $colorText
        if ($free -ge 0) { Write-Log "Free   : $(Format-Bytes $free)" $colorText }
        Write-Log "----------------------------------------" $colorText

        $tempVmdkPath  = $null
        $tempScriptDir = $null
        $partialPath   = $null
        $keepIntermediates = $false
        $finalSuccess = $false
        $verifyNote   = 'not run'

        try {
            $image = if ($Direction -eq 'PveToVm') { $script:ConfigPveToVmImage } else { $script:ConfigVmToPveImage }
            if (-not (Ensure-DockerImage -Image $image)) {
                if ($script:CancelRequested) {
                    Write-Log "Aborting: conversion cancelled during image pull." $colorWarning
                    $jobResult = 'CANCELLED'; $jobExit = 2
                } else {
                    Write-Log "Aborting: image unavailable." $colorError
                }
                return $null
            }
            $script:LastProcessOutput = ''

            if ($Direction -eq 'PveToVm') {
                Write-Log "Executing Docker (Proxmox -> VMware)..." $colorWarning
                Write-Log "Image : $($script:ConfigPveToVmImage)" $colorText

                $dockerArgs = "run --rm --name $($script:ContainerName) " +
                              "-v `"${directory}:/data`" -w /data " +
                              "$($script:ConfigPveToVmImage) `"$fileName`""

                $exitCode = Invoke-SafeProcess -Exe "docker" -ArgsString $dockerArgs -WorkingDirectory $directory

                $newVmdks = @(Get-ChildItem -LiteralPath $directory -Filter "*.vmdk" -File -ErrorAction SilentlyContinue |
                              Where-Object { $_.LastWriteTime -gt $conversionStartTime } |
                              Sort-Object LastWriteTime -Descending)

                $descriptor = $newVmdks | Where-Object { $_.Name -notmatch '-(s\d{3}|flat)\.vmdk$' } | Select-Object -First 1
                if ($descriptor) {
                    $produced = $descriptor.FullName
                }
                elseif ($newVmdks.Count -gt 0) {
                    $firstSeg = $newVmdks[0]
                    if ($firstSeg.Name -match '^(.+)-s\d{3}\.vmdk$') {
                        $derived = [System.IO.Path]::Combine($directory, "$($matches[1]).vmdk")
                        $produced = if (Test-Path -LiteralPath $derived) { $derived } else { $firstSeg.FullName }
                    } else {
                        $produced = $firstSeg.FullName
                    }
                }
                else { $produced = $null }

                $hasFile      = ($produced -and (Test-Path -LiteralPath $produced))
                $producedSize = if ($hasFile) { [long](Get-Item -LiteralPath $produced).Length } else { 0 }
                $meetsMinSize = ($producedSize -ge $script:ConfigMinOutputBytes)
                $outputMarkerOk = $script:LastProcessOutput -match '(?im)All operations complete|conversion successful|successfully converted|^Success'
                $isSplitOut   = @($newVmdks | Where-Object { $_.Name -match '-s\d{3}\.vmdk$' }).Count -gt 0

                if ($exitCode -eq -1) {
                    Write-Log "`n[CANCELLED] Conversion cancelled by user." $colorWarning
                    $jobResult = 'CANCELLED'; $jobExit = 2
                }
                elseif ($exitCode -eq -2) {
                    Write-Log "`n[ERROR] Failed to launch docker.exe." $colorError
                    $jobResult = 'FAILED'; $jobExit = 1
                }
                elseif ($exitCode -eq 0 -and $hasFile -and $producedSize -gt 0) {
                    if ($isSplitOut) { Write-Log "Output is a split VMDK; renaming descriptor and segments consistently." $colorText }
                    try {
                        Rename-VmdkSet -SourcePath $produced -TargetPath $outputPath
                        Write-Log "`n[SUCCESS] Conversion complete - $(Format-Bytes $producedSize)" $colorSuccess
                        Write-Log "Saved: $outputPath" $colorSuccess
                        $finalSuccess = $true
                        $jobOutputPath = $outputPath
                        $jobOutputBytes = $producedSize
                        $jobResult = 'SUCCESS'; $jobExit = 0
                        $verifyNote = 'not applicable (.vmdk)'
                        if ($script:ConfigAutoCleanupLeftovers) {
                            $leftovers = @(Get-PveToVmLeftovers -Directory $directory -FileName $fileName)
                            if ($leftovers.Count -gt 0) {
                                Remove-Leftovers -Paths $leftovers
                                Write-Log "Cleaned up $($leftovers.Count) intermediate(s)." $colorTextMuted
                            }
                        }
                    } catch {
                        Write-Log "`n[ERROR] Could not finalize output rename: $_" $colorError
                        Write-Log "Raw output remains at: $produced" $colorWarning
                        $jobResult = 'FAILED'; $jobExit = 1
                    }
                }
                elseif ($exitCode -eq -3 -and $hasFile -and $meetsMinSize) {
                    try {
                        Rename-VmdkSet -SourcePath $produced -TargetPath $outputPath
                        Write-Log "`n[SUCCESS] Conversion complete (exit code unreadable) - $(Format-Bytes $producedSize)" $colorSuccess
                        Write-Log "Saved: $outputPath" $colorSuccess
                        Write-Log "Please verify the resulting disk in VMware." $colorWarning
                        $finalSuccess = $true
                        $jobOutputPath = $outputPath
                        $jobOutputBytes = $producedSize
                        $jobResult = 'SUCCESS'; $jobExit = 0
                        $verifyNote = 'verify manually'
                        if ($script:ConfigAutoCleanupLeftovers) {
                            $leftovers = @(Get-PveToVmLeftovers -Directory $directory -FileName $fileName)
                            if ($leftovers.Count -gt 0) {
                                Remove-Leftovers -Paths $leftovers
                                Write-Log "Cleaned up $($leftovers.Count) intermediate(s)." $colorTextMuted
                            }
                        }
                    } catch {
                        Write-Log "`n[ERROR] Could not finalize output rename: $_" $colorError
                        $jobResult = 'FAILED'; $jobExit = 1
                    }
                }
                elseif ($exitCode -ne 0 -and $exitCode -ne -1 -and $exitCode -ne -2 -and $exitCode -ne -3 -and
                        $hasFile -and $meetsMinSize -and $outputMarkerOk) {
                    try {
                        Rename-VmdkSet -SourcePath $produced -TargetPath $outputPath
                        Write-Log "`n[SUCCESS] Conversion complete despite exit code $exitCode - $(Format-Bytes $producedSize)" $colorWarning
                        Write-Log "Saved: $outputPath" $colorSuccess
                        $finalSuccess = $true
                        $jobOutputPath = $outputPath
                        $jobOutputBytes = $producedSize
                        $jobResult = 'SUCCESS'; $jobExit = 0
                        $verifyNote = "recovered from exit $exitCode"
                        if ($script:ConfigAutoCleanupLeftovers) {
                            $leftovers = @(Get-PveToVmLeftovers -Directory $directory -FileName $fileName)
                            if ($leftovers.Count -gt 0) {
                                Remove-Leftovers -Paths $leftovers
                                Write-Log "Cleaned up $($leftovers.Count) intermediate(s)." $colorTextMuted
                            }
                        }
                    } catch {
                        Write-Log "`n[ERROR] Could not finalize output rename: $_" $colorError
                        $jobResult = 'FAILED'; $jobExit = 1
                    }
                }
                elseif ($hasFile -and $producedSize -gt 0) {
                    Write-Log "`n[UNCERTAIN] A .vmdk exists ($(Format-Bytes $producedSize)) but the conversion did not signal success." $colorWarning
                    Write-Log "         Exit code: $exitCode  |  Marker: $outputMarkerOk" $colorWarning
                    Write-Log "         Raw output: $produced" $colorWarning
                    $jobResult = 'UNCERTAIN'; $jobExit = 3
                    $jobOutputPath = $produced
                    $jobOutputBytes = $producedSize
                }
                else {
                    $ec = if ($null -eq $exitCode -or "$exitCode" -eq '') { 'unknown' } else { $exitCode }
                    if ($exitCode -eq 0) {
                        Write-Log "`n[ERROR] The tool reported success but produced no usable output file." $colorError
                    } else {
                        Write-Log "`n[ERROR] Conversion failed (exit code $ec)." $colorError
                    }
                    if ($script:LastProcessOutput -match 'No space left') {
                        Write-Log "[HINT] Disk full on the container side." $colorWarning
                    }
                    if ($script:LastProcessOutput -match '(?i)killed|OOMKilled|out of memory') {
                        Write-Log "[HINT] Container appears to have been OOM-killed." $colorWarning
                    }
                    if (-not $script:ConfigKeepIntermediatesOnFailure) {
                        Remove-Leftovers -Paths @(Get-PveToVmLeftovers -Directory $directory -FileName $fileName)
                        foreach ($pv in $newVmdks) {
                            try { Remove-Item -LiteralPath $pv.FullName -Force -ErrorAction Stop } catch { }
                        }
                    } else { $keepIntermediates = $true }
                    $jobResult = 'FAILED'; $jobExit = 1
                }
            }
            else {
                $vdiskManager    = Find-VDiskManager
                $sourceToConvert = $fileName

                if ($srcInfo.IsSplit) {
                    if ($vdiskManager) {
                        Write-Log "Split VMDK detected - consolidating..." $colorWarning
                        $tempName     = "temp_" + [guid]::NewGuid().ToString('N') + ".vmdk"
                        $tempVmdkPath = [System.IO.Path]::Combine($directory, $tempName)
                        $vdiskArgs    = "-r `"$SourcePath`" -t 0 `"$tempVmdkPath`""
                        $vc = Invoke-SafeProcess -Exe $vdiskManager -ArgsString $vdiskArgs -WorkingDirectory $directory

                        $vdiskOutput = $script:LastProcessOutput
                        $fileOk = $false
                        try {
                            $fileOk = (Test-Path -LiteralPath $tempVmdkPath) -and ((Get-Item -LiteralPath $tempVmdkPath).Length -gt 0)
                        } catch { }
                        $outputOk = $vdiskOutput -match '(?im)Virtual disk conversion successful'

                        if (($vc -eq 0 -or $outputOk) -and $fileOk) {
                            if ($vc -ne 0 -and $outputOk) {
                                Write-Log "Consolidation OK (vdiskmanager exit $vc, but output confirmed success)." $colorSuccess
                            } else {
                                Write-Log "Consolidation OK - converting to QCOW2..." $colorSuccess
                            }
                            $sourceToConvert = $tempName
                        } elseif ($vc -eq -1) {
                            Write-Log "Consolidation cancelled." $colorWarning
                            $jobResult = 'CANCELLED'; $jobExit = 2
                            return $null
                        } elseif ($vc -eq -2) {
                            Write-Log "Failed to launch vmware-vdiskmanager.exe." $colorError
                        } else {
                            $vcText = if ($null -eq $vc) { 'unknown' } else { $vc }
                            Write-Log "Consolidation failed (exit $vcText, file=$fileOk, marker=$outputOk)." $colorWarning
                            Write-Log "Trying direct conversion (may fail)..." $colorWarning
                        }
                    } else {
                        Write-Log "Split VMDK but vmware-vdiskmanager.exe not found!" $colorError
                        Write-Log "Attempting direct conversion (may fail)..." $colorWarning
                    }
                }

                $partialName = $outName + '.partial'
                $partialPath = [System.IO.Path]::Combine($directory, $partialName)
                if (Test-Path -LiteralPath $partialPath) {
                    try { Remove-Item -LiteralPath $partialPath -Force -ErrorAction Stop } catch { }
                }

                $srcSafe = Get-SafeEnvValue $sourceToConvert
                $outSafe = Get-SafeEnvValue $partialName

                $tempScriptDir = Join-Path $env:TEMP ("vmconvert_" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $tempScriptDir -Force | Out-Null
                $tempScriptPath = Join-Path $tempScriptDir "convert.sh"

                $bashContent = @'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "[convert] Source : $SRC"
echo "[convert] Output : $OUT"
echo "[convert] Mode   : $QEMU_MODE"
echo "[convert] Installing qemu-utils..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends qemu-utils
echo "[convert] qemu-utils ready"

# -m must stay <= 16: qemu-img rejects anything higher with "Invalid number
# of coroutines. Allowed number of coroutines is between 1 and 16", which made
# the old Fast preset (-m 32) fail instantly. -W (--target-is-zero) requires
# -n and is meaningless when qemu-img creates the output itself, so it is gone.
case "$QEMU_MODE" in
    Safe)      QEMU_FLAGS="-t none -m 8"          ;;
    Fast)      QEMU_FLAGS="-t unsafe -m 16"       ;;
    Balanced|*) QEMU_FLAGS="-t writeback -m 16"   ;;
esac

echo "[convert] Converting VMDK -> QCOW2..."
qemu-img convert $QEMU_FLAGS -p -f vmdk -O qcow2 "$SRC" "$OUT"
echo "[convert] Conversion complete"

echo "[verify] Running qemu-img check..."
set +e
qemu-img check "$OUT"
CHECK_EXIT=$?
case $CHECK_EXIT in
    0) echo "[verify] CLEAN - image is valid" ;;
    1) echo "[verify] WARNING - corrupted image (data errors found)" ;;
    2) echo "[verify] WARNING - unsupported feature in image" ;;
    3) echo "[verify] WARNING - other errors found" ;;
    *) echo "[verify] UNKNOWN exit code $CHECK_EXIT" ;;
esac
set -e

echo "[done] All operations complete"
exit 0
'@ -replace "`r`n", "`n"

                [System.IO.File]::WriteAllText($tempScriptPath, $bashContent, [System.Text.Encoding]::ASCII)

                Write-Log "Executing Docker (VMware -> Proxmox)..." $colorWarning
                Write-Log "Image : $($script:ConfigVmToPveImage)  |  Mode: $($script:ConfigQemuMode)" $colorText

                $dockerArgs = "run --rm --name $($script:ContainerName) " +
                              "-e `"DEBIAN_FRONTEND=noninteractive`" " +
                              "-e `"SRC=$srcSafe`" " +
                              "-e `"OUT=$outSafe`" " +
                              "-e `"QEMU_MODE=$($script:ConfigQemuMode)`" " +
                              "-v `"${directory}:/data`" " +
                              "-v `"${tempScriptDir}:/scripts:ro`" " +
                              "-w /data " +
                              "$($script:ConfigVmToPveImage) " +
                              "bash /scripts/convert.sh"

                $exitCode = Invoke-SafeProcess -Exe "docker" -ArgsString $dockerArgs -WorkingDirectory $directory

                $hasFile    = Test-Path -LiteralPath $partialPath
                $outputSize = if ($hasFile) { [long](Get-Item -LiteralPath $partialPath).Length } else { 0 }
                $isFresh    = $hasFile -and ((Get-Item -LiteralPath $partialPath).LastWriteTime -gt $conversionStartTime)
                $meetsMin   = ($outputSize -ge $script:ConfigMinOutputBytes)
                $outputMarkerOk = $script:LastProcessOutput -match '(?im)\[done\] All operations complete'
                $verifyNote = if ($script:LastProcessOutput -match '(?im)\[verify\]\s+WARNING') { 'qemu-img: WARNING' }
                              elseif ($script:LastProcessOutput -match '(?im)\[verify\]\s+CLEAN') { 'qemu-img: CLEAN' }
                              else { 'not confirmed' }

                if ($exitCode -eq -1) {
                    Write-Log "`n[CANCELLED] Conversion cancelled by user." $colorWarning
                    $jobResult = 'CANCELLED'; $jobExit = 2
                }
                elseif ($exitCode -eq -2) {
                    Write-Log "`n[ERROR] Failed to launch docker.exe." $colorError
                    $jobResult = 'FAILED'; $jobExit = 1
                }
                elseif ($exitCode -eq 0 -and $hasFile -and $outputSize -gt 0) {
                    if (Promote-PartialOutput -PartialPath $partialPath -FinalPath $outputPath) {
                        Write-Log "`n[SUCCESS] Conversion + verification complete - $(Format-Bytes $outputSize)" $colorSuccess
                        Write-Log "Saved: $outputPath" $colorSuccess
                        $finalSuccess = $true
                        $jobOutputPath = $outputPath
                        $jobOutputBytes = $outputSize
                        $jobResult = 'SUCCESS'; $jobExit = 0
                        if ($script:LastProcessOutput -match '(?im)\[verify\]\s+WARNING') {
                            Write-Log "[WARN] qemu-img check reported warnings - see [verify] lines above." $colorWarning
                        }
                    } else {
                        $jobResult = 'FAILED'; $jobExit = 1
                    }
                }
                elseif ($exitCode -eq -3 -and $hasFile -and $isFresh -and $meetsMin) {
                    if (Promote-PartialOutput -PartialPath $partialPath -FinalPath $outputPath) {
                        Write-Log "`n[SUCCESS] Conversion complete (exit code unreadable) - $(Format-Bytes $outputSize)" $colorSuccess
                        Write-Log "Saved: $outputPath" $colorSuccess
                        $finalSuccess = $true
                        $jobOutputPath = $outputPath
                        $jobOutputBytes = $outputSize
                        $jobResult = 'SUCCESS'; $jobExit = 0
                    } else {
                        $jobResult = 'FAILED'; $jobExit = 1
                    }
                }
                elseif ($exitCode -ne 0 -and $exitCode -ne -1 -and $exitCode -ne -2 -and $exitCode -ne -3 -and
                        $hasFile -and $isFresh -and $meetsMin -and $outputMarkerOk) {
                    if (Promote-PartialOutput -PartialPath $partialPath -FinalPath $outputPath) {
                        Write-Log "`n[SUCCESS] Conversion complete despite exit code $exitCode - $(Format-Bytes $outputSize)" $colorWarning
                        Write-Log "Saved: $outputPath" $colorSuccess
                        $finalSuccess = $true
                        $jobOutputPath = $outputPath
                        $jobOutputBytes = $outputSize
                        $jobResult = 'SUCCESS'; $jobExit = 0
                    } else {
                        $jobResult = 'FAILED'; $jobExit = 1
                    }
                }
                elseif ($hasFile -and $isFresh -and $outputSize -gt 0) {
                    Write-Log "`n[UNCERTAIN] A .qcow2.partial exists ($(Format-Bytes $outputSize)) but conversion did not signal success." $colorWarning
                    Write-Log "         Exit code: $exitCode  |  Marker: $outputMarkerOk" $colorWarning
                    Write-Log "         Partial file: $partialPath" $colorWarning
                    if ([int]$exitCode -ge 128) {
                        Write-Log "[HINT] Exit $exitCode = killed by signal $([int]$exitCode - 128); the partial cannot be used." $colorWarning
                        Write-Log "[HINT] Usually an out-of-memory kill - raise Docker Desktop's memory limit or use QEMU mode 'Fast'." $colorWarning
                    }
                    $jobResult = 'UNCERTAIN'; $jobExit = 3
                    $jobOutputPath = $partialPath
                    $jobOutputBytes = $outputSize
                }
                else {
                    $ec = if ($null -eq $exitCode -or "$exitCode" -eq '') { 'unknown' } else { $exitCode }
                    if ($exitCode -eq 0) {
                        Write-Log "`n[ERROR] The tool reported success but produced no usable output file." $colorError
                    } else {
                        Write-Log "`n[ERROR] Conversion failed (exit code $ec)." $colorError
                    }
                    if ($script:LastProcessOutput -match 'No space left') {
                        Write-Log "[HINT] Disk full on the container side." $colorWarning
                    }
                    if ($script:LastProcessOutput -match '(?i)killed|OOMKilled|out of memory') {
                        Write-Log "[HINT] Container appears to have been OOM-killed." $colorWarning
                    }
                    $jobResult = 'FAILED'; $jobExit = 1
                }
            }
        }
        catch {
            Write-Log "`n[FATAL] $_" $colorError
            $jobResult = 'FAILED'; $jobExit = 1
        }
        finally {
            if ($tempVmdkPath -and (Test-Path -LiteralPath $tempVmdkPath)) {
                try {
                    Remove-Item -LiteralPath $tempVmdkPath -Force -ErrorAction Stop
                    Write-Log "Temporary consolidated VMDK removed." $colorText
                } catch { Write-Log "WARNING: could not delete temp file: $tempVmdkPath" $colorWarning }
            }
            if ($tempScriptDir -and (Test-Path -LiteralPath $tempScriptDir)) {
                try { Remove-Item -LiteralPath $tempScriptDir -Recurse -Force -ErrorAction Stop } catch { }
            }

            # An UNCERTAIN outcome keeps its .partial: it is the only artifact
            # of the partial conversion and the toast says to verify it.
            if ($partialPath -and (Test-Path -LiteralPath $partialPath)) {
                if ($jobResult -eq 'UNCERTAIN') {
                    Write-Log "Kept the unverified output for inspection: $partialPath" $colorWarning
                    Write-Log "         It is NOT a complete disk - the conversion never signalled success." $colorWarning
                } elseif (-not $finalSuccess) {
                    try {
                        Remove-Item -LiteralPath $partialPath -Force -ErrorAction Stop
                        Write-Log "Removed partial output after failure/cancel." $colorWarning
                    } catch { }
                }
            }

            if ($script:CancelRequested -and -not $finalSuccess) {
                if ($Direction -eq 'VmToPve') {
                    if (Test-Path -LiteralPath $outputPath) {
                        $fi = Get-Item -LiteralPath $outputPath -ErrorAction SilentlyContinue
                        if ($fi -and $fi.LastWriteTime -gt $conversionStartTime) {
                            try { Remove-Item -LiteralPath $outputPath -Force -ErrorAction Stop } catch { }
                        }
                    }
                } elseif ($Direction -eq 'PveToVm') {
                    $partials = @(Get-ChildItem -LiteralPath $directory -Filter "*.vmdk" -File -ErrorAction SilentlyContinue |
                                  Where-Object { $_.LastWriteTime -gt $conversionStartTime })
                    foreach ($p in $partials) {
                        try { Remove-Item -LiteralPath $p.FullName -Force -ErrorAction Stop } catch { }
                    }
                    if ($script:ConfigAutoCleanupLeftovers -and -not $script:ConfigKeepIntermediatesOnFailure) {
                        $leftovers = @(Get-PveToVmLeftovers -Directory $directory -FileName $fileName)
                        if ($leftovers.Count -gt 0) {
                            Remove-Leftovers -Paths $leftovers
                            Write-Log "Removed $($leftovers.Count) intermediate(s) after cancel." $colorText
                        }
                    }
                }
            }

            if ($keepIntermediates) { Write-Log "Intermediates preserved (see paths above)." $colorWarning }

            $elapsed = (Get-Date) - $conversionStartTime
            Write-Log "----------------------------------------" $colorText
            Write-Log "Elapsed: $(Format-Duration $elapsed)" $colorText
            $newFree = Get-DiskFreeSpace -Directory $directory
            if ($newFree -ge 0) { Write-Log "Free now: $(Format-Bytes $newFree)" $colorText }
            switch ($jobResult) {
                'SUCCESS'   { Write-Log "RESULT: SUCCESS" $colorSuccess }
                'CANCELLED' { Write-Log "RESULT: CANCELLED - no output was kept." $colorWarning }
                'UNCERTAIN' { Write-Log "RESULT: UNCERTAIN - output written but not verified; see hints above." $colorWarning }
                default     { Write-Log "RESULT: FAILED" $colorError }
            }

            if (-not $script:HeadlessMode -and -not $script:FormIsClosing) {
                try {
                    $progressBar.MarqueeAnimationSpeed = 0
                    $progressBar.Style     = [System.Windows.Forms.ProgressBarStyle]::Marquee
                    $progressBar.Visible   = $false
                    $btnConvert.Enabled    = $true
                    $btnConvert.Text       = "START CONVERSION"
                    $btnConvert.BackColor  = $colorAccent
                    $btnCancel.Visible     = $false
                    $btnCancel.Enabled     = $true
                    $btnCancel.Text        = "CANCEL"
                    $btnCancel.BackColor   = $colorCancel
                    $btnHistory.Enabled    = $true
                    $btnSupport.Enabled    = $true
                    $btnSettings2.Enabled  = $true
                    $btnSettings.Enabled   = $true
                    $null = Check-Docker
                } catch { }
            }

            $script:CurrentProcess  = $null
            $script:CancelRequested = $false
            $script:ConversionStart = $null
            $script:ContainerName   = $null
            $script:WatchdogDirectory = $null
            $script:WatchdogTripped = $false
        }

        return $null
    }
    finally {
        if ($conversionAttempted) {
            $duration = (Get-Date) - $jobStart

            if ($jobResult -eq 'SUCCESS') {
                if ($jobOutputPath) { Add-JobHistory -Entry @{
                    Started = $jobStart; Source = $SourcePath; Output = $jobOutputPath; Direction = $Direction
                    SourceBytes = $srcSize; OutputBytes = $jobOutputBytes; Duration = $duration
                    Result = $jobResult; ExitCode = $jobExit
                } }
                Show-Toast -Title "Conversion complete" -Message "$([System.IO.Path]::GetFileName($jobOutputPath))  -  $(Format-Bytes $jobOutputBytes)  in  $(Format-Duration $duration)"
                if (-not $script:HeadlessMode -and -not $script:FormIsClosing -and $form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
                    $form.Activate()
                }
                Show-SummaryDialog -Result 'SUCCESS' -OutputPath $jobOutputPath -OutputBytes $jobOutputBytes -Duration $duration -VerifyNote $verifyNote
            }
            elseif ($jobResult -eq 'UNCERTAIN') {
                if ($jobOutputPath) { Add-JobHistory -Entry @{
                    Started = $jobStart; Source = $SourcePath; Output = $jobOutputPath; Direction = $Direction
                    SourceBytes = $srcSize; OutputBytes = $jobOutputBytes; Duration = $duration
                    Result = $jobResult; ExitCode = $jobExit
                } }
                Show-Toast -Title "Conversion uncertain" -Message "Please verify the output manually."
                Show-SummaryDialog -Result 'UNCERTAIN' -OutputPath $jobOutputPath -OutputBytes $jobOutputBytes -Duration $duration -VerifyNote $verifyNote
            }
            elseif ($jobResult -eq 'CANCELLED') {
                Add-JobHistory -Entry @{
                    Started = $jobStart; Source = $SourcePath; Output = $null; Direction = $Direction
                    SourceBytes = $srcSize; OutputBytes = 0; Duration = $duration
                    Result = $jobResult; ExitCode = $jobExit
                }
                Show-Toast -Title "Conversion cancelled" -Message "No output produced."
            }
            else {
                Add-JobHistory -Entry @{
                    Started = $jobStart; Source = $SourcePath; Output = $null; Direction = $Direction
                    SourceBytes = $srcSize; OutputBytes = 0; Duration = $duration
                    Result = $jobResult; ExitCode = $jobExit
                }
                Show-Toast -Title "Conversion failed" -Message "See the log for details."
            }

            $script:LastJobResult = [pscustomobject]@{
                Result      = $jobResult
                ExitCode    = $jobExit
                OutputPath  = $jobOutputPath
                OutputBytes = $jobOutputBytes
                Duration    = $duration
                Source      = $SourcePath
                Direction   = $Direction
            }
        }
    }
}

# ============================================================
#  21. UI EVENT HANDLERS
# ============================================================
$sharedDragEnter = {
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        $dropZone.BackColor = $colorDropZoneHover
        $dropZone.Tag.Border = $colorAccent
        $dropZone.Invalidate()
    }
}
$sharedDragLeave = {
    $dropZone.BackColor = $colorDropZone
    $dropZone.Tag.Border = $colorBorder
    $dropZone.Invalidate()
}
$sharedDragDrop  = {
    $dropZone.BackColor = $colorDropZone
    $dropZone.Tag.Border = $colorBorder
    $dropZone.Invalidate()
    $files = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($files -and $files.Count -gt 0) { Set-File -Path $files[0] }
}

$dropZone.Add_DragEnter($sharedDragEnter)
$dropZone.Add_DragLeave($sharedDragLeave)
$dropZone.Add_DragDrop($sharedDragDrop)
$lblDropText.Add_DragEnter($sharedDragEnter)
$lblDropText.Add_DragLeave($sharedDragLeave)
$lblDropText.Add_DragDrop($sharedDragDrop)

$lblDropText.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "VM Disk Files (*.vma.zst;*.vmdk)|*.vma.zst;*.vmdk|All Files (*.*)|*.*"
    $dlg.Title  = "Select source VM disk"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-File -Path $dlg.FileName
    }
})

$rbPveToVm.Add_CheckedChanged({
    if ($rbPveToVm.Checked) {
        if ($txtOutputName.Text) { $txtOutputName.Text = Get-NormalizedOutputName -Name $txtOutputName.Text -TargetExt ".vmdk" }
        $lblQemuMode.Visible = $false
        $cmbQemuMode.Visible = $false
    }
    Update-DirectionTiles
})
$rbVmToPve.Add_CheckedChanged({
    if ($rbVmToPve.Checked) {
        if ($txtOutputName.Text) { $txtOutputName.Text = Get-NormalizedOutputName -Name $txtOutputName.Text -TargetExt ".qcow2" }
        $lblQemuMode.Visible = $true
        $cmbQemuMode.Visible = $true
    }
    Update-DirectionTiles
})

$cmbLogLevel.Add_SelectedIndexChanged({
    $script:ConfigMinLogLevel = [string]$cmbLogLevel.SelectedItem
})
$cmbQemuMode.Add_SelectedIndexChanged({
    $script:ConfigQemuMode = [string]$cmbQemuMode.SelectedItem
})

$btnCancel.Add_Click({
    $script:CancelRequested = $true
    $btnCancel.Enabled = $false
    $btnCancel.Text    = "CANCELLING..."
    Write-Log "`nCancellation requested - stopping process..." $colorWarning
})

$btnCopyLog.Add_Click({
    if ($txtLog.Text.Length -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText($txtLog.Text)
        $btnCopyLog.Text      = "COPIED!"
        $btnCopyLog.BackColor = $colorSuccess
        $btnCopyLog.ForeColor = [System.Drawing.Color]::Black
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 1200
        $t.Add_Tick({
            param($s, $e)
            $btnCopyLog.Text      = "COPY LOG"
            $btnCopyLog.BackColor = $colorPanel
            $btnCopyLog.ForeColor = $colorText
            $s.Stop(); $s.Dispose()
        })
        $t.Start()
    }
})

$btnSaveLog.Add_Click({
    if ($txtLog.Text.Length -eq 0) { return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter   = "Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*"
    $dlg.FileName = "VMConverter_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $dlg.Title    = "Save conversion log"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            [System.IO.File]::WriteAllText($dlg.FileName, $txtLog.Text, [System.Text.Encoding]::UTF8)
            $btnSaveLog.Text      = "SAVED!"
            $btnSaveLog.BackColor = $colorSuccess
            $btnSaveLog.ForeColor = [System.Drawing.Color]::Black
            $t = New-Object System.Windows.Forms.Timer
            $t.Interval = 1200
            $t.Add_Tick({
                param($s, $e)
                $btnSaveLog.Text      = "SAVE LOG"
                $btnSaveLog.BackColor = $colorPanel
                $btnSaveLog.ForeColor = $colorText
                $s.Stop(); $s.Dispose()
            })
            $t.Start()
        } catch {
            $null = Show-Message -Text "Could not save log: $_" -Title "Save Failed" -Buttons OK -Icon Error
        }
    }
})

$btnHistory.Add_Click({ Show-HistoryDialog })
$btnSettings.Add_Click({ Show-SettingsDialog })
$btnSettings2.Add_Click({ Show-SettingsDialog })

$btnSupport.Add_Click({
    Write-Log "Building support bundle..." $colorText
    try {
        $zip = Export-SupportBundle -Reason 'User clicked SUPPORT button'
        Write-Log "Support bundle saved to: $zip" $colorSuccess
        $null = Show-Message -Text "Support bundle saved to:`n`n$zip`n`nAttach this file when reporting a problem." -Title "Support Bundle" -Buttons OK -Icon Information
    } catch {
        Write-Log "Failed to build support bundle: $_" $colorError
    }
})

$form.Add_KeyDown({
    param($s, $e)
    # Walk the container chain: a TextBox nested inside a panel would
    # otherwise slip through and Enter would start a conversion while the
    # user was typing. RichTextBox is a TextBoxBase, so one test covers both.
    $focusedIsText = $false
    $fc = $form.ActiveControl
    $guard = 0
    while ($null -ne $fc -and $guard -lt 16) {
        if ($fc -is [System.Windows.Forms.TextBoxBase]) { $focusedIsText = $true; break }
        if ($fc -is [System.Windows.Forms.ContainerControl] -and $null -ne $fc.ActiveControl) {
            $fc = $fc.ActiveControl
        } else {
            $fc = $fc.Parent
        }
        $guard++
    }

    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        if ($btnCancel.Visible -and $btnCancel.Enabled) { $btnCancel.PerformClick() }
        else { $form.Close() }
        $e.Handled = $true
    } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and $btnConvert.Enabled -and -not $focusedIsText) {
        $btnConvert.PerformClick()
        $e.Handled = $true
    }
})

$form.Add_FormClosing({
    param($s, $e)
    if ($script:FormIsClosing) { return }
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "A conversion is currently running.`n`nCancel it and exit?",
            "Confirm Exit",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {
            $e.Cancel = $true
            return
        }
        $script:CancelRequested = $true
        Stop-ConversionProcess -Process $script:CurrentProcess
    }
    $script:FormIsClosing = $true
})

$btnConvert.Add_Click({
    $dir = if ($rbPveToVm.Checked) { 'PveToVm' } else { 'VmToPve' }
    $null = Invoke-Conversion -SourcePath $txtFilePath.Text -OutputName $txtOutputName.Text -Direction $dir
})

# ============================================================
#  22. CLI DISPATCH
# ============================================================
function Resolve-Direction {
    param([string]$Path, [string]$DirParam)
    if ($DirParam -ne 'Auto') { return $DirParam }
    if ($Path -match '\.vma\.zst$') { return 'PveToVm' }
    if ($Path -match '\.vmdk$')     { return 'VmToPve' }
    return $null
}

if ($Headless -and -not $InputPath) {
    Write-Host "ERROR: -Headless requires -InputPath."
    exit 1
}

if ($InputPath -and $Headless) {
    $script:HeadlessMode = $true
    if ($Quiet) { $script:QuietMode = $true }
    if ($Force) { $script:ForceOverwrite = $true }

    $effDir = Resolve-Direction -Path $InputPath -DirParam $Direction
    if (-not $effDir) {
        Write-Host "ERROR: Cannot infer direction from file extension (expected .vma.zst or .vmdk). Use -Direction."
        exit 1
    }
    if (-not (Test-Path -LiteralPath $InputPath)) {
        Write-Host "ERROR: Input path not found: $InputPath"
        exit 1
    }

    $effOut = $OutputPath
    if (-not $effOut) {
        $baseName = [System.IO.Path]::GetFileName($InputPath)
        $baseName = $baseName -replace '\.vma\.zst$', '' -replace '\.vmdk$', ''
        if ($effDir -eq 'PveToVm') { $effOut = "$baseName.vmdk" } else { $effOut = "$baseName.qcow2" }
    } else {
        $reqDir = [System.IO.Path]::GetDirectoryName($effOut)
        if ($reqDir) {
            $srcDir = [System.IO.Path]::GetDirectoryName($InputPath)
            if ($reqDir.TrimEnd('\','/') -ne $srcDir.TrimEnd('\','/')) {
                Write-Host "WARNING: output is written next to the source; ignoring directory '$reqDir'."
            }
        }
        $effOut = [System.IO.Path]::GetFileName($effOut)
    }

    Write-Log "=== VM Converter Pro v$ScriptVersion (HEADLESS) ===" $colorAccent
    Write-Log "Input    : $InputPath" $colorText
    Write-Log "Output   : $effOut" $colorText
    Write-Log "Direction: $effDir" $colorText

    $null = Invoke-Conversion -SourcePath $InputPath -OutputName $effOut -Direction $effDir
    $result = $script:LastJobResult
    if ($null -eq $result) { exit 1 }
    exit $result.ExitCode
}
elseif ($InputPath) {
    if (Test-Path -LiteralPath $InputPath) {
        Set-File -Path $InputPath
        if ($OutputPath) { $txtOutputName.Text = [System.IO.Path]::GetFileName($OutputPath) }
        if ($Direction -eq 'PveToVm') { $rbPveToVm.Checked = $true }
        elseif ($Direction -eq 'VmToPve') { $rbVmToPve.Checked = $true }
    }
}

# ============================================================
#  23. INITIALIZE + SHOW FORM
# ============================================================
$dockerOK = Check-Docker

$txtLog.AppendText("VM Converter Pro v$ScriptVersion ($ScriptBuild) - $ScriptAuthor`n")
$txtLog.AppendText("Drop a file or click the drop zone to begin.`n")
$txtLog.AppendText("Shortcuts: Enter = Start (not while editing)  |  Esc = Cancel/Exit`n")
$txtLog.AppendText("Settings: $($script:ConfigSettingsFile)`n")
$txtLog.AppendText("History : $($script:ConfigHistoryFile)`n")

if ($script:SettingsLoadError) {
    Write-Log "Settings file could not be read - using defaults: $($script:SettingsLoadError)" $colorWarning
}

if ($dockerOK) {
    $cleaned = Initialize-Cleanup
    if ($cleaned -gt 0) {
        Write-Log "Cleaned up $cleaned stale container(s) from a previous session." $colorTextMuted
    }
}

if ($script:ConfigPveToVmImage -notmatch '@sha256:') {
    $txtLog.AppendText("TIP: pin the PVE->VM image by digest for reproducibility.`n")
}

[void]$form.ShowDialog()
$form.Dispose()