<#
.SYNOPSIS
Build a distributable Windows installer for Sun notes.

.DESCRIPTION
  packaging\make-installer.ps1 [-Release] [-Version X.Y.Z] [-OutDir DIR]
                               [-NoBuild] [-KeepTree]
                               [-SignToolPath PATH] [-SignArgs "..."]

-Release builds with dune's release profile instead of dev (no dev-only flags,
js_of_ocaml output optimised). Use it for anything you hand to someone else.

Produces dist\Sun-notes-<version>-<arch>-setup.exe, an Inno Setup installer.

This is a PowerShell script, not a bash one like its macOS and Linux siblings,
because it has to drive Windows tools (ISCC.exe, signtool.exe) and PowerShell
is on every Windows machine while bash is not.

Three things are different from every other platform:

  * Nothing resolves dependencies at install time. There is no apt or dnf, so
    any DLL the executable imports and Windows does not ship has to travel
    inside the installer. Here that means the mingw-w64 runtime, which
    owebview pulls in through -lstdc++: libstdc++-6.dll and friends. The
    script reads the import table, copies what it finds, and refuses to build
    if one is missing. (WebView2Loader.dll is not among them — owebview's
    vendored webview.h uses its built-in loader and finds the runtime through
    the registry itself.)

  * WebView2 is not guaranteed to be present. It ships with Windows 11 and
    reaches most Windows 10 machines through Edge, but "most" is not "all",
    and without it the app starts and shows nothing. The installer looks in
    the same registry locations the app will look in at startup and, if the
    runtime is missing, fetches Microsoft's Evergreen bootstrapper first.

  * The executable has no icon of its own. main.ml never calls set_app_icon,
    and on Windows that call would only set the *window* icon anyway — what
    Explorer and the Start menu show comes from an ICO resource inside the
    .exe. The script embeds one with rcedit when it is available, and always
    installs an .ico for the shortcuts to point at, so the shortcuts look
    right either way.

The layout needs no tricks here: Webview.Utils.web_dir looks for a "web"
directory next to the running binary, and on Windows that is simply where it
goes. No symlink, unlike the Linux packages.
#>

