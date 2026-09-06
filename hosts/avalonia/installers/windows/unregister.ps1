<#
.SYNOPSIS
  Reverses register.ps1 — removes the ProgId, all OpenWithProgids entries, and the
  RegisteredApplications listing from HKCU\Software\Classes. Never touches a per-extension
  (Default) key, because register.ps1 never wrote one either.

.NOTES
  NOT EXECUTED by the packaging gate — writes the script only. Run on a real Windows machine.
#>

$ErrorActionPreference = "Stop"

$ProgId = "FastDoc.Document"

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

Write-Host "==> 1/3: removing OpenWithProgids entries"
foreach ($ext in $AllExtensions) {
  $key = "HKCU:\Software\Classes\.$ext\OpenWithProgids"
  if (Test-Path $key) {
    Remove-ItemProperty -Path $key -Name $ProgId -ErrorAction SilentlyContinue
  }
}

Write-Host "==> 2/3: removing ProgId and Capabilities keys"
Remove-Item -Path "HKCU:\Software\Classes\$ProgId" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKCU:\Software\FastDoc" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "==> 3/3: removing RegisteredApplications entry"
Remove-ItemProperty -Path "HKCU:\Software\RegisteredApplications" -Name "FastDoc" -ErrorAction SilentlyContinue

Add-Type -Namespace Win32 -Name Shell -MemberDefinition @"
[DllImport("shell32.dll")]
public static extern void SHChangeNotify(long wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
"@
$SHCNE_ASSOCCHANGED = 0x08000000
$SHCNF_IDLIST = 0x0000
[Win32.Shell]::SHChangeNotify($SHCNE_ASSOCCHANGED, $SHCNF_IDLIST, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Host "Done. FastDoc removed from all 'open with' candidate lists."
Write-Host "If FastDoc was ever set as a DEFAULT app for something, Windows falls back to its"
Write-Host "previous default automatically (UserChoice keys are untouched by this script)."
