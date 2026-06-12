param(
    [string]$OutputDirectory = "",
    [int]$Jobs = 8,
    [ValidateSet("arm64", "x86_64")]
    [string]$Architecture = "x86_64",
    [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $env:TEMP ("actiond-windows-llvm-" + [Guid]::NewGuid().ToString("N"))
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$ServerErrorLog = Join-Path $OutputDirectory "windows-actiond.err.log"
$ActiondBuildLog = Join-Path $OutputDirectory "llvm-tblgen-actiond.log"
$HostBuildLog = Join-Path $OutputDirectory "llvm-tblgen-windows-host.log"
$TimingSummary = Join-Path $OutputDirectory "windows-llvm-smoke-timings.md"

if ($Architecture -eq "arm64") {
    $GuestPlatform = "//platforms:linux_aarch64_musl"
    $LlvmPlatform = "@llvm//platforms:linux_arm64_musl"
    $ExecutionPlatform = "//e2e:actiond_linux_arm64_musl_exec"
    $KernelTarget = "//vm:linux_kernel.image"
    $KernelSuffix = ".Image"
    $InitramfsTarget = "//vm:initramfs_aarch64"
    $RuntimeTarget = "//runtimes:runtimes_squashfs_aarch64"
    $WindowsActiondTarget = "//cmd/windows-actiond:windows-actiond_windows_arm64"
    $WindowsActiondSuffix = "windows-actiond_windows_arm64.exe"
} else {
    $GuestPlatform = "//platforms:linux_x86_64_musl"
    $LlvmPlatform = "@llvm//platforms:linux_x86_64_musl"
    $ExecutionPlatform = "//e2e:actiond_linux_x86_64_musl_exec"
    $KernelTarget = "//vm:linux_kernel.vm_linux"
    $KernelSuffix = ".vmlinux"
    $InitramfsTarget = "//vm:initramfs_x86_64"
    $RuntimeTarget = "//runtimes:runtimes_squashfs_x86_64"
    $WindowsActiondTarget = "//cmd/windows-actiond:windows-actiond_windows_x86_64"
    $WindowsActiondSuffix = "windows-actiond_windows_x86_64.exe"
}

function Get-BazelFile([string[]]$Files, [string]$Suffix) {
    $Paths = @($Files | Where-Object { $_.EndsWith($Suffix) })
    if ($Paths.Count -ne 1) { throw "expected one Bazel file ending in ${Suffix}, got $($Paths.Count): $Paths" }
    $Path = $Paths[0].Trim()
    if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $RepoRoot $Path }
    $Path = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Bazel file does not exist: $Path" }
    return $Path
}

function Invoke-LlvmMeasurement(
    [string]$Name,
    [string]$OutputBase,
    [string]$BuildLog,
    [string[]]$BuildArguments
) {
    if (Test-Path $OutputBase) { Remove-Item -Recurse -Force $OutputBase }
    $CommonArguments = @(
        "-c", "opt",
        "--strip=always",
        "--stripopt=--strip-all",
        "--platforms=$LlvmPlatform",
        "--experimental_remote_downloader=",
        "--experimental_remote_downloader_local_fallback=true",
        "--noremote_cache_compression",
        "--noremote_accept_cached",
        "--jobs=$Jobs"
    ) + $BuildArguments

    $WarmupArguments = @(
        "--output_base=$OutputBase",
        "build", "//e2e:llvm_exec_warmup"
    ) + $CommonArguments
    Write-Host "Starting $Name LLVM exec-configuration warmup"
    & bazel @WarmupArguments
    if ($LASTEXITCODE -ne 0) { throw "$Name LLVM exec-configuration warmup failed" }

    $Arguments = @(
        "--output_base=$OutputBase",
        "build", "@llvm-project//llvm:llvm-tblgen"
    ) + $CommonArguments
    Write-Host "Starting $Name LLVM measurement"
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & bazel @Arguments 2>&1 | Tee-Object -FilePath $BuildLog | Out-Host
        $ExitCode = $LASTEXITCODE
    } finally {
        $Stopwatch.Stop()
    }
    & bazel "--output_base=$OutputBase" shutdown
    if ($LASTEXITCODE -ne 0) { throw "$Name Bazel shutdown failed" }
    if ($ExitCode -ne 0) { throw "$Name LLVM llvm-tblgen build failed" }

    $LogText = Get-Content -Raw $BuildLog
    $LogText = [regex]::Replace($LogText, "`e\[[0-9;]*m", "")
    $ElapsedMatches = [regex]::Matches($LogText, "Elapsed time: ([0-9.]+)s")
    if ($ElapsedMatches.Count -eq 0) { throw "$Name LLVM log does not contain Bazel elapsed time" }
    $BazelElapsedSeconds = [double]::Parse(
        $ElapsedMatches[$ElapsedMatches.Count - 1].Groups[1].Value,
        [Globalization.CultureInfo]::InvariantCulture
    )
    $ProcessMatches = [regex]::Matches($LogText, "(?m)^INFO: ([^\r\n]*processes:[^\r\n]*)")
    if ($ProcessMatches.Count -eq 0) { throw "$Name LLVM log does not contain Bazel process counts" }
    $ProcessSummary = $ProcessMatches[$ProcessMatches.Count - 1].Groups[1].Value
    return [PSCustomObject]@{
        BazelElapsedSeconds = $BazelElapsedSeconds
        WallElapsedSeconds = $Stopwatch.Elapsed.TotalSeconds
        ProcessSummary = $ProcessSummary
    }
}