[CmdletBinding()]
param(
  [switch] $Release,
  [string] $Version = "",
  [string] $OutDir = "",
  [switch] $NoBuild,
  [switch] $KeepTree,
  [string] $SignToolPath = "",
  [string] $SignArgs = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- parameters

$AppName     = 'Sun notes'
$ExeName     = 'sun-notes.exe'
$Publisher   = 'Frédéric Lang'
$HomePage    = 'https://github.com/korkorran/Sun-notes'
$Synopsis    = 'A note-taking app written in OCaml'
# Inno identifies an installed application by this GUID, not by its name. It
# must never change: that is how an upgrade recognises the older version it is
# replacing instead of installing a second copy alongside it.
$AppGuid     = '{{8B9F1C2E-4D3A-4E67-9A15-7C0E2D6B5A41}'
$Copyright   = "© 2026 Frédéric Lang. MIT licence."
$IconSizes   = @(256, 128, 64, 48, 32, 16)

# DLLs Windows itself provides. Anything imported and not on this list has to
# be shipped. api-ms-win-* and ext-ms-* are the API-set stubs, always present.
$SystemDlls = @(
  'kernel32.dll','kernelbase.dll','user32.dll','gdi32.dll','gdiplus.dll',
  'advapi32.dll','shell32.dll','shlwapi.dll','ole32.dll','oleaut32.dll',
  'combase.dll','comctl32.dll','comdlg32.dll','version.dll','ws2_32.dll',
  'msvcrt.dll','ucrtbase.dll','ntdll.dll','rpcrt4.dll','secur32.dll',
  'crypt32.dll','bcrypt.dll','ncrypt.dll','imm32.dll','winmm.dll',
  'setupapi.dll','userenv.dll','iphlpapi.dll','dnsapi.dll','mswsock.dll',
  'normaliz.dll','psapi.dll','wldap32.dll','windowscodecs.dll','uxtheme.dll',
  'propsys.dll','shcore.dll','dwmapi.dll','dcomp.dll','d3d11.dll','dxgi.dll',
  'd2d1.dll','dwrite.dll','powrprof.dll','winhttp.dll','wininet.dll',
  'urlmon.dll','oleacc.dll','msimg32.dll','usp10.dll','opengl32.dll'
)

# ------------------------------------------------------------------ plumbing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Blue }
function Info($m) { Write-Host "    $m" }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

if (-not $OutDir) { $OutDir = Join-Path $RootDir 'dist' }

# Version: explicit flag, else the nearest git tag, else a placeholder.
if (-not $Version) {
  $Version = (& git -C $RootDir describe --tags --abbrev=0 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $Version) { $Version = '0.1.0' }
}
$Version = $Version -replace '^v', ''
if ($Version -notmatch '^[0-9]') { Die "version `"$Version`" does not start with a digit" }

# Inno's AppVersion is free-form, but VersionInfoVersion must be a dotted
# number of up to four parts, so a snapshot suffix has to be dropped from it.
$NumericVersion = ([regex]::Match($Version, '^[0-9]+(\.[0-9]+){0,3}')).Value
if (-not $NumericVersion) { $NumericVersion = '0.0.0' }

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("sun-notes-inst-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

try {

# ------------------------------------------------- step 1: check the toolchain

Step "Checking the environment"

if ($env:OS -ne 'Windows_NT') {
  Die "this script only runs on Windows (use make-dmg.sh on macOS, make-deb.sh / make-rpm.sh on Linux)"
}

# Inno Setup's compiler. It is not on PATH by default, so look where its
# installer puts it before giving up.
$Iscc = $null
foreach ($candidate in @(
    (Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe")) {
  if ($candidate -and (Test-Path $candidate)) { $Iscc = $candidate; break }
}
if (-not $Iscc) {
  Die ("ISCC.exe not found — install Inno Setup 6.3 or later (winget install JRSoftware.InnoSetup).`n" +
       "    6.1 introduced CreateDownloadPage, used to fetch the WebView2 bootstrapper; 6.3 introduced`n" +
       "    ArchitecturesAllowed=x64compatible, which lets the x64 build install on Windows on ARM.")
}

# The project's own opam switch first: the dune on PATH belongs to whatever
# switch happens to be active and may be older than the (lang dune ...) this
# project declares, in which case it refuses to build at all.
$Dune = $null
foreach ($candidate in @(
    $env:DUNE,
    (Join-Path $RootDir '_opam\bin\dune.exe'),
    (Get-Command 'dune' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1))) {
  if ($candidate -and (Test-Path $candidate)) { $Dune = $candidate; break }
}
if (-not $NoBuild -and -not $Dune) {
  Die "dune not found — install it, run 'opam switch create . --deps-only', or pass -NoBuild"
}

$SrcIcon = Join-Path $RootDir 'logo.png'
if (-not (Test-Path $SrcIcon)) { Die "no logo.png at the repository root — the icon is built from it" }
$License = Join-Path $RootDir 'LICENSE'
if (-not (Test-Path $License)) { Die "no LICENSE at the repository root — the installer shows it" }

$BuildProfile = if ($Release) { 'release' } else { 'dev' }

Info "Inno Setup     $Iscc"
if ($Dune) { Info "dune           $Dune" }
Info "profile        $BuildProfile"
Info "version        $Version (VersionInfo $NumericVersion)"
Info "output         $OutDir"
Info "work directory $WorkDir"

# ------------------------------------------------------- step 2: build the app

$BinSrc = Join-Path $RootDir '_build\default\run\main.exe'
$WebSrc = Join-Path $RootDir '_build\default\run\web'

if (-not $NoBuild) {
  Step "Building with dune (--profile $BuildProfile)"
  Push-Location $RootDir
  try {
    & $Dune build --profile $BuildProfile
    if ($LASTEXITCODE -ne 0) { Die "dune build failed" }
  } finally { Pop-Location }
} else {
  Step "Skipping the build (-NoBuild)"
  if ($Release) { Warn "-Release with -NoBuild: whatever is already in _build is packaged as is" }
}

