<#
.SYNOPSIS
  Registers FastDoc as an "open with" candidate for every extension this app opens, per
  docs/studio/sprints/S3/d5-file-assoc-print-dnd.md §3 (Windows, non-packaged exe form).
  Writes ONLY to HKCU\Software\Classes — no admin rights needed, matches the doc's own
  "비패키지 exe" registry shape exactly (ProgId + OpenWithProgids + RegisteredApplications).

.DESCRIPTION
  This script does NOT set FastDoc as the default app for anything — Windows 8+ protects
  HKCU\...\FileExts\<ext>\UserChoice with a hash the app cannot write, so the OS's own "Default
  apps" settings screen is the only place a user can make that choice (the doc's exact words:
  "기본 앱은 프로그램이 못 정한다"). This script only makes FastDoc show up as a candidate.

.PARAMETER InstallDir
  Directory holding FastDoc.Avalonia.exe (a published win-x64 self-contained output).

.NOTES
  NOT EXECUTED by the packaging gate — per dispatch instructions, this only writes the script.
  A real Windows machine must run it to verify.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$InstallDir
)

$ErrorActionPreference = "Stop"

$ExePath = Join-Path $InstallDir "FastDoc.Avalonia.exe"
if (-not (Test-Path $ExePath)) {
  Write-Error "FastDoc.Avalonia.exe not found at $ExePath — is this a published win-x64 self-contained output?"
  exit 1
}

$ProgId = "FastDoc.Document"

# All 70 extensions this app opens (Sources/FastDocReader/App/DocumentTypes.swift —
# markdownExtensions + officeExtensions + hwpExtensions + plainTextExtensions). Every one of
# these gets an OpenWithProgids entry ("open with" candidate); NONE of them get their
# (Default) key touched here — that would silently steal the default from Word/HWP/whatever
# already owns it, which the doc explicitly warns against.
$AllExtensions = @(
  "md", "markdown",
  "docx", "docm", "dotx", "dotm", "odt", "hwp", "hwpx",
  "txt", "text", "csv", "tsv", "log", "crash", "ips",
  "conf", "cfg", "ini", "env", "vars", "toml", "cnf",
  "yaml", "yml", "json", "xml", "jsonl", "ndjson",
  "tf", "tfvars", "hcl", "sls", "properties", "lock",
  "graphql", "gql", "proto", "thrift", "avsc",
  "xsd", "wsdl", "dtd", "resx", "strings", "po",
  "har", "http", "rest", "sql", "diff", "patch",
  "mk", "gradle", "cmake", "bzl",
  "rst", "adoc", "asciidoc", "org", "tex", "textile", "nfo",
  "vtt", "srt", "smi", "ass", "ssa", "sub", "lrc"
)

Write-Host "==> 1/3: registering ProgId $ProgId -> $ExePath"
New-Item -Path "HKCU:\Software\Classes\$ProgId" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Classes\$ProgId" -Name "(Default)" -Value "FastDoc Document"
New-Item -Path "HKCU:\Software\Classes\$ProgId\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Classes\$ProgId\DefaultIcon" -Name "(Default)" -Value "`"$ExePath`",0"
New-Item -Path "HKCU:\Software\Classes\$ProgId\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Classes\$ProgId\shell\open\command" -Name "(Default)" -Value "`"$ExePath`" `"%1`""

Write-Host "==> 2/3: adding OpenWithProgids for $($AllExtensions.Count) extensions"
foreach ($ext in $AllExtensions) {
  $key = "HKCU:\Software\Classes\.$ext\OpenWithProgids"
  New-Item -Path $key -Force | Out-Null
  Set-ItemProperty -Path $key -Name $ProgId -Value ([byte[]]@()) -Type Binary
}

Write-Host "==> 3/3: registering under RegisteredApplications (Settings > Default apps visibility)"
New-Item -Path "HKCU:\Software\FastDoc\Capabilities\FileAssociations" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\FastDoc\Capabilities" -Name "ApplicationName" -Value "FastDoc"
foreach ($ext in $AllExtensions) {
  Set-ItemProperty -Path "HKCU:\Software\FastDoc\Capabilities\FileAssociations" -Name ".$ext" -Value $ProgId
}
New-Item -Path "HKCU:\Software\RegisteredApplications" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\RegisteredApplications" -Name "FastDoc" -Value "Software\FastDoc\Capabilities"

# Notify the shell so File Explorer picks up the new "open with" candidates without a restart.
Add-Type -Namespace Win32 -Name Shell -MemberDefinition @"
[DllImport("shell32.dll")]
public static extern void SHChangeNotify(long wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
"@
$SHCNE_ASSOCCHANGED = 0x08000000
$SHCNF_IDLIST = 0x0000
[Win32.Shell]::SHChangeNotify($SHCNE_ASSOCCHANGED, $SHCNF_IDLIST, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Host ""
Write-Host "Done. FastDoc is now an 'open with' candidate for $($AllExtensions.Count) extensions."
Write-Host "It is NOT the default for any of them — set that in Settings > Apps > Default apps,"
Write-Host "or right-click a file > Open with > Choose another app > Always use this app."