function Get-BazelProcessCounts([string]$Name, [string]$Summary, [string]$ExecutionKind) {
    $TotalMatch = [regex]::Match($Summary, "^([0-9]+) processes")
    $ExecutedMatch = [regex]::Match($Summary, "([0-9]+) $ExecutionKind")
    if (-not $TotalMatch.Success -or -not $ExecutedMatch.Success) {
        throw "could not parse $Name process counts"
    }
    return [PSCustomObject]@{
        Total = [int]$TotalMatch.Groups[1].Value
        Executed = [int]$ExecutedMatch.Groups[1].Value
    }
}

function Stop-WindowsActiond {
    if ($script:Server) {
        if (-not $script:Server.HasExited) { Stop-Process -Id $script:Server.Id -Force }
        if (-not $script:Server.WaitForExit(30000)) { throw "windows-actiond did not exit" }
    }
    $script:Server = $null
    if ($script:VmwpIds.Count -gt 0) {
        $Deadline = [DateTime]::UtcNow.AddMinutes(2)
        do {
            $RemainingIds = @($script:VmwpIds | Where-Object {
                Get-Process -Id $_ -ErrorAction SilentlyContinue
            })
            if ($RemainingIds.Count -eq 0) { break }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $Deadline)
        if ($RemainingIds.Count -ne 0) {
            throw "vmwp processes did not exit after windows-actiond stopped: $RemainingIds"
        }
    }
    $script:VmwpIds = @()
}