if (-not (Test-Path $BinSrc)) { Die "no executable at $BinSrc — run without -NoBuild" }
if (-not (Test-Path (Join-Path $WebSrc 'index.html'))) { Die "no built page at $WebSrc\index.html" }
if (-not (Test-Path (Join-Path $WebSrc 'app.js'))) { Die "no compiled page at $WebSrc\app.js — did js_of_ocaml run?" }

# ------------------------------------------------- step 3: inspect the binary

Step "Inspecting the executable"

# Read the PE header's Machine field rather than trusting the host: the
# installer declares an architecture and must not lie about it.
function Get-PeMachine([string] $Path) {
  $fs = [System.IO.File]::OpenRead($Path)
  try {
    $br = New-Object System.IO.BinaryReader($fs)
    $fs.Position = 0x3C
    $peOffset = $br.ReadInt32()
    $fs.Position = $peOffset
    if ($br.ReadUInt32() -ne 0x00004550) { return $null }   # "PE\0\0"
    return $br.ReadUInt16()
  } finally { $fs.Dispose() }
}

$machine = Get-PeMachine $BinSrc
switch ($machine) {
  0x8664  { $Arch = 'x64';   $InnoArch = 'x64compatible' }
  0x014c  { $Arch = 'x86';   $InnoArch = '' }
  0xAA64  { $Arch = 'arm64'; $InnoArch = 'arm64' }
  default { Die ("unrecognised PE machine type 0x{0:X4} in {1}" -f $machine, $BinSrc) }
}
Info "PE machine is $Arch"

# The import table, read with whichever tool is around. objdump comes with the
# mingw toolchain opam uses on Windows; dumpbin comes with Visual Studio.
# Finding one of these matters more than it looks. Without it nothing can be
# bundled, and the failure is silent on the machine that builds: the DLLs are
# on its PATH, so the app starts here and nowhere else. Hence the breadth of
# the search, and the Die further down rather than a warning.
function Find-ImportTool {
  # A mingw toolchain installed through opam prefixes its binutils with the
  # target triple, so plain "objdump" is often not the name to look for.
  foreach ($name in @('objdump', 'x86_64-w64-mingw32-objdump',
                      'aarch64-w64-mingw32-objdump', 'llvm-objdump')) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return @{ Kind = 'objdump'; Path = $c.Source } }
  }
  $c = Get-Command 'dumpbin' -ErrorAction SilentlyContinue
  if ($c) { return @{ Kind = 'dumpbin'; Path = $c.Source } }
  # Visual Studio ships dumpbin but leaves it off PATH outside a developer
  # prompt. vswhere knows where the installation is.
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) {
    $root = & $vswhere -latest -products * -property installationPath 2>$null | Select-Object -First 1
    if ($root) {
      $tools = Join-Path $root 'VC\Tools\MSVC'
      if (Test-Path $tools) {
        $found = Get-ChildItem -Path $tools -Recurse -Filter 'dumpbin.exe' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -like '*\Hostx64\x64\*' } |
                 Select-Object -First 1
        if ($found) { return @{ Kind = 'dumpbin'; Path = $found.FullName } }
      }
    }
  }
  return $null
}

function Get-ImportedDlls([string] $Path, $Tool) {
  if ($Tool.Kind -eq 'objdump') {
    return (& $Tool.Path -p $Path) |
      Select-String -Pattern 'DLL Name:\s*(\S+)' |
      ForEach-Object { $_.Matches[0].Groups[1].Value }
  }
  return (& $Tool.Path /dependents $Path) |
    Select-String -Pattern '(?i)^\s+(\S+\.dll)\s*$' |
    ForEach-Object { $_.Matches[0].Groups[1].Value }
}

# Last resort for locating a DLL: ask the C compiler, which knows its own
# runtime's whereabouts even when that directory is not on PATH.
function Resolve-ViaCompiler([string] $Dll) {
  foreach ($name in @('gcc', 'x86_64-w64-mingw32-gcc', 'cc')) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $c) { continue }
    $out = (& $c.Source "-print-file-name=$Dll" 2>$null | Select-Object -First 1)
    # gcc echoes the name back unchanged when it finds nothing.
    if ($out -and $out -ne $Dll -and (Test-Path -LiteralPath $out -ErrorAction SilentlyContinue)) {
      return (Resolve-Path -LiteralPath $out).Path
    }
  }
  return $null
}

