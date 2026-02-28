# Cockpit.ps1 - Single-window cockpit + Fixed WebView2 Runtime (no machine install needed)
# Clipboard protocol: run only when clipboard contains a line exactly: ---NEXT---
# Extract last fenced ```powershell``` block BEFORE the first marker line, run it, copy output.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure STA
try {
  if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Sta','-File', $PSCommandPath) `
      -WorkingDirectory (Split-Path -Parent $PSCommandPath)
    exit
  }
} catch { }

# ----- Paths -----
$AppDir  = Split-Path -Parent $PSCommandPath
$Root    = (Resolve-Path (Join-Path $AppDir '..')).Path
$LogsDir = Join-Path $Root 'logs'
$TmpDir  = Join-Path $LogsDir 'tmp'
$DepsLib = Join-Path $Root 'deps\WebView2\lib'
$FixedRtRoot = Join-Path $Root 'deps\WebView2\fixed'

foreach ($p in @($LogsDir,$TmpDir)) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# ----- Settings -----
$SettingsDir  = Join-Path $env:LOCALAPPDATA 'CHATGPTPROGRAM'
$SettingsPath = Join-Path $SettingsDir 'settings.json'
$WebViewUserData = Join-Path $SettingsDir 'webview2_userdata'
if (-not (Test-Path -LiteralPath $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $WebViewUserData)) { New-Item -ItemType Directory -Path $WebViewUserData -Force | Out-Null }

function Nz([object]$v, [string]$fallback='') { if ($null -eq $v) { $fallback } else { [string]$v } }

function Write-Log([string]$msg) {
  try {
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $msg
    Add-Content -LiteralPath (Join-Path $LogsDir 'cockpit.log') -Value $line -Encoding UTF8
  } catch { }
}

function Get-DefaultSettings {
  [ordered]@{
    chatUrl        = 'https://chatgpt.com/'
    workingDir     = $Root
    arm            = $true
    marker         = '---NEXT---'
    requireFence   = $true
    autoCopy       = $true
    nonInteractive = $true
    timeoutSeconds = 300
  }
}

function Load-Settings {
  $d = Get-DefaultSettings
  if (Test-Path -LiteralPath $SettingsPath) {
    try {
      $raw = Get-Content -LiteralPath $SettingsPath -Raw
      if ($raw -and $raw.Trim()) {
        $obj = $raw | ConvertFrom-Json
        foreach ($k in $d.Keys) { if ($null -ne $obj.$k) { $d[$k] = $obj.$k } }
      }
    } catch { Write-Log ("Settings load failed: " + $_.Exception.Message) }
  }
  $d
}

function Save-Settings([hashtable]$s) {
  try { $s | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SettingsPath -Encoding UTF8 -Force }
  catch { Write-Log ("Settings save failed: " + $_.Exception.Message) }
}

$Settings = Load-Settings

# ----- WPF + Clipboard -----
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

function Get-ClipboardTextSafe {
  for ($i=0; $i -lt 6; $i++) {
    try {
      if ([System.Windows.Clipboard]::ContainsText()) { return [System.Windows.Clipboard]::GetText() }
      return ''
    } catch { Start-Sleep -Milliseconds 40 }
  }
  ''
}

function Set-ClipboardTextSafe([string]$text) {
  $t = Nz $text ''
  for ($i=0; $i -lt 6; $i++) {
    try { [System.Windows.Clipboard]::SetText($t); return $true }
    catch { Start-Sleep -Milliseconds 40 }
  }
  $false
}

# ----- Parsing -----
function LooksLikeDiffOrPatch([string]$text) {
  if (-not $text) { return $false }
  return (
    $text -match '^\s*diff --git' -or
    $text -match '^\s*index [0-9a-f]+' -or
    $text -match '^\s*\+\+\+ ' -or
    $text -match '^\s*--- ' -or
    $text -match '^\s*@@ '
  )
}

