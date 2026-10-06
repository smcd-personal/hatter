<#
.SYNOPSIS
    Set up hatter's WezTerm client on Windows, with no bash and no WSL.

.DESCRIPTION
    Every step checks before it acts, so running this again is safe and
    doubles as a health check:

      1. winget, WezTerm and Git          installed if missing
      2. OpenSSH client and ssh-agent     one elevation prompt, only if needed
      3. an ssh key, loaded in the agent  generated if missing
      4. your hatter config               cloned, or pulled if already there
      5. the hatter WezTerm plugin        fetched at -Ref
      6. ~\.wezterm.lua                   written, then loaded to prove it works
      7. every hat                        probed over ssh, with a fix for each
                                          one that refuses this machine's key

    Run it from PowerShell:

      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/smcd-personal/hatter/main/tools/install-windows.ps1))) -ConfigRemote you@shell.example.com:git/dotfiles.git

.PARAMETER ConfigRemote
    Where `hatter backup` pushes your config. Needed the first time only.

.PARAMETER Ref
    The hatter branch, tag or commit to install the plugin from. Default main.

.PARAMETER Yes
    Answer yes to every question, including replacing an existing
    ~\.wezterm.lua (which is always backed up first).

.PARAMETER NonInteractive
    For CI: never prompt. Implies -Yes, and a missing key is generated with
    no passphrase. Not for a machine a person uses.
#>
[CmdletBinding()]
param(
    [string]$ConfigRemote,
    [string]$Ref = 'main',
    [string]$RepoUrl = 'https://github.com/smcd-personal/hatter',
    [switch]$NoMaximize,
    [switch]$Yes,
    [switch]$NonInteractive,
    [switch]$SkipInstall,
    [switch]$SkipHatCheck,
    [switch]$NoLaunch
)

# Windows PowerShell 5.1 is what a fresh machine has, so nothing here may need
# 7: no ternaries, no ??, no && between commands.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
if ($NonInteractive) { $Yes = $true }

# ------------------------------------------------------------------ output

$script:Problems = New-Object System.Collections.ArrayList

function Step($msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  ok  $msg" -ForegroundColor Green }
function Note($msg) { Write-Host "      $msg" }
function Warn($msg) {
    Write-Host "  !!  $msg" -ForegroundColor Yellow
    [void]$script:Problems.Add($msg)
}
# Never `exit`: run as a scriptblock from the one-line install, exit would close
# the user's PowerShell window. Throw, and let the outermost handler report it.
$FailTag = 'hatter-install: '
function Fail($msg) { throw ($FailTag + $msg) }

function Confirm-Step($question) {
    if ($Yes) { return $true }
    $a = Read-Host "  $question [y/N]"
    return ($a -match '^(y|yes)$')
}

# A native command, with its exit code and everything it printed. With
# ErrorActionPreference at Stop, 5.1 turns any stderr line into a terminating
# error, so it is relaxed for the call.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ Code = $code; Out = ($out -join "`n") }
}

# winget changes PATH in the registry; this process has to read it again.
function Sync-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Forward slashes, for Lua and for git's sshCommand.
function ConvertTo-Slash($p) { return ($p -replace '\\', '/') }

