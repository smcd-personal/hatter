<#
.SYNOPSIS
    Set up hatter's WezTerm client on Windows, with no bash and no WSL.

.DESCRIPTION
    Every step checks before it acts, so running this again is safe and
    doubles as a health check:

      1. winget, WezTerm and Git          installed if missing
      2. OpenSSH client and ssh-agent     one elevation prompt, only if needed
      3. an ssh key, loaded in the agent  one you have, or a new one
      4. your hatter config               cloned, or pulled if already there
      5. the hatter WezTerm plugin        fetched at -Ref
      6. ~\.wezterm.lua                   written, then loaded to prove it works
      7. every hat                        probed over ssh, with a fix for each
                                          one that refuses this machine's key

    Run it from PowerShell:

      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/smcd-personal/hatter/main/tools/install-windows.ps1))) -ConfigRemote you@shell.example.com:git/dotfiles.git

.PARAMETER ConfigRemote
    Where `hatter backup` pushes your config. Needed the first time only.

.PARAMETER KeyPath
    The private key to use. Without it the installer asks - listing the keys
    it finds in a folder you choose - and remembers the answer for next time.

.PARAMETER Ref
    The hatter branch, tag or commit to install the plugin from. Default main.

.PARAMETER Yes
    Answer yes to every question, including replacing an existing
    ~\.wezterm.lua (which is always backed up first).

.PARAMETER NonInteractive
    For CI: never prompt. Implies -Yes. With no -KeyPath and no key chosen
    before, it uses ~/.ssh/id_ed25519, generating it with no passphrase if
    missing. Not for a machine a person uses.