function Get-MarkerIndex([string]$text, [string]$marker) {
  if (-not $text) { return -1 }
  $pattern = '(?m)^\s*' + [Regex]::Escape($marker) + '\s*$'
  $m = [Regex]::Match($text, $pattern)
  if ($m.Success) { return $m.Index }
  -1
}

function Contains-MarkerLine([string]$text, [string]$marker) {
  if (-not $text) { return $false }
  $lines = $text -split "`r?`n"
  foreach ($l in $lines) { if (($l.Trim()) -eq $marker) { return $true } }
  $false
}

function Extract-LastFencedPowerShellBeforeMarker([string]$text, [int]$markerIndex) {
  if (-not $text) { return $null }
  $pattern = '```powershell\s*([\s\S]*?)\s*```'
  $matches = [Regex]::Matches($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $matches -or $matches.Count -eq 0) { return $null }

  for ($i = $matches.Count - 1; $i -ge 0; $i--) {
    $m = $matches[$i]
    $endPos = $m.Index + $m.Length
    if ($markerIndex -lt 0 -or $endPos -le $markerIndex) { return $m.Groups[1].Value }
  }
  $null
}

# ----- Execution -----
function Invoke-PowerShellScriptFile([string]$scriptText, [string]$workingDir, [int]$timeoutSeconds, [bool]$nonInteractive) {
  $tmp = Join-Path $TmpDir ('run_' + [Guid]::NewGuid().ToString('N') + '.ps1')
  Set-Content -LiteralPath $tmp -Value (Nz $scriptText '') -Encoding UTF8 -Force

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

  $args = @('-NoProfile','-ExecutionPolicy','Bypass')
  if ($nonInteractive) { $args += '-NonInteractive' }
  $args += @('-File', $tmp)

  $psi.Arguments = ($args | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join ' '
  $psi.WorkingDirectory = $workingDir
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi

  $sbOut = New-Object System.Text.StringBuilder
  $sbErr = New-Object System.Text.StringBuilder

  $outHandler = [System.Diagnostics.DataReceivedEventHandler]{ param($sender,$e) if ($e.Data -ne $null) { [void]$sbOut.AppendLine($e.Data) } }
  $errHandler = [System.Diagnostics.DataReceivedEventHandler]{ param($sender,$e) if ($e.Data -ne $null) { [void]$sbErr.AppendLine($e.Data) } }

  $p.add_OutputDataReceived($outHandler)
  $p.add_ErrorDataReceived($errHandler)

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $timedOut = $false

  try {
    [void]$p.Start()
    $p.BeginOutputReadLine()
    $p.BeginErrorReadLine()

    $ok = $p.WaitForExit([Math]::Max(1,$timeoutSeconds) * 1000)
    if (-not $ok) {
      $timedOut = $true
      try { $p.Kill() } catch { }
      try { $p.WaitForExit(1500) } catch { }
    } else {
      try { $p.WaitForExit(300) } catch { }
    }
  } finally {
    $sw.Stop()
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
  }

  $exitCode = 1
  if ($timedOut) { $exitCode = 124 } else { try { $exitCode = $p.ExitCode } catch { $exitCode = 1 } }

  [pscustomobject]@{
    ExitCode   = $exitCode
    DurationMs = [int]$sw.ElapsedMilliseconds
    TimedOut   = $timedOut
    StdOut     = ($sbOut.ToString()).TrimEnd()
    StdErr     = ($sbErr.ToString()).TrimEnd()
  }
}

function Format-RunResult($r) {
  $tout = ''
  if ($r.TimedOut) { $tout = ' (TIMEOUT)' }
  @(
    ('ExitCode: {0}{1}' -f $r.ExitCode, $tout)
    ('DurationMs: {0}' -f $r.DurationMs)
    ''
    'STDOUT:'
    (Nz $r.StdOut '')
    ''
    'STDERR:'
    (Nz $r.StdErr '')
  ) -join "`r`n"
}

# ----- Fixed WebView2 Runtime download/use -----
function Get-FixedRuntimeExeFolder {
  if (-not (Test-Path -LiteralPath $FixedRtRoot)) { return $null }

  $arch = if ([Environment]::Is64BitOperatingSystem) { 'win-x64' } else { 'win-x86' }
  $hits = Get-ChildItem -LiteralPath $FixedRtRoot -Recurse -File -Filter 'msedgewebview2.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match [Regex]::Escape("\runtimes\$arch\native\") }

  if (-not $hits) {
    $hits = Get-ChildItem -LiteralPath $FixedRtRoot -Recurse -File -Filter 'msedgewebview2.exe' -ErrorAction SilentlyContinue
  }

  if ($hits) { return (Split-Path -Parent $hits[0].FullName) }
  return $null
}

function Ensure-FixedRuntimeDownloaded {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch {}

  if (-not (Test-Path -LiteralPath $FixedRtRoot)) { New-Item -ItemType Directory -Path $FixedRtRoot -Force | Out-Null }

  $exeFolder = Get-FixedRuntimeExeFolder
  if ($exeFolder -and (Test-Path -LiteralPath (Join-Path $exeFolder 'msedgewebview2.exe'))) {
    Write-Log "Fixed runtime already present: $exeFolder"
    return $true
  }

  $url = 'https://www.nuget.org/api/v2/package/Microsoft.WebView2.FixedVersionRuntime'
  $tmp = Join-Path $env:TEMP ('WebView2Fixed_' + [Guid]::NewGuid().ToString('N') + '.nupkg')
  $extract = Join-Path $env:TEMP ('WebView2Fixed_extract_' + [Guid]::NewGuid().ToString('N'))

  Write-Log "Downloading fixed runtime nuget..."
  if (Test-Path -LiteralPath $extract) { Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Path $extract -Force | Out-Null

  try {
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
  } catch {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($url, $tmp)
  }

  Write-Log "Extracting fixed runtime nuget..."
  [System.IO.Compression.ZipFile]::ExtractToDirectory($tmp, $extract)

  # Clear old fixed runtime content
  try {
    if (Test-Path -LiteralPath $FixedRtRoot) {
      Get-ChildItem -LiteralPath $FixedRtRoot -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch {}

  # IMPORTANT: use -Path (not -LiteralPath) because of wildcard *
  Write-Log "Copying fixed runtime into: $FixedRtRoot"
  Copy-Item -Path (Join-Path $extract '*') -Destination $FixedRtRoot -Recurse -Force

  try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
  try { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue } catch {}

  $exeFolder = Get-FixedRuntimeExeFolder
  if ($exeFolder) {
    Write-Log "Fixed runtime installed to: $exeFolder"
    return $true
  }
  Write-Log "Fixed runtime install failed: msedgewebview2.exe not found"
  return $false
}

# ----- UI -----
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CHATGPTPROGRAM Cockpit" Height="900" Width="1400"
        WindowStartupLocation="CenterScreen">
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="260"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#111827" CornerRadius="8" Padding="10" Margin="0,0,0,10">
      <DockPanel LastChildFill="True">
        <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
          <TextBlock Text="ChatGPT URL:" Foreground="White" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBox x:Name="UrlTextBox" Width="760" Margin="0,0,8,0"/>
          <Button x:Name="GoButton" Content="Go" Padding="10,4" Margin="0,0,6,0"/>
          <Button x:Name="BackButton" Content="Back" Padding="10,4" Margin="0,0,6,0"/>
          <Button x:Name="ForwardButton" Content="Forward" Padding="10,4" Margin="0,0,6,0"/>
          <Button x:Name="ReloadButton" Content="Reload" Padding="10,4" Margin="0,0,6,0"/>
          <Button x:Name="OpenExternalButton" Content="Open External" Padding="10,4" Margin="0,0,6,0"/>
          <Button x:Name="CopyUrlButton" Content="Copy URL" Padding="10,4"/>
        </StackPanel>
        <TextBlock x:Name="TopStatusText" Foreground="#93C5FD" HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>

    <Grid Grid.Row="1" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="320"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="White" BorderBrush="#E5E7EB" BorderThickness="1" CornerRadius="8" Padding="6">
        <Grid>
          <Grid x:Name="WebViewHost" Background="White"/>
          <Border x:Name="WebFallback" Background="#FFF7ED" CornerRadius="6" Padding="12" Visibility="Collapsed">
            <StackPanel>
              <TextBlock Text="Embedded ChatGPT unavailable." FontWeight="Bold" Foreground="#9A3412" Margin="0,0,0,6"/>
              <TextBlock Text="Click 'Download Embedded Browser' (no admin) then try again." Foreground="#9A3412" Margin="0,0,0,6"/>
              <TextBlock Text="You can still use 'Open External' + clipboard runner meanwhile." Foreground="#9A3412"/>
            </StackPanel>
          </Border>
        </Grid>
      </Border>

      <Border Grid.Column="1" Background="#F3F4F6" CornerRadius="8" Padding="10" Margin="10,0,0,0">
        <ScrollViewer x:Name="ToolsScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel>
          <TextBlock Text="Tools" FontWeight="Bold" Margin="0,0,0,8"/>

          <Button x:Name="DownloadWebViewButton" Content="Download Embedded Browser" Padding="10,6" Margin="0,0,0,6"/>
          <ProgressBar x:Name="DownloadProgress" Height="10" IsIndeterminate="True" Visibility="Collapsed" Margin="0,0,0,10"/>

          <CheckBox x:Name="ArmCheckBox" Content="ARM (auto-run on marker)" Margin="0,0,0,6"/>
          <CheckBox x:Name="RequireFenceCheckBox" Content="Require fenced powershell" Margin="0,0,0,6"/>
          <CheckBox x:Name="AutoCopyCheckBox" Content="Auto-copy output" Margin="0,0,0,6"/>
          <CheckBox x:Name="NonInteractiveCheckBox" Content="Use -NonInteractive" Margin="0,0,0,10"/>

          <TextBlock Text="Marker" Margin="0,0,0,2"/>
          <TextBox x:Name="MarkerTextBox" Margin="0,0,0,10"/>

          <TextBlock Text="Timeout (s)" Margin="0,0,0,2"/>
          <TextBox x:Name="TimeoutTextBox" Margin="0,0,0,10"/>

          <TextBlock Text="Working Dir" Margin="0,0,0,2"/>
          <TextBox x:Name="WorkingDirTextBox" Margin="0,0,0,6"/>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="BrowseDirButton" Content="Browse" Padding="10,4" Margin="0,0,6,0"/>
            <Button x:Name="OpenDirButton" Content="Open" Padding="10,4"/>
          </StackPanel>

          <Separator Margin="0,8,0,8"/>

          <Button x:Name="RunNowButton" Content="Run Now (fenced block)" Padding="10,6" Margin="0,0,0,6"/>
          <Button x:Name="CopyOutputButton" Content="Copy Output" Padding="10,6" Margin="0,0,0,6"/>
          <Button x:Name="CopyChatReplyButton" Content="Copy Output as Chat Reply" Padding="10,6" Margin="0,0,0,6"/>
          <Button x:Name="ClearButton" Content="Clear Script/Output" Padding="10,6" Margin="0,0,0,6"/>
          <Button x:Name="OpenLogButton" Content="Open Log" Padding="10,6"/>

          <TextBlock x:Name="RightStatusText" Foreground="#374151" TextWrapping="Wrap" Margin="0,10,0,0"/>
        </StackPanel></ScrollViewer>
      </Border>
    </Grid>

    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <GroupBox Header="Extracted PowerShell Script (from clipboard)" Grid.Column="0" Margin="0,0,6,0">
        <TextBox x:Name="ScriptTextBox" FontFamily="Consolas" FontSize="12" AcceptsReturn="True"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
      </GroupBox>

      <GroupBox Header="Output (auto-copied)" Grid.Column="1" Margin="6,0,0,0">
        <TextBox x:Name="OutputTextBox" FontFamily="Consolas" FontSize="12" AcceptsReturn="True" IsReadOnly="True"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
      </GroupBox>
    </Grid>
  </Grid>
</Window>
"@

$xml = New-Object System.Xml.XmlDocument
$xml.LoadXml($xaml)
$reader = New-Object System.Xml.XmlNodeReader $xml
$Window = [Windows.Markup.XamlReader]::Load($reader)
$Find = { param($n) $Window.FindName($n) }

# Controls
$UrlTextBox = & $Find 'UrlTextBox'
$GoButton = & $Find 'GoButton'
$BackButton = & $Find 'BackButton'
$ForwardButton = & $Find 'ForwardButton'
$ReloadButton = & $Find 'ReloadButton'
$OpenExternalButton = & $Find 'OpenExternalButton'
$CopyUrlButton = & $Find 'CopyUrlButton'
$TopStatusText = & $Find 'TopStatusText'

$WebViewHost = & $Find 'WebViewHost'
$WebFallback = & $Find 'WebFallback'

$DownloadWebViewButton = & $Find 'DownloadWebViewButton'
$DownloadProgress = & $Find 'DownloadProgress'

$ArmCheckBox = & $Find 'ArmCheckBox'
$RequireFenceCheckBox = & $Find 'RequireFenceCheckBox'
$AutoCopyCheckBox = & $Find 'AutoCopyCheckBox'
$NonInteractiveCheckBox = & $Find 'NonInteractiveCheckBox'
$MarkerTextBox = & $Find 'MarkerTextBox'
$TimeoutTextBox = & $Find 'TimeoutTextBox'
$WorkingDirTextBox = & $Find 'WorkingDirTextBox'
$BrowseDirButton = & $Find 'BrowseDirButton'
$OpenDirButton = & $Find 'OpenDirButton'

$RunNowButton = & $Find 'RunNowButton'
$CopyOutputButton = & $Find 'CopyOutputButton'
$CopyChatReplyButton = & $Find 'CopyChatReplyButton'
$ClearButton = & $Find 'ClearButton'
$OpenLogButton = & $Find 'OpenLogButton'
$RightStatusText = & $Find 'RightStatusText'

$ScriptTextBox = & $Find 'ScriptTextBox'
$OutputTextBox = & $Find 'OutputTextBox'

# WebView2 state
$script:WebView = $null

# Clipboard state
$script:LastClipboardSeen = ''
$script:LastProcessed = ''
$script:SuppressClipboardText = $null

function Apply-SettingsToUI {
  $UrlTextBox.Text = $Settings.chatUrl
  $WorkingDirTextBox.Text = $Settings.workingDir
  $ArmCheckBox.IsChecked = [bool]$Settings.arm
  $RequireFenceCheckBox.IsChecked = [bool]$Settings.requireFence
  $AutoCopyCheckBox.IsChecked = [bool]$Settings.autoCopy
  $NonInteractiveCheckBox.IsChecked = [bool]$Settings.nonInteractive
  $MarkerTextBox.Text = $Settings.marker
  $TimeoutTextBox.Text = [string]$Settings.timeoutSeconds
  $TopStatusText.Text = ("WD: {0}" -f $Settings.workingDir)
  $RightStatusText.Text = ("Waiting for marker: {0}" -f $Settings.marker)
}

function Pull-UIToSettings {
  $Settings.chatUrl = (Nz $UrlTextBox.Text $Settings.chatUrl).Trim()
  $wd = (Nz $WorkingDirTextBox.Text $Settings.workingDir).Trim()
  if ($wd -and (Test-Path -LiteralPath $wd)) { $Settings.workingDir = $wd }

  $Settings.arm = [bool]$ArmCheckBox.IsChecked
  $Settings.requireFence = [bool]$RequireFenceCheckBox.IsChecked
  $Settings.autoCopy = [bool]$AutoCopyCheckBox.IsChecked
  $Settings.nonInteractive = [bool]$NonInteractiveCheckBox.IsChecked

  $m = (Nz $MarkerTextBox.Text $Settings.marker).Trim()
  if ($m) { $Settings.marker = $m }

  $t = 0
  if ([int]::TryParse((Nz $TimeoutTextBox.Text '300').Trim(), [ref]$t) -and $t -gt 0) { $Settings.timeoutSeconds = $t }

  Save-Settings $Settings
  $TopStatusText.Text = ("WD: {0}" -f $Settings.workingDir)
}

function Set-RightStatus([string]$msg) { $RightStatusText.Text = $msg }

function Try-InitWebView2 {
  $WebViewHost.Children.Clear()
  $script:WebView = $null

  $core = Join-Path $DepsLib 'Microsoft.Web.WebView2.Core.dll'
  $wpf  = Join-Path $DepsLib 'Microsoft.Web.WebView2.Wpf.dll'

  if (-not (Test-Path -LiteralPath $core) -or -not (Test-Path -LiteralPath $wpf)) {
    $WebFallback.Visibility = 'Visible'
    Set-RightStatus "Missing WebView2 DLLs under deps\WebView2\lib"
    return
  }

  try { Add-Type -Path $core | Out-Null; Add-Type -Path $wpf | Out-Null }
  catch {
    Write-Log ("WebView2 DLL load failed: " + $_.Exception.Message)
    $WebFallback.Visibility = 'Visible'
    Set-RightStatus "Failed to load WebView2 DLLs."
    return
  }

  try {
    $wv = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $wv.HorizontalAlignment = 'Stretch'
    $wv.VerticalAlignment   = 'Stretch'
    [void]$WebViewHost.Children.Add($wv)
    $script:WebView = $wv

    $wv.add_NavigationCompleted({
      try {
        if ($script:WebView -and $script:WebView.Source) {
          $UrlTextBox.Text = $script:WebView.Source.AbsoluteUri
          Pull-UIToSettings
        }
      } catch { }
    })

    $fixedExeFolder = Get-FixedRuntimeExeFolder
    if ($fixedExeFolder) {
      Set-RightStatus ("Using fixed runtime: " + $fixedExeFolder)
      $envTask = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($fixedExeFolder, $WebViewUserData, $null)
      $env = $envTask.GetAwaiter().GetResult()
      $null = $wv.EnsureCoreWebView2Async($env).GetAwaiter().GetResult()
      $WebFallback.Visibility = 'Collapsed'
    } else {
      $null = $wv.EnsureCoreWebView2Async().GetAwaiter().GetResult()
      $WebFallback.Visibility = 'Collapsed'
      Set-RightStatus "Using installed runtime."
    }

    $startUrl = (Nz $Settings.chatUrl 'https://chatgpt.com/').Trim()
    if (-not $startUrl) { $startUrl = 'https://chatgpt.com/' }
    $wv.Source = [Uri]$startUrl
  } catch {
    Write-Log ("WebView2 init failed: " + $_.Exception.Message)
    $WebFallback.Visibility = 'Visible'
    Set-RightStatus "Embedded browser unavailable. Click 'Download Embedded Browser'."
    try { $WebViewHost.Children.Clear() } catch {}
    $script:WebView = $null
  }
}

function Run-ScriptAndShow([string]$scriptText) {
  Pull-UIToSettings
  $wd = $Settings.workingDir
  if (-not (Test-Path -LiteralPath $wd)) { $wd = $Root }

  $r = Invoke-PowerShellScriptFile -scriptText $scriptText -workingDir $wd -timeoutSeconds ([int]$Settings.timeoutSeconds) -nonInteractive ([bool]$Settings.nonInteractive)
  $out = Format-RunResult $r
  $OutputTextBox.Text = $out

  if ($Settings.autoCopy) {
    $script:SuppressClipboardText = $out
    [void](Set-ClipboardTextSafe $out)
    Set-RightStatus ("Ran & copied output @ " + (Get-Date -Format 'HH:mm:ss'))
  } else {
    Set-RightStatus ("Ran @ " + (Get-Date -Format 'HH:mm:ss'))
  }
}

function Extract-ScriptFromClipboardText([string]$txt, [bool]$requireMarker) {
  if (-not $txt) { return @{ ok=$false; reason='Empty clipboard'; script=$null } }
  if (LooksLikeDiffOrPatch $txt) { return @{ ok=$false; reason='Looks like diff/patch; blocked.'; script=$null } }

  $markerIndex = Get-MarkerIndex -text $txt -marker $Settings.marker
  if ($requireMarker -and $markerIndex -lt 0) { return @{ ok=$false; reason=('Waiting for marker: ' + $Settings.marker); script=$null } }

  if ($Settings.requireFence) {
    $scriptText = Extract-LastFencedPowerShellBeforeMarker -text $txt -markerIndex $markerIndex
    if (-not $scriptText) { return @{ ok=$false; reason='No fenced powershell block found before marker.'; script=$null } }
    return @{ ok=$true; reason=''; script=$scriptText }
  } else {
    if ($markerIndex -ge 0) { return @{ ok=$true; reason=''; script=$txt.Substring(0,$markerIndex).Trim() } }
    return @{ ok=$true; reason=''; script=$txt }
  }
}

# ----- Events -----
$Window.add_Loaded({ Apply-SettingsToUI; Try-InitWebView2 })

$OpenExternalButton.add_Click({ Pull-UIToSettings; Start-Process (Nz $Settings.chatUrl 'https://chatgpt.com/') })
$CopyUrlButton.add_Click({ Pull-UIToSettings; $script:SuppressClipboardText = $Settings.chatUrl; [void](Set-ClipboardTextSafe $Settings.chatUrl); Set-RightStatus "URL copied." })

$GoButton.add_Click({
  Pull-UIToSettings
  $u = (Nz $Settings.chatUrl 'https://chatgpt.com/').Trim()
  if (-not $u) { return }
  try { if ($script:WebView) { $script:WebView.Source = [Uri]$u } else { Start-Process $u } }
  catch { Start-Process $u }
})
$BackButton.add_Click({ try { if ($script:WebView -and $script:WebView.CanGoBack) { $script:WebView.GoBack() } } catch { } })
$ForwardButton.add_Click({ try { if ($script:WebView -and $script:WebView.CanGoForward) { $script:WebView.GoForward() } } catch { } })
$ReloadButton.add_Click({ try { if ($script:WebView) { $script:WebView.Reload() } } catch { } })

$BrowseDirButton.add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = "Select working directory"
  if (Test-Path -LiteralPath $Settings.workingDir) { $dlg.SelectedPath = $Settings.workingDir } else { $dlg.SelectedPath = $Root }
  $r = $dlg.ShowDialog()
  if ($r -eq [System.Windows.Forms.DialogResult]::OK -and $dlg.SelectedPath) {
    $WorkingDirTextBox.Text = $dlg.SelectedPath
    Pull-UIToSettings
    Set-RightStatus "Working dir updated."
  }
})
$OpenDirButton.add_Click({ Pull-UIToSettings; if (Test-Path -LiteralPath $Settings.workingDir) { Start-Process explorer.exe $Settings.workingDir } })

# IMPORTANT: download runs on background thread (UI won't "do nothing")
$DownloadWebViewButton.add_Click({
  Pull-UIToSettings
  $DownloadWebViewButton.IsEnabled = $false
  $DownloadProgress.Visibility = 'Visible'
  Set-RightStatus "Downloading embedded browser (fixed runtime)..."
  $Window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

  $bw = New-Object System.ComponentModel.BackgroundWorker
  $bw.WorkerReportsProgress = $false
  $bw.WorkerSupportsCancellation = $false

  $bw.add_DoWork({
    try {
      $ok = Ensure-FixedRuntimeDownloaded
      $_.Result = $ok
    } catch {
      $_.Result = $_.Exception
    }
  })

  $bw.add_RunWorkerCompleted({
    $DownloadProgress.Visibility = 'Collapsed'
    $DownloadWebViewButton.IsEnabled = $true

    if ($_.Result -is [System.Exception]) {
      $ex = $_.Result
      Write-Log ("Download fixed runtime failed: " + $ex.Message)
      Set-RightStatus ("Download failed: " + $ex.Message)
      return
    }

    if ($_.Result -eq $true) {
      Set-RightStatus "Download complete. Initializing embedded browser..."
      $Window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
      Try-InitWebView2
    } else {
      Set-RightStatus "Download failed (runtime not found after extract). Open Log."
    }
  })

  $bw.RunWorkerAsync()
})

$RunNowButton.add_Click({
  Pull-UIToSettings
  $txt = Get-ClipboardTextSafe
  $res = Extract-ScriptFromClipboardText -txt $txt -requireMarker:$false
  if (-not $res.ok) { Set-RightStatus ("Not run: " + $res.reason); return }
  $ScriptTextBox.Text = $res.script
  $choice = [System.Windows.MessageBox]::Show("Run extracted PowerShell now?", "Confirm Run", 'YesNo', 'Warning')
  if ($choice -ne 'Yes') { Set-RightStatus "Canceled."; return }
  Run-ScriptAndShow $res.script
})

$CopyOutputButton.add_Click({
  $o = Nz $OutputTextBox.Text ''
  $script:SuppressClipboardText = $o
  [void](Set-ClipboardTextSafe $o)
  Set-RightStatus "Output copied."
})

$CopyChatReplyButton.add_Click({
  $o = Nz $OutputTextBox.Text ''
  $wrap = '```text' + "`r`n" + $o + "`r`n" + '```'
  $script:SuppressClipboardText = $wrap
  [void](Set-ClipboardTextSafe $wrap)
  Set-RightStatus "Output-as-reply copied."
})

$ClearButton.add_Click({
  $ScriptTextBox.Clear()
  $OutputTextBox.Clear()
  Set-RightStatus ("Waiting for marker: " + $Settings.marker)
})

$OpenLogButton.add_Click({ Start-Process notepad.exe (Join-Path $LogsDir 'cockpit.log') })

foreach ($ctrl in @($UrlTextBox,$WorkingDirTextBox,$MarkerTextBox,$TimeoutTextBox,$ArmCheckBox,$RequireFenceCheckBox,$AutoCopyCheckBox,$NonInteractiveCheckBox)) {
  try { $ctrl.add_LostFocus({ Pull-UIToSettings }) } catch { }
  try { $ctrl.add_Click({ Pull-UIToSettings }) } catch { }
}

# ----- Clipboard polling (marker-driven) -----
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.add_Tick({
  try {
    Pull-UIToSettings
    $txt = Get-ClipboardTextSafe
    if ($null -eq $txt) { $txt = '' }

    if ($script:SuppressClipboardText -ne $null -and $txt -eq $script:SuppressClipboardText) {
      $script:SuppressClipboardText = $null
      return
    }

    if ($txt -ne $script:LastClipboardSeen) {
      $script:LastClipboardSeen = $txt

      if ($Settings.arm -and (Contains-MarkerLine -text $txt -marker $Settings.marker)) {
        if ($txt -ne $script:LastProcessed) {
          $script:LastProcessed = $txt
          $res = Extract-ScriptFromClipboardText -txt $txt -requireMarker:$true
          if ($res.ok) {
            $ScriptTextBox.Text = $res.script
            Run-ScriptAndShow $res.script
          } else {
            Set-RightStatus ("Not run: " + $res.reason)
          }
        }
      }
    }
  } catch {
    Write-Log ("Timer error: " + $_.Exception.Message)
  }
})
$timer.Start()

[void]$Window.ShowDialog()

