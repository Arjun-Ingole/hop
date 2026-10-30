# --- Official download sources -----------------------------------------

function Get-WebText([string]$Url) {
    $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60).Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    $content
}

function ConvertTo-Version([string]$Text) {
    if ($Text -notmatch '\.') { $Text += '.0' }
    [version]$Text
}

function New-Download([string]$Url, [string]$Sha256, [int64]$Size) {
    [pscustomobject]@{ Url = $Url; Sha256 = $Sha256; Size = $Size; FileName = ([uri]$Url).Segments[-1] }
}

function Resolve-Download($Distro) {
    switch ($Distro.Kind) {
        'ubuntu' {
            # SHA256SUMS lists every point release; take the newest desktop ISO.
            $sums = Get-WebText ($Distro.Base + 'SHA256SUMS')
            $pattern = '(?m)^([0-9a-f]{64}) \*?(' + [regex]::Escape($Distro.Prefix) + '-([\d.]+)-desktop-amd64\.iso)\s*$'
            $best = $null
            foreach ($m in [regex]::Matches($sums, $pattern)) {
                $v = ConvertTo-Version $m.Groups[3].Value
                if (-not $best -or $v -gt $best.Version) { $best = @{ Version = $v; Sha = $m.Groups[1].Value; File = $m.Groups[2].Value } }
            }
            if (-not $best) { throw "Could not find the $($Distro.Name) ISO on $($Distro.Source)." }
            return New-Download ($Distro.Base + $best.File) $best.Sha 0
        }
        'mint' {
            $base = 'https://mirrors.edge.kernel.org/linuxmint/stable/'
            $versions = [regex]::Matches((Get-WebText $base), 'href="(\d+(?:\.\d+)?)/"') |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object { ConvertTo-Version $_ } -Descending
            foreach ($v in $versions) {
                try { $sums = Get-WebText "$base$v/sha256sum.txt" } catch { continue }
                $m = [regex]::Match($sums, "(?m)^([0-9a-f]{64}) \*?(linuxmint-[\d.]+-$($Distro.Edition)-64bit\.iso)")
                if ($m.Success) { return New-Download "$base$v/$($m.Groups[2].Value)" $m.Groups[1].Value 0 }
            }
            throw 'Could not find the Linux Mint ISO on the mirror.'
        }
        'pop' {
            $build = Invoke-RestMethod -Uri 'https://api.pop-os.org/builds/24.04/generic' -UseBasicParsing -TimeoutSec 60
            return New-Download $build.url $build.sha_sum ([int64]$build.size)
        }
        'elementary' {
            # The link carries an expiring token, so read it from the site each time.
            # elementary does not publish a checksum; the download is HTTPS from their server.
            $m = [regex]::Match((Get-WebText 'https://elementary.io/'), 'https://dl\.elementaryos\.org/[^"''\s<>]+-amd64[^"''\s<>]*\.iso')
            if (-not $m.Success) { throw 'Could not find the download link on elementary.io.' }
            return New-Download $m.Value $null 0
        }
    }
    throw "Unknown system '$($Distro.Id)'."
}

# --- Download ------------------------------------------------------------

function Test-Sha256([string]$Path, [string]$Expected) {
    Set-Stage 2
    Set-Status 'Checking the download is genuine (takes a minute)...'
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected.ToUpperInvariant()
}

function Invoke-Download($Download, [string]$Path) {
    Set-Stage 1
    $part = "$Path.part"
    $total = $Download.Size
    if (-not $total) {
        try {
            $head = Invoke-WebRequest -Uri $Download.Url -Method Head -UseBasicParsing -TimeoutSec 60
            $total = [int64]($head.Headers['Content-Length'] | Select-Object -First 1)
        } catch { $total = 0 }
    }
    if ($total -and (Test-Path -LiteralPath $part) -and (Get-Item -LiteralPath $part).Length -ge $total) {
        Write-Log 'Download already complete.'
    } else {
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        if (-not (Test-Path $curl)) {
            Set-Status "Downloading $($Download.FileName)..."
            Start-BitsTransfer -Source $Download.Url -Destination $part
        } else {
            # -C - resumes a half-finished download if Install is clicked again.
            $curlArgs = @('-L', '--fail', '--silent', '--show-error', '--retry', '5', '--retry-delay', '5',
                '-C', '-', '-o', "`"$part`"", "`"$($Download.Url)`"")
            $proc = Start-Process -FilePath $curl -ArgumentList $curlArgs -PassThru -WindowStyle Hidden
            $null = $proc.Handle   # keeps ExitCode readable after the process exits
            $Sync.ChildPid = $proc.Id   # lets the app stop the download if it is closed
            Set-Status "Downloading $($Download.FileName)..."
            while (-not $proc.HasExited) {
                if ($total -and (Test-Path -LiteralPath $part)) {
                    $done = (Get-Item -LiteralPath $part).Length
                    $Sync.Status = 'Downloading {0}... {1:N1} of {2:N1} GB' -f $Download.FileName, ($done / 1GB), ($total / 1GB)
                    Set-ByteProgress $done $total
                }
                Start-Sleep -Milliseconds 700
            }
            if ($proc.ExitCode -ne 0) {
                throw "The download stopped (curl error $($proc.ExitCode)). Check the internet connection and click Install again; it will pick up where it left off."
            }
        }
    }
    Move-Item -LiteralPath $part -Destination $Path -Force
}

function Get-Iso($Download, [string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if (-not $Download.Sha256 -or (Test-Sha256 $Path $Download.Sha256)) {
            Write-Log "Using the copy already in $Path"
            return
        }
        Write-Log 'The file already downloaded is damaged; downloading it again.'
        Remove-Item -LiteralPath $Path -Force
    }
    Invoke-Download $Download $Path
    if ($Download.Sha256) {
        if (-not (Test-Sha256 $Path $Download.Sha256)) {
            Remove-Item -LiteralPath $Path -Force
            throw 'The downloaded file is damaged (checksum does not match). Click Install to download it again.'
        }
        Write-Log 'Checksum matches the official one.'
    } else {
        Write-Log 'This project does not publish a checksum. The file came over a secure HTTPS connection from its official server.'
    }
}