$tool = Find-ImportTool
if ($null -eq $tool) {
  Die ("no tool found that can read a PE import table (objdump, x86_64-w64-mingw32-objdump,`n" +
       "    llvm-objdump or dumpbin). Without one, a DLL the executable needs would be left out`n" +
       "    of the installer and the app would fail to start on any machine but this one —`n" +
       "    quietly, since the toolchain's DLLs are on PATH here. Refusing to build rather than`n" +
       "    ship that. Install binutils, or the Visual Studio build tools for dumpbin.")
}
Info "reading imports with $($tool.Path)"

# Where a non-system DLL might live. In practice these are the mingw-w64
# runtime libraries, which owebview pulls in through -lstdc++ (see its
# lib/config/discover.ml, mingw_link_flags). They sit beside the compiler, so
# PATH usually has them; when it does not, gcc -print-file-name does.
#
# WebView2Loader.dll is deliberately NOT searched for. owebview's vendored
# webview.h defaults to WEBVIEW_MSWEBVIEW2_BUILTIN_IMPL=1, which locates the
# runtime through the registry on its own; the LoadLibraryW of
# WebView2Loader.dll is guarded by is_loaded() with that built-in
# implementation as the fallback. Being loaded by name at runtime, it never
# appears in the import table either — so shipping the NuGet copy would add
# weight and nothing else.
$searchDirs = @((Split-Path -Parent $BinSrc))
$searchDirs += ($env:PATH -split ';' | Where-Object { $_ })

function Test-SystemDll([string] $Name) {
  $n = $Name.ToLower()
  return ($SystemDlls -contains $n) -or ($n -like 'api-ms-win-*') -or ($n -like 'ext-ms-*')
}

function Resolve-DllPath([string] $Dll) {
  foreach ($dir in $searchDirs) {
    $p = Join-Path $dir $Dll
    if (Test-Path $p) { return $p }
  }
  return (Resolve-ViaCompiler $Dll)
}

# Walk the whole import closure, not just the executable's own table.
#
# This is the bug that shipped in 0.1.0. A DLL we bundle has imports of its
# own: libstdc++-6.dll pulls in libgcc_s_seh-1.dll and libwinpthread-1.dll,
# and neither of those appears anywhere in main.exe's import table. Scanning
# one level deep found libstdc++-6.dll, shipped it alone, and the installed
# app died on launch with "the code execution cannot proceed because
# libgcc_s_seh-1.dll was not found" — on any machine without a toolchain,
# which is to say on every machine but the one that built it.
#
# So: queue the executable, scan it, and queue every non-system DLL found so
# that whatever *it* imports is scanned too, until nothing new turns up.
$bundled = @{}
$seen = @{}
$queue = New-Object System.Collections.Queue
$queue.Enqueue(@{ Path = $BinSrc; Name = (Split-Path -Leaf $BinSrc) })
$scanned = 0

while ($queue.Count -gt 0) {
  $item = $queue.Dequeue()
  $scanned++
  foreach ($dll in @(Get-ImportedDlls $item.Path $tool)) {
    $n = $dll.ToLower()
    if ($seen.ContainsKey($n)) { continue }
    $seen[$n] = $true
    if (Test-SystemDll $dll) { continue }

    $found = Resolve-DllPath $dll
    if (-not $found) {
      Die ("$($item.Name) imports $dll, which Windows does not ship and which is neither on`n" +
           "    PATH nor known to the C compiler. It has to be inside the installer, or the app`n" +
           "    will not start on another machine.")
    }
    $bundled[$n] = $found
    Info "  bundling $dll  (needed by $($item.Name))"
    # Scan what this one imports in turn.
    $queue.Enqueue(@{ Path = $found; Name = $dll })
  }
}

Info "scanned $scanned binaries, bundling $($bundled.Count) DLLs Windows does not ship"
$bundled = @($bundled.Values)