function Install-Hatter {
    # ------------------------------------------------------------------- paths

    if ($env:OS -ne 'Windows_NT') { Fail 'this installer is for Windows. On macOS or Linux, see docs/install-wezterm.md.' }

    $Home_      = $env:USERPROFILE
    $SshDir     = Join-Path $env:SystemRoot 'System32\OpenSSH'
    $Ssh        = Join-Path $SshDir 'ssh.exe'
    $SshKeygen  = Join-Path $SshDir 'ssh-keygen.exe'
    $SshAdd     = Join-Path $SshDir 'ssh-add.exe'
    $KeyPath    = Join-Path $Home_ '.ssh\id_ed25519'
    $ConfigBase = $env:XDG_CONFIG_HOME
    if (-not $ConfigBase) { $ConfigBase = Join-Path $Home_ '.config' }
    $ConfigDir  = Join-Path $ConfigBase 'hatter'
    $ConfigJson = Join-Path $ConfigDir 'config.json'
    $PluginDir  = Join-Path $env:LOCALAPPDATA 'hatter\src'
    $WezConfig  = Join-Path $Home_ '.wezterm.lua'
    $WezLocal   = Join-Path $Home_ '.wezterm-local.lua'
    $Marker     = "-- Written by hatter's install-windows.ps1."

    # Host keys: a new host is accepted and remembered, a changed one is refused.
    # The same trust as answering "yes" at the first prompt, without the prompt
    # that BatchMode would turn into a failure.
    $SshOpts = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10')
    $GitSsh  = '"' + (ConvertTo-Slash $Ssh) + '" -o StrictHostKeyChecking=accept-new'

    Write-Host 'hatter: Windows setup' -ForegroundColor Cyan
    Note "plugin ref: $Ref"

    # ---------------------------------------------------------- 1. WezTerm, Git

    Step 'WezTerm and Git'

    function Find-WezTerm {
        $c = Get-Command wezterm -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        $p = Join-Path $env:ProgramFiles 'WezTerm\wezterm.exe'
        if (Test-Path $p) { return $p }
        return $null
    }

    function Install-WithWinget($id, $name) {
        if ($SkipInstall) { Fail "$name is not installed, and -SkipInstall was given." }
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Fail "$name is not installed, and winget is not available to install it.
      Install 'App Installer' from the Microsoft Store, or install $name by hand."
        }
        Note "installing $name with winget..."
        $r = Invoke-Native winget @('install', '--id', $id, '-e', '--silent',
            '--accept-package-agreements', '--accept-source-agreements')
        Sync-Path
        if ($r.Code -ne 0) { Fail "winget could not install ${name}:`n$($r.Out)" }
    }

    $Wez = Find-WezTerm
    if (-not $Wez) { Install-WithWinget 'wez.wezterm' 'WezTerm'; $Wez = Find-WezTerm }
    if (-not $Wez) { Fail 'WezTerm was installed but wezterm.exe cannot be found. Open a new PowerShell and run this again.' }
    Ok ("WezTerm   " + (Invoke-Native $Wez @('--version')).Out)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Install-WithWinget 'Git.Git' 'Git'
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            $g = Join-Path $env:ProgramFiles 'Git\cmd'
            if (Test-Path $g) { $env:Path += ";$g" }
        }
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail 'Git was installed but git.exe cannot be found. Open a new PowerShell and run this again.' }
    Ok ("Git       " + (Invoke-Native git @('--version')).Out)

    # ----------------------------------------------------- 2. OpenSSH and agent

    Step 'OpenSSH client and agent'

    # Everything that needs an administrator, gathered so there is one prompt.
    $admin = New-Object System.Collections.ArrayList
    if (-not (Test-Path $Ssh)) {
        [void]$admin.Add('Get-WindowsCapability -Online -Name OpenSSH.Client* | Add-WindowsCapability -Online | Out-Null')
    }
    $agent = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ((-not $agent) -or ($agent.StartType -ne 'Automatic') -or ($agent.Status -ne 'Running')) {
        [void]$admin.Add('Set-Service ssh-agent -StartupType Automatic')
        [void]$admin.Add('Start-Service ssh-agent')
    }

    if ($admin.Count -gt 0) {
        $adminScript = ($admin -join "`n")
        if (Test-Admin) {
            & ([scriptblock]::Create($adminScript))
        } elseif ($NonInteractive) {
            Warn 'not an administrator, so the ssh client or agent could not be set up'
        } else {
            Note 'asking for administrator rights to set up the ssh client and agent...'
            $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(
                "`$ErrorActionPreference = 'Stop'`n" + $adminScript))
            try {
                Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden `
                    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $b64
            } catch {
                Warn 'administrator rights were declined'
            }
        }
    }

    if (-not (Test-Path $Ssh)) { Fail "the OpenSSH client is not installed ($Ssh)." }
    Ok ("ssh       " + (Invoke-Native $Ssh @('-V')).Out)

    $agent = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($agent -and $agent.Status -eq 'Running') {
        Ok 'ssh-agent running, starts with Windows'
    } else {
        Warn 'ssh-agent is not running: every tab will ask for your key passphrase'
    }

    # ------------------------------------------------------------- 3. ssh key

    Step 'ssh key'

    if (-not (Test-Path $KeyPath)) {
        New-Item -ItemType Directory -Force (Split-Path $KeyPath) | Out-Null
        $comment = "$env:USERNAME@$env:COMPUTERNAME"
        if ($NonInteractive) {
            # Start-Process passes this line as is, so -N "" reaches ssh-keygen
            # as an empty passphrase on both 5.1 and 7.
            Start-Process -Wait -NoNewWindow $SshKeygen `
                -ArgumentList "-q -t ed25519 -N `"`" -C `"$comment`" -f `"$KeyPath`""
        } else {
            Note 'no key yet - making one. Choose a passphrase; the agent remembers it.'
            & $SshKeygen -t ed25519 -C $comment -f $KeyPath
        }
        if (-not (Test-Path $KeyPath)) { Fail 'ssh-keygen did not create a key.' }
        Ok "created $KeyPath"
    } else {
        Ok "found $KeyPath"
    }
    $PubKey = (Get-Content "$KeyPath.pub" -Raw).Trim()

    $agent = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($agent -and $agent.Status -eq 'Running') {
        $fp = ((Invoke-Native $SshKeygen @('-l', '-f', "$KeyPath.pub")).Out -split ' ')[1]
        $loaded = (Invoke-Native $SshAdd @('-l')).Out
        if ($loaded -like "*$fp*") {
            Ok 'key loaded in the agent'
        } elseif ($NonInteractive) {
            [void](Invoke-Native $SshAdd @($KeyPath))
        } else {
            & $SshAdd $KeyPath
            if ($LASTEXITCODE -eq 0) { Ok 'key loaded in the agent' } else { Warn 'the key could not be added to the agent' }
        }
    }

    function Show-KeyFix($hats) {
        try { Set-Clipboard -Value $PubKey; $clip = ' (it is on your clipboard)' } catch { $clip = '' }
        Write-Host ''
        Write-Host "  This machine's key$clip is not authorised there yet. On a machine" -ForegroundColor Yellow
        Write-Host '  that already reaches your hats, run:' -ForegroundColor Yellow
        Write-Host ''
        Write-Host "    hatter key add '$PubKey' $hats" -ForegroundColor White
        Write-Host ''
        Write-Host '  then run this installer again.' -ForegroundColor Yellow
    }

    # --------------------------------------------------------- 4. hatter config

    Step 'hatter config'

    if (Test-Path (Join-Path $ConfigDir '.git')) {
        [void](Invoke-Native git @('-C', $ConfigDir, 'config', 'core.sshCommand', $GitSsh))
        $r = Invoke-Native git @('-C', $ConfigDir, 'pull', '--ff-only', '-q')
        if ($r.Code -eq 0) { Ok "up to date: $ConfigDir" } else { Warn "could not pull the config: $($r.Out)" }
    } elseif (Test-Path $ConfigJson) {
        Ok "found $ConfigJson (not a git clone, so it is not updated)"
    } else {
        if (-not $ConfigRemote) {
            if ($NonInteractive) { Fail 'no hatter config yet. Pass -ConfigRemote <where hatter backup pushes>.' }
            $ConfigRemote = Read-Host '  Where does `hatter backup` push your config? (e.g. you@shell.example.com:git/dotfiles.git)'
            if (-not $ConfigRemote) { Fail 'no config remote given.' }
        }
        New-Item -ItemType Directory -Force $ConfigBase | Out-Null
        $r = Invoke-Native git @('-c', "core.sshCommand=$GitSsh", 'clone', '-q', $ConfigRemote, $ConfigDir)
        if ($r.Code -ne 0) {
            Write-Host $r.Out
            if ($r.Out -match 'Permission denied') {
                $h = ($ConfigRemote -split ':')[0]
                Show-KeyFix "<the hat on $h>"
                Fail 'the config server does not accept this key yet.'
            }
            Fail "could not clone $ConfigRemote"
        }
        [void](Invoke-Native git @('-C', $ConfigDir, 'config', 'core.sshCommand', $GitSsh))
        Ok "cloned into $ConfigDir"
    }

    if (-not (Test-Path $ConfigJson)) { Fail "$ConfigJson is missing - is that the right repository?" }
    try {
        $Config = Get-Content $ConfigJson -Raw | ConvertFrom-Json
    } catch {
        Fail "$ConfigJson is not valid JSON."
    }
    $HatNames = @()
    if ($Config.PSObject.Properties['hats'] -and $Config.hats) {
        $HatNames = @($Config.hats.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
    }
    Ok ("{0} hats: {1}" -f $HatNames.Count, ($HatNames -join ', '))

    # -------------------------------------------------------- 5. the plugin

    Step "hatter WezTerm plugin ($Ref)"

    if (-not (Test-Path (Join-Path $PluginDir '.git'))) {
        New-Item -ItemType Directory -Force $PluginDir | Out-Null
        [void](Invoke-Native git @('-C', $PluginDir, 'init', '-q'))
        [void](Invoke-Native git @('-C', $PluginDir, 'remote', 'add', 'origin', $RepoUrl))
    }
    [void](Invoke-Native git @('-C', $PluginDir, 'remote', 'set-url', 'origin', $RepoUrl))
    $r = Invoke-Native git @('-C', $PluginDir, 'fetch', '-q', '--depth', '1', 'origin', $Ref)
    if ($r.Code -ne 0) { Fail "could not fetch $Ref from ${RepoUrl}:`n$($r.Out)" }
    $r = Invoke-Native git @('-C', $PluginDir, 'checkout', '-q', '--force', '--detach', 'FETCH_HEAD')
    if ($r.Code -ne 0) { Fail "could not check out ${Ref}:`n$($r.Out)" }
    $PluginInit = Join-Path $PluginDir 'plugin\init.lua'
    if (-not (Test-Path $PluginInit)) { Fail "$Ref has no plugin/init.lua - it predates the WezTerm plugin. Try -Ref main." }
    $rev = (Invoke-Native git @('-C', $PluginDir, 'rev-parse', '--short', 'HEAD')).Out
    Ok "$PluginDir at $rev"

    # ----------------------------------------------------- 6. WezTerm config

    Step 'WezTerm config'

    $maximize = 'true'
    if ($NoMaximize) { $maximize = 'false' }
    $luaPlugin = ConvertTo-Slash $PluginDir

    $lua = @"
$Marker
-- Running it again rewrites this file, so put your own settings in
-- ~/.wezterm-local.lua instead: return a function that takes (config, wezterm).
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- hatter: Ctrl+Shift+O opens a workspace on any hat.
local hatter = dofile '$luaPlugin/plugin/init.lua'
hatter.apply_to_config(config)

-- Ctrl+Shift+S: switch between the hats you have open.
table.insert(config.keys, {
  key = 'S', mods = 'CTRL|SHIFT',
  action = wezterm.action.ShowLauncherArgs { flags = 'FUZZY|WORKSPACES' },
})

-- Open maximized.
if $maximize then
  wezterm.on('gui-startup', function(cmd)
    local _, _, window = wezterm.mux.spawn_window(cmd or {})
    window:gui_window():maximize()
  end)
end

local ok, extra = pcall(dofile, wezterm.home_dir .. '/.wezterm-local.lua')
if ok and type(extra) == 'function' then
  extra(config, wezterm)
end

return config
"@

    $write = $true
    if (Test-Path $WezConfig) {
        $existing = Get-Content $WezConfig -Raw
        if ($existing -and $existing.StartsWith($Marker)) {
            if ($existing.Trim() -eq $lua.Trim()) { $write = $false; Ok "$WezConfig is current" }
        } elseif ($existing -and $existing.Trim()) {
            $bak = "$WezConfig.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Note "$WezConfig exists and was not written by this installer."
            if (Confirm-Step "Replace it? It is kept as $(Split-Path $bak -Leaf)") {
                Copy-Item $WezConfig $bak
                Ok "backed up to $bak"
                if (-not (Test-Path $WezLocal)) {
                    Note 'anything of your own from it belongs in ~\.wezterm-local.lua'
                }
            } else {
                $write = $false
                Warn "left $WezConfig alone, so the hatter picker is not set up"
            }
        }
    }

    if ($write) {
        # UTF-8 without a BOM, written in one go - never half-saved.
        [IO.File]::WriteAllText($WezConfig, $lua, (New-Object Text.UTF8Encoding $false))
        Ok "wrote $WezConfig"
    }

    # WezTerm uses the first of these it finds, so either one hides ours.
    if ($env:WEZTERM_CONFIG_FILE) {
        Warn "WEZTERM_CONFIG_FILE is set to $env:WEZTERM_CONFIG_FILE, so WezTerm ignores ~\.wezterm.lua"
    }
    $besideExe = Join-Path (Split-Path $Wez) 'wezterm.lua'
    if (Test-Path $besideExe) { Warn "$besideExe exists, so WezTerm ignores ~\.wezterm.lua" }

    # WezTerm exits 0 even when a config fails to load, and says so on stderr.
    $r = Invoke-Native $Wez @('--config-file', $WezConfig, 'ls-fonts')
    $errs = @($r.Out -split "`n" | Where-Object { $_ -match '\bERROR\b|syntax error|runtime error' })
    if ($errs.Count -gt 0) {
        Write-Host ($errs -join "`n")
        Fail "WezTerm could not load $WezConfig."
    }
    Ok 'WezTerm loads it cleanly'

    # ---------------------------------------------------------- 7. the hats

    if (-not $SkipHatCheck -and $HatNames.Count -gt 0) {
        Step 'Reaching each hat'
        $denied = @()
        foreach ($h in $HatNames) {
            $dest = $null
            $hp = $Config.hats.$h
            if ($hp -and $hp.PSObject.Properties['ssh']) { $dest = [string]$hp.ssh }
            if (-not $dest -or $dest.StartsWith('-')) { Warn "${h}: no usable ssh destination"; continue }
            $r = Invoke-Native $Ssh ($SshOpts + @('-o', 'BatchMode=yes', $dest, 'true'))
            if ($r.Code -eq 0) {
                Ok ("{0,-12} {1}" -f $h, $dest)
            } elseif ($r.Out -match 'Permission denied') {
                Warn ("{0,-12} {1}  key not authorised" -f $h, $dest)
                $denied += $h
            } else {
                $why = ($r.Out -split "`n" | Select-Object -Last 1)
                Warn ("{0,-12} {1}  unreachable: {2}" -f $h, $dest, $why)
            }
        }
        if ($denied.Count -gt 0) { Show-KeyFix ($denied -join ' ') }
    }

    # ------------------------------------------------------------------- done

    Step 'Done'
    if ($script:Problems.Count -eq 0) {
        Ok 'everything checked out'
    } else {
        Note ("{0} thing(s) need attention - see the !! lines above." -f $script:Problems.Count)
    }
    Note 'In WezTerm: Ctrl+Shift+O opens any workspace, Ctrl+Shift+S switches hats.'
    Note 'Run this again any time to update the plugin and the config, and to re-check.'

    if (-not $NoLaunch -and -not $NonInteractive) {
        $gui = Join-Path (Split-Path $Wez) 'wezterm-gui.exe'
        if (Test-Path $gui) { Start-Process $gui }
    }
}

try {
    Install-Hatter
    # Otherwise the caller sees whatever the last native command left in
    # $LASTEXITCODE - a refused ssh probe, say - and calls a finished run failed.
    if ($NonInteractive) { exit 0 }
} catch {
    $m = "$($_.Exception.Message)"
    if (-not $m.StartsWith($FailTag)) { throw }
    Write-Host ''
    Write-Host ('error: ' + $m.Substring($FailTag.Length)) -ForegroundColor Red
    Write-Host 'Fix that and run the installer again - the steps before it are kept.'
    if ($NonInteractive) { exit 1 }
}
