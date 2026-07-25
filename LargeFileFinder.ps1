#Requires -Version 5.1
<#
.SYNOPSIS
    Finds the largest files on your PC.

.DESCRIPTION
    Runs as a WinForms GUI by default. Use -Console for a terminal-only scan.

.EXAMPLE
    .\LargeFileFinder.ps1
    Opens the GUI.

.EXAMPLE
    .\LargeFileFinder.ps1 -Console -Path C:\Users\RAY -MinMB 250 -Top 50
    Lists the 50 biggest files over 250 MB under the given path.

.EXAMPLE
    .\LargeFileFinder.ps1 -Console -Path C:\ -MinMB 500 -Csv big.csv
    Writes the results to a CSV instead of the screen.
#>
[CmdletBinding()]
param(
    [switch]$Console,
    [string]$Path,
    [double]$MinMB = 100,
    [int]$Top = 200,
    [string]$Csv,
    [switch]$IncludeWindows,
    [switch]$HideConsole
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers ----

function Format-Size {
    param([double]$Bytes)
    $units = 'B', 'KB', 'MB', 'GB', 'TB', 'PB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) {
        $Bytes /= 1024
        $i++
    }
    if ($i -eq 0) { '{0} B' -f [int]$Bytes } else { '{0:N1} {1}' -f $Bytes, $units[$i] }
}

# Directory names that are noise, unreadable, or dangerous to recurse into.
function Get-SkipList {
    param([switch]$IncludeWindows)
    $skip = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        $root = $drive.RootDirectory.FullName
        [void]$skip.Add((Join-Path $root '$Recycle.Bin'))
        [void]$skip.Add((Join-Path $root 'System Volume Information'))
        [void]$skip.Add((Join-Path $root 'Recovery'))
    }
    if (-not $IncludeWindows) {
        [void]$skip.Add($env:SystemRoot)
    }
    return $skip
}

<#
    Iterative walk so a deep tree cannot blow the stack, and so one unreadable
    folder (permissions, long path, offline OneDrive stub) never aborts the scan.
    Reparse points are skipped to avoid junction/symlink loops and double counts.
#>
function Invoke-FileScan {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][long]$MinBytes,
        [System.Collections.Generic.HashSet[string]]$Skip,
        [scriptblock]$OnProgress,      # called as { param($dir, $seen, $hits) }
        [scriptblock]$ShouldCancel     # returns $true to stop early
    )

    $hits = [System.Collections.Generic.List[object]]::new()
    $seen = 0L
    $seenBytes = 0L
    $errors = 0
    $tick = 0

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        if ($ShouldCancel -and (& $ShouldCancel)) { break }

        $dir = $stack.Pop()
        if ($Skip -and $Skip.Contains($dir.TrimEnd('\'))) { continue }

        try {
            $di = [System.IO.DirectoryInfo]::new($dir)

            foreach ($f in $di.EnumerateFiles()) {
                $seen++
                $seenBytes += $f.Length
                if ($f.Length -ge $MinBytes) { $hits.Add($f) }

                if ((++$tick % 512) -eq 0 -and $OnProgress) {
                    & $OnProgress $dir $seen $hits.Count
                    if ($ShouldCancel -and (& $ShouldCancel)) { break }
                }
            }

            foreach ($sub in $di.EnumerateDirectories()) {
                if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($sub.FullName)
            }
        }
        catch {
            $errors++   # unreadable folder: skip it and keep going
        }
    }

    if ($OnProgress) { & $OnProgress $Root $seen $hits.Count }

    [pscustomobject]@{
        Files     = $hits
        FilesSeen = $seen
        BytesSeen = $seenBytes
        DirErrors = $errors
        Cancelled = [bool]($ShouldCancel -and (& $ShouldCancel))
    }
}

# ---------------------------------------------------------- console mode ----

function Start-ConsoleScan {
    param([string]$Root, [double]$MinMB, [int]$Top, [string]$Csv, [switch]$IncludeWindows)

    if (-not $Root) { $Root = (Get-Location).Path }
    $Root = (Resolve-Path -LiteralPath $Root).Path
    $minBytes = [long]($MinMB * 1MB)

    Write-Host "Scanning $Root for files >= $(Format-Size $minBytes) ..." -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $progress = {
        param($dir, $seen, $found)
        Write-Progress -Activity 'Scanning' -Status "$seen files scanned, $found large" -CurrentOperation $dir
    }

    $result = Invoke-FileScan -Root $Root -MinBytes $minBytes `
        -Skip (Get-SkipList -IncludeWindows:$IncludeWindows) -OnProgress $progress
    $sw.Stop()
    Write-Progress -Activity 'Scanning' -Completed

    $rows = $result.Files |
        Sort-Object Length -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            [pscustomobject]@{
                Size     = Format-Size $_.Length
                Bytes    = $_.Length
                Name     = $_.Name
                Modified = $_.LastWriteTime
                Folder   = $_.DirectoryName
            }
        }

    if ($Csv) {
        $rows | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
        Write-Host "Wrote $($rows.Count) rows to $Csv" -ForegroundColor Green
    }
    else {
        $rows | Format-Table Size, Name, Modified, Folder -AutoSize
    }

    $total = ($result.Files | Measure-Object Length -Sum).Sum
    Write-Host ("{0} files >= {1} using {2} | {3} files scanned ({4}) | {5} folders skipped | {6:N1}s" -f `
        $result.Files.Count, (Format-Size $minBytes), (Format-Size $total), `
        $result.FilesSeen, (Format-Size $result.BytesSeen), $result.DirErrors, $sw.Elapsed.TotalSeconds) `
        -ForegroundColor Cyan
}

# -------------------------------------------------------------- gui mode ----

<#
    Hides this process's console window. Only called via -HideConsole (the .cmd
    launcher), never when the script is run from a terminal the user is using.
    Note: launching with -WindowStyle Hidden instead would also hide the form.