# ------------------------------------------------------ step 4: build the icon

Step "Building the icon from logo.png"

$IcoPath = Join-Path $WorkDir 'sun-notes.ico'
$sizeList = ($IconSizes -join ',')

$magick = Get-Command 'magick' -ErrorAction SilentlyContinue
if (-not $magick) { $magick = Get-Command 'convert' -ErrorAction SilentlyContinue }

if ($magick) {
  & $magick.Source $SrcIcon -define "icon:auto-resize=$sizeList" $IcoPath
  if ($LASTEXITCODE -ne 0) { Die "ImageMagick failed to build the icon" }
  Info "built with ImageMagick: $sizeList"
} else {
  $py = Get-Command 'python' -ErrorAction SilentlyContinue
  if (-not $py) { $py = Get-Command 'python3' -ErrorAction SilentlyContinue }
  $havePillow = $false
  if ($py) {
    & $py.Source -c 'import PIL' 2>$null
    $havePillow = ($LASTEXITCODE -eq 0)
  }
  if ($havePillow) {
    $pyScript = @'
import sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
sizes = [int(s) for s in sys.argv[3:]]
im = Image.open(src).convert("RGBA")
im.save(dst, format="ICO", sizes=[(s, s) for s in sizes])
'@
    $pyFile = Join-Path $WorkDir 'mkico.py'
    Set-Content -Path $pyFile -Value $pyScript -Encoding UTF8
    & $py.Source $pyFile $SrcIcon $IcoPath @IconSizes
    if ($LASTEXITCODE -ne 0) { Die "Pillow failed to build the icon" }
    Info "built with Pillow: $sizeList"
  } else {
    Die ("neither ImageMagick nor Pillow found — one of them is needed to turn logo.png into an .ico.`n" +
         "    winget install ImageMagick.ImageMagick, or pip install Pillow")
  }
}

# ------------------------------------------------- step 5: assemble the tree

Step "Assembling the payload"

$Stage = Join-Path $WorkDir 'stage'
New-Item -ItemType Directory -Path (Join-Path $Stage 'web') -Force | Out-Null

Copy-Item $BinSrc (Join-Path $Stage $ExeName)
Copy-Item $IcoPath (Join-Path $Stage 'sun-notes.ico')
foreach ($dll in $bundled) { Copy-Item $dll $Stage }

# Only the runtime assets: dune stages the OCaml sources of the page in the
# same build directory.
Get-ChildItem -Path $WebSrc -File |
  Where-Object {
    $_.Extension -notin @('.ml', '.mli') -and
    $_.Name -ne 'dune' -and
    $_.Name -notlike '*.bc.js' -and
    $_.Name -notlike '*.bc-for-jsoo' -and
    $_.Name -notlike '.*'
  } |
  ForEach-Object { Copy-Item $_.FullName (Join-Path $Stage 'web') }

foreach ($needed in @('web\index.html', 'web\app.js')) {
  if (-not (Test-Path (Join-Path $Stage $needed))) { Die "$needed is missing from the payload" }
}
Info "page: $((Get-ChildItem (Join-Path $Stage 'web')).Name -join ' ')"

# Inno shows the licence in the wizard and wants a text file for it.
Copy-Item $License (Join-Path $WorkDir 'LICENSE.txt')