Push-Location $RepoRoot
$Server = $null
$VmwpIds = @()
try {
    $BuildBuddyBesArguments = @()
    $BuildBuddyRemoteArguments = @()
    if ($env:BUILDBUDDY_API_KEY) {
        $BuildBuddyBesArguments += "--bes_header=x-buildbuddy-api-key=$env:BUILDBUDDY_API_KEY"
        $BuildBuddyRemoteArguments += "--remote_header=x-buildbuddy-api-key=$env:BUILDBUDDY_API_KEY"
    }

    $BuildArguments = @(
        "build",
        "--config=remote",
        "--remote_timeout=900",
        "--platforms=$GuestPlatform",
        $WindowsActiondTarget,
        $KernelTarget,
        $InitramfsTarget,
        $RuntimeTarget
    ) + $BuildBuddyBesArguments + $BuildBuddyRemoteArguments
    & bazel @BuildArguments
    if ($LASTEXITCODE -ne 0) { throw "$Architecture windows-actiond artifacts failed to build" }

    $CqueryExpression = "set($WindowsActiondTarget $KernelTarget $InitramfsTarget $RuntimeTarget)"
    $CqueryResult = & bazel cquery $CqueryExpression --output=files --bes_backend= --noshow_progress `
        --config=remote "--platforms=$GuestPlatform" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "bazel cquery failed: $CqueryResult" }
    $BazelFiles = @(
        $CqueryResult |
            ForEach-Object { $_.ToString() } |
            Where-Object { $_ -and -not $_.StartsWith("INFO:") }
    )
    $WindowsActiond = Get-BazelFile $BazelFiles $WindowsActiondSuffix
    $Kernel = Get-BazelFile $BazelFiles $KernelSuffix
    $Initramfs = Get-BazelFile $BazelFiles "initramfs.cpio.zst"
    $RuntimeImage = Get-BazelFile $BazelFiles ".sqfs"

    if ($BuildOnly) {
        $ExecutableOutput = (& $WindowsActiond 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $ExecutableOutput -notmatch "windows-actiond") {
            throw "$Architecture windows-actiond executable failed"
        }
        $Revision = (& git rev-parse HEAD).Trim()
        $Summary = @"
# Windows Artifact Build

- Revision: $Revision
- Architecture: $Architecture
- Windows executable: $WindowsActiondSuffix
- Result: all artifacts built in one Bazel command and the Windows executable ran successfully
- Hyper-V VM: not run because -BuildOnly was specified
"@
        Set-Content -Path $TimingSummary -Value $Summary
        Write-Host $Summary
        if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Summary }
        return
    }

    $VmRoot = Join-Path $OutputDirectory "vm"
    $VmCpus = [Math]::Max(1, [Math]::Min(4, [int]$env:NUMBER_OF_PROCESSORS))

    $Arguments = @(
        "serve-vm",
        "--listen=127.0.0.1:8998",
        "--root=$VmRoot",
        "--kernel=$Kernel",
        "--initramfs=$Initramfs",
        "--runtime-image=$RuntimeImage",
        "--cas-image-size-mib=8192",
        "--memory-mib=8192",
        "--cpus=$VmCpus",
        "--connect-timeout-ms=900000"
    )
    $VmwpBaselineIds = @((Get-Process -Name "vmwp" -ErrorAction SilentlyContinue).Id)
    $Server = Start-Process -FilePath $WindowsActiond -ArgumentList $Arguments -NoNewWindow -PassThru `
        -RedirectStandardError $ServerErrorLog

    $Deadline = [DateTime]::UtcNow.AddMinutes(16)
    do {
        if ($Server.HasExited) { throw "windows-actiond exited before accepting REAPI connections" }
        if ((Test-Path $ServerErrorLog) -and
            ((Get-Content -Raw $ServerErrorLog) -match "gRPC bridge listening on 127\.0\.0\.1:8998")) {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $Deadline)
    if ([DateTime]::UtcNow -ge $Deadline) { throw "windows-actiond did not open port 8998" }

    $VmwpIds = @(
        (Get-Process -Name "vmwp" -ErrorAction SilentlyContinue).Id |
            Where-Object { $VmwpBaselineIds -notcontains $_ }
    )
    $script:VmwpIds = $VmwpIds
    if ($VmwpIds.Count -eq 0) { throw "windows-actiond did not create a vmwp process" }

    $ActiondBuildArguments = @(
        "--host_platform=$LlvmPlatform",
        "--extra_execution_platforms=$ExecutionPlatform",
        "--remote_executor=grpc://127.0.0.1:8998",
        "--remote_cache=grpc://127.0.0.1:8998",
        "--remote_local_fallback=false",
        "--shell_executable=/bin/bash",
        "--spawn_strategy=remote",
        "--genrule_strategy=remote"
    ) + $BuildBuddyBesArguments
    $HostBuildArguments = @(
        "--remote_executor=",
        "--remote_cache=",
        "--spawn_strategy=local",
        "--genrule_strategy=local"
    ) + $BuildBuddyBesArguments

    $ActiondResult = Invoke-LlvmMeasurement `
        -Name "actiond" `
        -OutputBase (Join-Path $OutputDirectory "actiond-bazel-output-base") `
        -BuildLog $ActiondBuildLog `
        -BuildArguments $ActiondBuildArguments

    Stop-WindowsActiond

    $HostResult = Invoke-LlvmMeasurement `
        -Name "Windows host" `
        -OutputBase (Join-Path $OutputDirectory "windows-host-bazel-output-base") `
        -BuildLog $HostBuildLog `
        -BuildArguments $HostBuildArguments

    $ActiondCounts = Get-BazelProcessCounts "actiond" $ActiondResult.ProcessSummary "remote"
    $HostCounts = Get-BazelProcessCounts "Windows host" $HostResult.ProcessSummary "local"
    if ($ActiondCounts.Total -ne $HostCounts.Total -or $ActiondCounts.Executed -ne $HostCounts.Executed) {
        throw "actiond processes total=$($ActiondCounts.Total) executed=$($ActiondCounts.Executed); Windows host total=$($HostCounts.Total) executed=$($HostCounts.Executed)"
    }

    $ActiondBazel = $ActiondResult.BazelElapsedSeconds.ToString("0.000", [Globalization.CultureInfo]::InvariantCulture)
    $ActiondWall = $ActiondResult.WallElapsedSeconds.ToString("0.000", [Globalization.CultureInfo]::InvariantCulture)
    $HostBazel = $HostResult.BazelElapsedSeconds.ToString("0.000", [Globalization.CultureInfo]::InvariantCulture)
    $HostWall = $HostResult.WallElapsedSeconds.ToString("0.000", [Globalization.CultureInfo]::InvariantCulture)
    $Ratio = ($ActiondResult.BazelElapsedSeconds / $HostResult.BazelElapsedSeconds).ToString("0.000", [Globalization.CultureInfo]::InvariantCulture)
    $Revision = (& git rev-parse HEAD).Trim()
    $Summary = @"
# Windows LLVM Performance Comparison

- Generated: $([DateTime]::UtcNow.ToString("u"))
- Revision: $Revision
- Workload: @llvm-project//llvm:llvm-tblgen, warmup=//e2e:llvm_exec_warmup
- Architecture: $Architecture
- Target platform: $LlvmPlatform
- Build mode: -c opt --strip=always --stripopt=--strip-all
- VM CPUs: $VmCpus
- actiond input mode: actiondfs
- Comparison: actiond uses Linux $Architecture musl host tools in the Hyper-V guest; the Windows host uses default Windows host tools. This is an end-to-end comparison, not an executor-only comparison.

| Execution | Jobs | Bazel elapsed | Wall elapsed | Processes |
| --- | ---: | ---: | ---: | --- |
| actiond | $Jobs | ${ActiondBazel}s | ${ActiondWall}s | $($ActiondResult.ProcessSummary) |
| Windows host | $Jobs | ${HostBazel}s | ${HostWall}s | $($HostResult.ProcessSummary) |

actiond / Windows host Bazel elapsed ratio: ${Ratio}x

Both measurements use fresh Bazel output bases on the same Windows host.
"@
    Set-Content -Path $TimingSummary -Value $Summary
    Write-Host $Summary
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Summary }
    Write-Host "Windows LLVM smoke output: $OutputDirectory"
} finally {
    Stop-WindowsActiond
    Pop-Location
}