#>
function Hide-ConsoleWindow {
    Add-Type -Name ConsoleWin -Namespace LFF -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    $h = [LFF.ConsoleWin]::GetConsoleWindow()
    if ($h -ne [IntPtr]::Zero) { [void][LFF.ConsoleWin]::ShowWindow($h, 0) }  # SW_HIDE
}

<#
    Every control and helper below is $script:-scoped on purpose. WinForms event
    handlers do not run inside this function's scope, so a plain local like
    $status is invisible to them and "$status.Text = ..." throws at click time.
#>
function Start-Gui {
    param([string]$Root, [double]$MinMB, [int]$Top)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName Microsoft.VisualBasic
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:Results  = @()
    $script:Scanning = $false
    $script:Cancel   = $false
    $script:SortCol  = 1
    $script:SortAsc  = $false

    $script:Form = New-Object System.Windows.Forms.Form -Property @{
        Text          = 'Large File Finder'
        Size          = New-Object System.Drawing.Size(1020, 640)
        MinimumSize   = New-Object System.Drawing.Size(760, 420)
        StartPosition = 'CenterScreen'
        Font          = New-Object System.Drawing.Font('Segoe UI', 9)
    }

    # --- top bar -------------------------------------------------------------
    $lblPath = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Folder'; Location = '12,17'; AutoSize = $true
    }
    $script:TxtPath = New-Object System.Windows.Forms.TextBox -Property @{
        Text = $Root; Location = '60,14'; Width = 560; Anchor = 'Top,Left,Right'
    }
    $script:BtnBrowse = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Browse...'; Location = '628,13'; Width = 80; Anchor = 'Top,Right'
    }
    $script:BtnScan = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Scan'; Location = '714,13'; Width = 90; Anchor = 'Top,Right'
    }

    $lblMin = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Larger than'; Location = '12,52'; AutoSize = $true
    }
    # Value is assigned after Maximum on purpose: -Property applies keys in an
    # arbitrary order, and setting Value first throws once it exceeds the default max.
    $script:NumMin = New-Object System.Windows.Forms.NumericUpDown -Property @{
        Location = '88,49'; Width = 70; Minimum = 1; Maximum = 1024000; Increment = 50
    }
    $script:NumMin.Value = [Math]::Max(1, [Math]::Min(1024000, [decimal]$MinMB))
    $lblMinUnit = New-Object System.Windows.Forms.Label -Property @{
        Text = 'MB'; Location = '163,52'; AutoSize = $true
    }
    $lblTop = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Show top'; Location = '205,52'; AutoSize = $true
    }
    $script:NumTop = New-Object System.Windows.Forms.NumericUpDown -Property @{
        Location = '265,49'; Width = 70; Minimum = 10; Maximum = 100000; Increment = 50
    }
    $script:NumTop.Value = [Math]::Max(10, [Math]::Min(100000, [decimal]$Top))
    $script:ChkWin = New-Object System.Windows.Forms.CheckBox -Property @{
        Text = 'Include Windows folder'; Location = '350,50'; AutoSize = $true; Checked = $false
    }
    $script:BtnExport = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Export CSV'; Location = '714,48'; Width = 90; Anchor = 'Top,Right'; Enabled = $false
    }

    # --- results -------------------------------------------------------------
    $script:List = New-Object System.Windows.Forms.ListView -Property @{
        Location      = '12,82'
        Size          = New-Object System.Drawing.Size(980, 470)
        Anchor        = 'Top,Left,Right,Bottom'
        View          = 'Details'
        FullRowSelect = $true
        GridLines     = $true
        MultiSelect   = $true
        HideSelection = $false
    }
    [void]$script:List.Columns.Add('Name', 300)
    [void]$script:List.Columns.Add('Size', 90, 'Right')
    [void]$script:List.Columns.Add('Type', 70)
    [void]$script:List.Columns.Add('Modified', 130)
    [void]$script:List.Columns.Add('Folder', 360)

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen   = $menu.Items.Add('Open containing folder')
    $miCopy   = $menu.Items.Add('Copy full path')
    [void]$menu.Items.Add('-')
    $miDelete = $menu.Items.Add('Delete (send to Recycle Bin)')
    $script:List.ContextMenuStrip = $menu

    # --- status --------------------------------------------------------------
    $script:Status = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Pick a folder and press Scan.'
        Location = '12,562'; Width = 980; Height = 34
        Anchor = 'Left,Right,Bottom'
    }

    $script:Form.Controls.AddRange(@(
        $lblPath, $script:TxtPath, $script:BtnBrowse, $script:BtnScan,
        $lblMin, $script:NumMin, $lblMinUnit, $lblTop, $script:NumTop,
        $script:ChkWin, $script:BtnExport, $script:List, $script:Status
    ))
    $script:Form.AcceptButton = $script:BtnScan

    # --- rendering -----------------------------------------------------------
    $script:Render = {
        $key = switch ($script:SortCol) {
            0 { 'Name' } 1 { 'Length' } 2 { 'Extension' } 3 { 'LastWriteTime' } default { 'DirectoryName' }
        }
        $rows = @($script:Results | Sort-Object -Property $key -Descending:(-not $script:SortAsc) |
            Select-Object -First ([int]$script:NumTop.Value))

        $script:List.BeginUpdate()
        $script:List.Items.Clear()
        foreach ($f in $rows) {
            $item = New-Object System.Windows.Forms.ListViewItem $f.Name
            [void]$item.SubItems.Add((Format-Size $f.Length))
            [void]$item.SubItems.Add($(if ($f.Extension) { $f.Extension.TrimStart('.').ToLower() } else { '' }))
            [void]$item.SubItems.Add($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
            [void]$item.SubItems.Add($f.DirectoryName)
            $item.Tag = $f.FullName
            [void]$script:List.Items.Add($item)
        }
        $script:List.EndUpdate()
        $script:BtnExport.Enabled = $script:Results.Count -gt 0
    }

    # --- scanning ------------------------------------------------------------
    $script:SetScanning = {
        param([bool]$On)
        $script:Scanning = $On
        $script:BtnScan.Text = $(if ($On) { 'Cancel' } else { 'Scan' })
        foreach ($c in @($script:TxtPath, $script:BtnBrowse, $script:NumMin, $script:ChkWin)) {
            $c.Enabled = -not $On
        }
    }

    # Reports progress and keeps the window responsive mid-scan.
    $script:OnProgress = {
        param($dir, $seen, $found)
        $script:Status.Text = "Scanning... $('{0:N0}' -f $seen) files checked, $found large so far`r`n$dir"
        [System.Windows.Forms.Application]::DoEvents()
    }

    $script:BtnScan.Add_Click({
        # A throw inside a handler kills the process, so every handler is guarded.
        try {
            if ($script:Scanning) { $script:Cancel = $true; return }

            $root = $script:TxtPath.Text.Trim()
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                [void][System.Windows.Forms.MessageBox]::Show("Not a folder:`n$root",
                    'Large File Finder', 'OK', 'Warning')
                return
            }

            $script:Cancel = $false
            & $script:SetScanning $true
            $script:List.Items.Clear()
            $script:Results = @()
            $minBytes = [long]([double]$script:NumMin.Value * 1MB)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            try {
                $result = Invoke-FileScan -Root $root -MinBytes $minBytes `
                    -Skip (Get-SkipList -IncludeWindows:$script:ChkWin.Checked) `
                    -OnProgress $script:OnProgress -ShouldCancel { $script:Cancel }
            }
            finally {
                $sw.Stop()
                & $script:SetScanning $false
            }

            $script:Results = @($result.Files)
            $script:SortCol = 1
            $script:SortAsc = $false
            & $script:Render

            $total = ($script:Results | Measure-Object Length -Sum).Sum
            $script:Status.Text = ("{0}{1:N0} files over {2} using {3}  |  {4:N0} files scanned ({5})  |  " +
                                   "{6} folders unreadable  |  {7:N1}s") -f `
                $(if ($result.Cancelled) { 'Cancelled - ' } else { '' }),
                $script:Results.Count, (Format-Size $minBytes), (Format-Size $total),
                $result.FilesSeen, (Format-Size $result.BytesSeen), $result.DirErrors, $sw.Elapsed.TotalSeconds
        }
        catch {
            & $script:SetScanning $false
            $script:Status.Text = "Scan failed: $($_.Exception.Message)"
            [void][System.Windows.Forms.MessageBox]::Show(
                "$($_.Exception.Message)", 'Large File Finder', 'OK', 'Error')
        }
    })

    $script:BtnBrowse.Add_Click({
        try {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Choose a folder or drive to scan'
            $dlg.SelectedPath = $script:TxtPath.Text
            if ($dlg.ShowDialog() -eq 'OK') { $script:TxtPath.Text = $dlg.SelectedPath }
        }
        catch { $script:Status.Text = "Browse failed: $($_.Exception.Message)" }
    })

    $script:List.Add_ColumnClick({
        param($sender, $e)
        try {
            if ($script:SortCol -eq $e.Column) { $script:SortAsc = -not $script:SortAsc }
            else { $script:SortCol = $e.Column; $script:SortAsc = ($e.Column -ne 1) }
            & $script:Render
        }
        catch { $script:Status.Text = "Sort failed: $($_.Exception.Message)" }
    })

    $openSelected = {
        try {
            foreach ($item in $script:List.SelectedItems) {
                if (Test-Path -LiteralPath $item.Tag) {
                    Start-Process explorer.exe "/select,`"$($item.Tag)`""
                }
            }
        }
        catch { $script:Status.Text = "Open failed: $($_.Exception.Message)" }
    }
    $script:List.Add_DoubleClick($openSelected)
    $miOpen.Add_Click($openSelected)

    $miCopy.Add_Click({
        try {
            $paths = @($script:List.SelectedItems | ForEach-Object { $_.Tag })
            if ($paths) {
                [System.Windows.Forms.Clipboard]::SetText(($paths -join "`r`n"))
                $script:Status.Text = "Copied $($paths.Count) path(s) to the clipboard."
            }
        }
        catch { $script:Status.Text = "Copy failed: $($_.Exception.Message)" }
    })

    $miDelete.Add_Click({
        try {
            $items = @($script:List.SelectedItems)
            if (-not $items) { return }
            $names = ($items | Select-Object -First 10 | ForEach-Object { $_.Text }) -join "`r`n"
            $more = if ($items.Count -gt 10) { "`r`n...and $($items.Count - 10) more" } else { '' }
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Send $($items.Count) file(s) to the Recycle Bin?`r`n`r`n$names$more",
                'Confirm delete', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }

            $failed = @()
            foreach ($item in $items) {
                try {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                        $item.Tag,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
                    $script:Results = @($script:Results | Where-Object { $_.FullName -ne $item.Tag })
                    $script:List.Items.Remove($item)
                }
                catch { $failed += $item.Text }
            }
            if ($failed) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    "Could not delete:`r`n$($failed -join "`r`n")", 'Large File Finder', 'OK', 'Error')
            }
        }
        catch { $script:Status.Text = "Delete failed: $($_.Exception.Message)" }
    })

    $script:BtnExport.Add_Click({
        try {
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'CSV file (*.csv)|*.csv'
            $dlg.FileName = 'large-files.csv'
            if ($dlg.ShowDialog() -ne 'OK') { return }
            $script:Results |
                Sort-Object Length -Descending |
                Select-Object @{n = 'Size'; e = { Format-Size $_.Length } },
                              @{n = 'Bytes'; e = { $_.Length } },
                              Name,
                              @{n = 'Modified'; e = { $_.LastWriteTime } },
                              @{n = 'Folder'; e = { $_.DirectoryName } } |
                Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
            $script:Status.Text = "Exported $($script:Results.Count) rows to $($dlg.FileName)"
        }
        catch { $script:Status.Text = "Export failed: $($_.Exception.Message)" }
    })

    $script:Form.Add_FormClosing({ $script:Cancel = $true })
    $script:Form.Add_Shown({ $script:Form.Activate() })

    [void]$script:Form.ShowDialog()
    $script:Form.Dispose()
}

# ------------------------------------------------------------------ main ----

if ($Console) {
    Start-ConsoleScan -Root $Path -MinMB $MinMB -Top $Top -Csv $Csv -IncludeWindows:$IncludeWindows
}
else {
    if (-not $Path) { $Path = $env:USERPROFILE }
    if ($HideConsole) { Hide-ConsoleWindow }
    Start-Gui -Root $Path -MinMB $MinMB -Top $Top
}