# The .exe carries no icon resource of its own, so Explorer shows the generic
# one. rcedit patches the built binary in place — optional, because the
# shortcuts point at the .ico regardless and the app works either way.
$rcedit = Get-Command 'rcedit' -ErrorAction SilentlyContinue
if (-not $rcedit) { $rcedit = Get-Command 'rcedit-x64' -ErrorAction SilentlyContinue }
if ($rcedit) {
  & $rcedit.Source (Join-Path $Stage $ExeName) `
      --set-icon $IcoPath `
      --set-file-version $NumericVersion `
      --set-product-version $NumericVersion `
      --set-version-string 'ProductName' $AppName `
      --set-version-string 'FileDescription' $Synopsis `
      --set-version-string 'CompanyName' $Publisher `
      --set-version-string 'LegalCopyright' $Copyright
  if ($LASTEXITCODE -ne 0) { Warn "rcedit failed — the .exe keeps the generic icon" }
  else { Info "embedded the icon and version info into $ExeName" }
} else {
  Warn "rcedit not found — the .exe keeps the generic icon in Explorer (the shortcuts still get the right one)."
  Warn "Install it with: winget install --id=ElectronNET.RcEdit  (or npm i -g rcedit)"
}

# ------------------------------------------------- step 6: write the script

Step "Writing the Inno Setup script"

# French is only offered if this Inno installation actually has the file;
# naming a missing .isl is a hard compile error.
$FrenchIsl = Join-Path (Split-Path -Parent $Iscc) 'Languages\French.isl'
$LanguageLines = 'Name: "english"; MessagesFile: "compiler:Default.isl"'
if (Test-Path $FrenchIsl) {
  $LanguageLines += "`nName: `"french`"; MessagesFile: `"compiler:Languages\French.isl`""
  Info "offering English and French"
} else {
  Warn "French.isl not found next to ISCC — the installer will be English only"
}

$ArchLines = ''
if ($InnoArch) {
  $ArchLines = "ArchitecturesAllowed=$InnoArch`nArchitecturesInstallIn64BitMode=$InnoArch"
}

$SetupBase = "Sun-notes-$Version-$Arch-setup"

$Iss = @"
; Generated by packaging\make-installer.ps1 — edit that, not this.

[Setup]
AppId=$AppGuid
AppName=$AppName
AppVersion=$Version
VersionInfoVersion=$NumericVersion
AppPublisher=$Publisher
AppPublisherURL=$HomePage
AppSupportURL=$HomePage/issues
AppUpdatesURL=$HomePage/releases
AppCopyright=$Copyright
DefaultDirName={autopf}\$AppName
DefaultGroupName=$AppName
; lowest means no UAC prompt and an install under the user's own profile.
; A user who wants it for everyone can still elevate from the dialog.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
$ArchLines
OutputDir=$OutDir
OutputBaseFilename=$SetupBase
SetupIconFile=$IcoPath
UninstallDisplayIcon={app}\$ExeName
LicenseFile=$WorkDir\LICENSE.txt
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes

[Languages]
$LanguageLines

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "$Stage\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\$AppName"; Filename: "{app}\$ExeName"; IconFilename: "{app}\sun-notes.ico"
Name: "{group}\{cm:UninstallProgram,$AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\$AppName"; Filename: "{app}\$ExeName"; IconFilename: "{app}\sun-notes.ico"; Tasks: desktopicon

[Run]
; The runtime first, if it is missing, then the app.
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Installing the Microsoft Edge WebView2 runtime..."; Check: WebView2Missing; Flags: waituntilterminated skipifdoesntexist
Filename: "{app}\$ExeName"; Description: "{cm:LaunchProgram,$AppName}"; Flags: nowait postinstall skipifsilent

[Code]
// The app is a native window wrapped around the system web engine, which on
// Windows is WebView2. Windows 11 has it; Windows 10 usually got it with Edge,
// but not always, and when it is missing the window comes up empty with no
// error at all. So: look for it, and fetch Microsoft's Evergreen bootstrapper
// if it is not there.
//
// The checks below mirror what the app itself does at startup. owebview's
// vendored webview.h (find_installed_client) reads the EBWebView value under
// ClientState\<stable channel guid>, in the 32-bit registry view, per-machine
// first and then per-user — and that same GUID is a constant in that header.
// Checking the very same places is what keeps "the installer said it was
// there" from ever disagreeing with "the window came up empty".
//
// The Clients\<guid>\pv value is Microsoft's documented check, kept as a
// second opinion: every WebView2 installer writes it.
const
  WebView2Client = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  ClientStateKey = 'SOFTWARE\Microsoft\EdgeUpdate\ClientState\';
  ClientsKey     = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\';
  BootstrapperUrl = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703';

var
  DownloadPage: TDownloadWizardPage;

function NonEmptyValue(RootKey: Integer; SubKey, ValueName: String): Boolean;
var
  Value: String;