#>
[CmdletBinding()]
param(
    [string]$ConfigRemote,
    [string]$Ref = 'main',
    [string]$KeyPath,
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
    $SshHome    = Join-Path $Home_ '.ssh'
    $StateFile  = Join-Path $env:LOCALAPPDATA 'hatter\install.json'
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

    # What a file is, from its first line: a private key Windows OpenSSH can
    # use, one it cannot (with the reason), or not a key at all ($null).
    function Get-KeyKind($path) {
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if (-not $item -or $item.PSIsContainer -or $item.Length -gt 65536) { return $null }
        $first = Get-Content -LiteralPath $path -TotalCount 1 -ErrorAction SilentlyContinue
        if (-not $first) { return $null }
        switch -Regex ($first) {
            '^-----BEGIN (OPENSSH) PRIVATE KEY-----'    { return @{ Ok = $true;  Kind = 'OpenSSH' } }
            '^-----BEGIN (RSA|EC) PRIVATE KEY-----'     { return @{ Ok = $true;  Kind = 'PEM' } }
            '^-----BEGIN (ENCRYPTED )?PRIVATE KEY-----' { return @{ Ok = $true;  Kind = 'PKCS#8' } }
            '^-----BEGIN (DSA) PRIVATE KEY-----'        { return @{ Ok = $false; Kind = 'DSA, which current OpenSSH has disabled' } }
            '^PuTTY-User-Key-File-'                     { return @{ Ok = $false; Kind = 'a PuTTY key - in PuTTYgen, Conversions > Export OpenSSH key' } }
        }
        return $null
    }

    # "256 SHA256:abc... comment (ED25519)", read from the .pub when there is
    # one, so an encrypted key is described without asking for its passphrase.
    function Get-KeyLabel($path) {
        $src = $path
        if (Test-Path -LiteralPath "$path.pub") { $src = "$path.pub" }
        $r = Invoke-Native $SshKeygen @('-l', '-f', $src)
        if ($r.Code -eq 0) { return $r.Out.Trim() }
        return '(encrypted - shown once unlocked)'
    }

    function Select-Key {
        $dir = $SshHome
        while ($true) {
            $answer = Read-Host "  Folder to look in [$dir]"
            if ($answer) { $dir = $answer.Trim().Trim('"') }
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                Note "no such folder: $dir"; $dir = $SshHome; continue
            }
            $usable = @(); $unusable = @()
            foreach ($f in Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue) {
                if ($f.Name -like '*.pub') { continue }
                $k = Get-KeyKind $f.FullName
                if (-not $k) { continue }
                if ($k.Ok) { $usable += $f.FullName } else { $unusable += "$($f.Name) ($($k.Kind))" }
            }
            foreach ($u in $unusable) { Note "cannot use $u" }
            if ($usable.Count -eq 0) {
                Note "no OpenSSH private keys in $dir"
                if (Confirm-Step 'Look in another folder?') { continue }
                return $null
            }
            Write-Host ''
            for ($i = 0; $i -lt $usable.Count; $i++) {
                Write-Host ("    {0}) {1}" -f ($i + 1), (Split-Path $usable[$i] -Leaf))
                Write-Host ("       {0}" -f (Get-KeyLabel $usable[$i])) -ForegroundColor DarkGray
            }
            Write-Host '    n) none of these - make a new key'
            Write-Host ''
            $default = ''
            if ($usable.Count -eq 1) { $default = '1' }
            while ($true) {
                $pick = Read-Host "  Which key? [$default]"
                if (-not $pick) { $pick = $default }
                if ($pick -match '^[nN]') { return $null }
                $n = 0
                if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $usable.Count) {
                    return $usable[$n - 1]
                }
                Note "pick 1 to $($usable.Count), or n"
            }
        }
    }

    function Initialize-Key {
        # Never over an existing key: id_ed25519 if free, else a name of its own.
        $path = Join-Path $SshHome 'id_ed25519'
        if (Test-Path -LiteralPath $path) { $path = Join-Path $SshHome 'id_ed25519_hatter' }
        if (Test-Path -LiteralPath $path) { return $path }
        New-Item -ItemType Directory -Force $SshHome | Out-Null
        $comment = "$env:USERNAME@$env:COMPUTERNAME"
        if ($NonInteractive) {
            # Start-Process passes this line as is, so -N "" reaches ssh-keygen
            # as an empty passphrase on both 5.1 and 7.
            Start-Process -Wait -NoNewWindow $SshKeygen `
                -ArgumentList "-q -t ed25519 -N `"`" -C `"$comment`" -f `"$path`""
        } else {
            Note 'making a new key. Choose a passphrase; the agent will remember it.'
            & $SshKeygen -t ed25519 -C $comment -f $path
        }
        if (-not (Test-Path -LiteralPath $path)) { Fail 'ssh-keygen did not create a key.' }
        Ok "created $path"
        return $path
    }

    # Which key: -KeyPath, else the one chosen last time, else ask.
    $state = @{}
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $j = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $state[$p.Name] = [string]$p.Value }
        } catch { $state = @{} }
    }

    $Key = $null
    $remembered = $false
    if ($KeyPath) {
        $Key = (Resolve-Path -LiteralPath $KeyPath -ErrorAction SilentlyContinue).Path
        if (-not $Key) { Fail "no such key: $KeyPath" }
    } elseif ($state['key'] -and (Test-Path -LiteralPath $state['key'])) {
        $Key = $state['key']
        $remembered = $true
    } elseif ($NonInteractive) {
        $Key = Join-Path $SshHome 'id_ed25519'
        if (-not (Test-Path -LiteralPath $Key)) { $Key = Initialize-Key }
    } else {
        if (Confirm-Step 'Use an ssh key you already have? (n makes a new one)') {
            $Key = Select-Key
        }
        if (-not $Key) { $Key = Initialize-Key }
    }

    $kind = Get-KeyKind $Key
    if (-not $kind) { Fail "$Key is not a private key." }
    if (-not $kind.Ok) { Fail "$Key cannot be used ($($kind.Kind))." }
    if ($remembered) { Ok "$Key (chosen before; -KeyPath changes it)" } else { Ok "using $Key" }

    # Windows OpenSSH refuses a private key that anyone but its owner, SYSTEM
    # or Administrators can read - which a key copied in from elsewhere usually
    # can, because it inherits its folder's permissions.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $loose = @((Get-Acl -LiteralPath $Key).Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and
        "$($_.IdentityReference)" -ne $me -and
        "$($_.IdentityReference)" -notmatch '\\(SYSTEM|Administrators)$'
    } | ForEach-Object { "$($_.IdentityReference)" } | Sort-Object -Unique)
    if ($loose.Count -gt 0) {
        Note ("others can read this key: {0}" -f ($loose -join ', '))
        if (Confirm-Step 'ssh refuses a key like that. Restrict it to you?') {
            # Drop inherited entries, keep you and SYSTEM, then remove the rest.
            [void](Invoke-Native icacls @($Key, '/inheritance:r', '/grant:r', "${me}:(F)", '/grant:r', '*S-1-5-18:(F)'))
            foreach ($who in $loose) { [void](Invoke-Native icacls @($Key, '/remove:g', $who)) }
            Ok 'permissions restricted to you'
        } else {
            Warn "$Key is readable by others, so ssh will refuse to use it"
        }
    }

    # The public half: the .pub beside it, or derived from the key itself.
    if (Test-Path -LiteralPath "$Key.pub") {
        $PubKey = (Get-Content -LiteralPath "$Key.pub" -Raw).Trim()
    } else {
        Note 'no .pub beside the key - reading it from the key (asks for the passphrase if it has one)'
        $PubKey = ((& $SshKeygen -y -f $Key) -join '').Trim()
        if (-not $PubKey) { Fail "could not read the public key from $Key" }
    }
    $pubTmp = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($pubTmp, $PubKey + "`n")
    $fp = ((Invoke-Native $SshKeygen @('-l', '-f', $pubTmp)).Out -split ' ')[1]
    Remove-Item -LiteralPath $pubTmp -ErrorAction SilentlyContinue
    Note $fp

    $state['key'] = $Key
    New-Item -ItemType Directory -Force (Split-Path $StateFile) | Out-Null
    ([pscustomobject]$state | ConvertTo-Json) | Set-Content -LiteralPath $StateFile

    # ssh tries only a few default names by itself. Any other key has to be in
    # the agent, which is where this one goes.
    $defaultNames = 'id_rsa', 'id_ecdsa', 'id_ecdsa_sk', 'id_ed25519', 'id_ed25519_sk'
    $isDefault = ((Split-Path $Key) -eq $SshHome) -and ($defaultNames -contains (Split-Path $Key -Leaf))

    $agent = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($agent -and $agent.Status -eq 'Running') {
        $loaded = (Invoke-Native $SshAdd @('-l')).Out
        if ($fp -and $loaded -like "*$fp*") {
            Ok 'key loaded in the agent'
        } elseif ($NonInteractive) {
            $r = Invoke-Native $SshAdd @($Key)
            if ($r.Code -eq 0) { Ok 'key loaded in the agent' } else { Warn "the key could not be added to the agent: $($r.Out)" }
        } else {
            & $SshAdd $Key
            if ($LASTEXITCODE -eq 0) { Ok 'key loaded in the agent' } else { Warn 'the key could not be added to the agent' }
        }
    } elseif (-not $isDefault) {
        Warn "$Key is not one of ssh's default names, and with no agent running ssh will not find it"
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
