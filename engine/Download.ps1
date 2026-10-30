# --- Official download sources -----------------------------------------

function Get-WebText([string]$Url) {
    for ($attempt = 1; ; $attempt++) {
        try {
            $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60).Content
            if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
            return $content
        } catch {
            if ($attempt -ge 3) { throw }
            Write-Log "Trying $Url again: $($_.Exception.Message)"
            Start-Sleep -Seconds 3
        }
    }
}

# The user's Downloads folder, wherever they have moved it.
function Get-DownloadFolder {
    $folder = try { (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path } catch { $null }
    if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { $folder = Join-Path $env:USERPROFILE 'Downloads' }
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $folder
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

# Refuses early rather than filling the drive and failing an hour in.
function Assert-DownloadRoom([string]$Path, [int64]$Total, [int64]$Done) {
    $needed = $(if ($Total) { $Total } else { 7GB }) - $Done + 1GB
    $root = [IO.Path]::GetPathRoot($Path)
    $free = ([IO.DriveInfo]$root).AvailableFreeSpace
    if ($free -lt $needed) {
        throw ('The download needs {0:N0} GB free on {1} and only {2:N0} GB is free. Free up some space, or download the ISO yourself and pick "Use an ISO file".' -f ($needed / 1GB), $root, ($free / 1GB))
    }
}

# curl.exe ignores Windows' proxy setting, so pass it on.
function Get-CurlProxy([string]$Url) {
    try {
        $proxy = [Net.WebRequest]::GetSystemWebProxy().GetProxy([uri]$Url)
        if ($proxy -and $proxy.AbsoluteUri -ne ([uri]$Url).AbsoluteUri) { $proxy.AbsoluteUri }
    } catch { }
}

function Get-CurlMessage([int]$Code) {
    switch ($Code) {
        { $_ -in 5, 6, 7 } { return "Couldn't reach the download server. Check the internet connection and click Install again; it will pick up where it left off." }
        23 { return "Couldn't save the download. Check the drive has free space and click Install again." }
        28 { return 'The download stalled. Check the internet connection and click Install again; it will pick up where it left off.' }
        { $_ -in 35, 60 } { return "A secure connection to the download server failed. Check this PC's date and time are correct, then click Install again." }
    }
    if ($Code -eq 22) { return 'The download server returned an error. It may be busy, or a proxy may be blocking it. Click Install again later; it will pick up where it left off.' }
    "The download stopped (curl error $Code). Check the internet connection and click Install again; it will pick up where it left off."
}

function Invoke-Curl([string]$Url, [string]$Part, [int64]$Total, [string]$Name) {
    # -C - resumes a half-finished download if Install is clicked again. The speed limit
    # ends a connection that has quietly died, which --retry then reopens.
    $curlArgs = @('-L', '--fail', '--silent', '--show-error', '--retry', '5', '--retry-delay', '5',
        '--connect-timeout', '30', '--speed-limit', '1024', '--speed-time', '120',
        '-C', '-', '-o', "`"$Part`"", "`"$Url`"")
    $proxy = Get-CurlProxy $Url
    if ($proxy) { $curlArgs = @('--proxy', "`"$proxy`"") + $curlArgs }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $proc = Start-Process -FilePath $curl -ArgumentList $curlArgs -PassThru -WindowStyle Hidden
    $null = $proc.Handle   # keeps ExitCode readable after the process exits
    $Sync.ChildPid = $proc.Id   # lets the app stop the download if it is closed
    Set-Status "Downloading $Name..."
    while (-not $proc.HasExited) {
        if ($Total -and (Test-Path -LiteralPath $Part)) {
            $done = (Get-Item -LiteralPath $Part).Length
            $Sync.Status = 'Downloading {0}... {1:N1} of {2:N1} GB' -f $Name, ($done / 1GB), ($Total / 1GB)
            Set-ByteProgress $done $Total
        }
        Start-Sleep -Milliseconds 700
    }
    $proc.ExitCode
}

function Test-ServerAnswers([string]$Url) {
    try { [void](Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 60); $true } catch { $false }
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
    $done = if (Test-Path -LiteralPath $part) { (Get-Item -LiteralPath $part).Length } else { 0 }
    # Bigger than the real file means it came from a different release.
    if ($total -and $done -gt $total) {
        Remove-Item -LiteralPath $part -Force
        $done = 0
    }
    Assert-DownloadRoom $Path $total $done

    if ($total -and $done -eq $total) {
        Write-Log 'Download already complete.'
    } elseif (-not (Test-Path (Join-Path $env:SystemRoot 'System32\curl.exe'))) {
        Set-Status "Downloading $($Download.FileName)..."
        Start-BitsTransfer -Source $Download.Url -Destination $part
    } else {
        $code = Invoke-Curl $Download.Url $part $total $Download.FileName
        # 22 and 33: the server refused to resume, usually because the partial file is already
        # whole or is from an older link. Start from zero once, but only if the server is
        # answering: 22 is also any HTTP error, and that shouldn't cost gigabytes of progress.
        if ($code -in 22, 33 -and (Test-Path -LiteralPath $part) -and (Test-ServerAnswers $Download.Url)) {
            Write-Log "The server would not resume the download (curl error $code); starting again."
            Remove-Item -LiteralPath $part -Force
            $code = Invoke-Curl $Download.Url $part $total $Download.FileName
        }
        if ($code -ne 0) { throw (Get-CurlMessage $code) }
    }

    $size = (Get-Item -LiteralPath $part).Length
    if ($total -and $size -ne $total) {
        Remove-Item -LiteralPath $part -Force
        throw ('The download came out the wrong size ({0:N0} bytes, expected {1:N0}). Click Install to download it again.' -f $size, $total)
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