begin
  Result := False;
  if RegQueryStringValue(RootKey, SubKey, ValueName, Value) then
    Result := (Value <> '') and (Value <> '0.0.0.0');
end;

function WebView2Installed: Boolean;
begin
  Result := NonEmptyValue(HKLM32, ClientStateKey + WebView2Client, 'EBWebView');
  if not Result then
    Result := NonEmptyValue(HKCU32, ClientStateKey + WebView2Client, 'EBWebView');
  if not Result then
    Result := NonEmptyValue(HKLM32, ClientsKey + WebView2Client, 'pv');
  if not Result then
    Result := NonEmptyValue(HKCU32, ClientsKey + WebView2Client, 'pv');
end;

function WebView2Missing: Boolean;
begin
  Result := not WebView2Installed;
end;

function OnDownloadProgress(const Url, FileName: String; const Progress, ProgressMax: Int64): Boolean;
begin
  Result := True;
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc), @OnDownloadProgress);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Dummy: Integer;
begin
  Result := True;
  if (CurPageID = wpReady) and WebView2Missing then
  begin
    DownloadPage.Clear;
    DownloadPage.Add(BootstrapperUrl, 'MicrosoftEdgeWebview2Setup.exe', '');
    DownloadPage.Show;
    try
      try
        DownloadPage.Download;
      except
        // Not fatal: the app may still find a runtime the registry did not
        // advertise, and refusing to install helps nobody. Say so and carry on.
        Dummy := SuppressibleMsgBox(
          'The Microsoft Edge WebView2 runtime could not be downloaded.' #13#10 #13#10 +
          'Setup will continue. If $AppName opens an empty window, install the runtime' #13#10 +
          'from https://developer.microsoft.com/microsoft-edge/webview2/ and start it again.',
          mbInformation, MB_OK, IDOK);
      end;
    finally
      DownloadPage.Hide;
    end;
  end;
end;
"@

$IssPath = Join-Path $WorkDir 'sun-notes.iss'
Set-Content -Path $IssPath -Value $Iss -Encoding UTF8
Info "spec: $IssPath"

# ------------------------------------------------- step 7: build the installer

Step "Compiling the installer"

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
& $Iscc /Q $IssPath
if ($LASTEXITCODE -ne 0) { Die "ISCC failed" }

$FinalExe = Join-Path $OutDir "$SetupBase.exe"
if (-not (Test-Path $FinalExe)) { Die "ISCC reported success but produced no $FinalExe" }

# ------------------------------------------------------- step 8: sign

if ($SignToolPath) {
  Step "Signing"
  if (-not (Test-Path $SignToolPath)) { Die "signtool not found at $SignToolPath" }
  $signArgList = @('sign') + ($SignArgs -split ' ' | Where-Object { $_ }) + @($FinalExe)
  & $SignToolPath @signArgList
  if ($LASTEXITCODE -ne 0) { Die "signing failed" }
  Info "signed"
} else {
  Warn "not signed. Windows SmartScreen will warn users that the publisher is unknown, and"
  Warn "will keep doing so until the certificate builds reputation. Pass -SignToolPath and"
  Warn "-SignArgs to sign with a code-signing certificate you own."
}

# ------------------------------------------------------- step 9: verify

Step "Verifying"

$item = Get-Item $FinalExe
Info "$($item.FullName)"
Info "$([math]::Round($item.Length / 1MB, 1)) MB"
Info ""
Info "Payload:"
Get-ChildItem -Path $Stage -Recurse -File |
  ForEach-Object { Info ("        " + $_.FullName.Substring($Stage.Length + 1)) }

if ($KeepTree) {
  $keep = Join-Path $OutDir 'sun-notes_tree'
  if (Test-Path $keep) { Remove-Item $keep -Recurse -Force }
  Copy-Item $Stage $keep -Recurse
  Copy-Item $IssPath (Join-Path $OutDir 'sun-notes.iss')
  Info "kept $keep and $(Join-Path $OutDir 'sun-notes.iss')"
}

Step "Done"
Info $FinalExe

} finally {
  if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}
