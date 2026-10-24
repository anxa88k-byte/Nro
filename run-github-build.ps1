$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Lệnh '$Program $($Arguments -join ' ')' bị lỗi (mã $LASTEXITCODE)."
    }
}

function Read-TextWithTimeout {
    param([string]$Prompt, [string]$Default, [int]$TimeoutSeconds = 5)
    Write-Host $Prompt -NoNewline
    $buffer = New-Object System.Text.StringBuilder
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                Write-Host ""
                return $buffer.ToString()
            }
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($buffer.Length -gt 0) {
                    $buffer.Length--
                    Write-Host "`b `b" -NoNewline
                }
                continue
            }
            if (-not [char]::IsControl($key.KeyChar)) {
                [void]$buffer.Append($key.KeyChar)
                Write-Host $key.KeyChar -NoNewline
            }
        } else {
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ""
    if ($buffer.Length -gt 0) { return $buffer.ToString() }
    Write-Host "Hết thời gian: tự động dùng tên mặc định '$Default'."
    return $Default
}

$statusFile = Join-Path $PSScriptRoot ".ipa-forge-status.json"
$script:jobInfo = $null
$script:jobProgress = 0
$script:buildSucceeded = $false
if (Test-Path -LiteralPath $statusFile) {
    try { $script:jobInfo = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json } catch { $script:jobInfo = $null }
}
function Set-JobStatus {
    param(
        [string]$State,
        [string]$Message,
        [int]$Progress = -1,
        [string]$RunId = "",
        [string]$Repo = "",
        [string]$DownloadPath = ""
    )
    if (-not $script:jobInfo) { return }
    $script:jobInfo.state = $State
    $script:jobInfo.message = $Message
    if ($Progress -ge 0) { $script:jobProgress = $Progress }
    $script:jobInfo.progress = $script:jobProgress
    $script:jobInfo.updated_at = [DateTimeOffset]::Now.ToString("o")
    if ($State -in @("completed", "failed") -and -not $script:jobInfo.finished_at) {
        $script:jobInfo.finished_at = [DateTimeOffset]::Now.ToString("o")
    }
    if ($RunId) { $script:jobInfo.run_id = $RunId }
    if ($Repo) { $script:jobInfo.repo = $Repo }
    if ($State -in @("queued", "running", "downloading", "completed") -and -not $script:jobInfo.started_at) {
        $script:jobInfo.started_at = [DateTimeOffset]::Now.ToString("o")
    }
    if ($DownloadPath) {
        $script:jobInfo.download_path = $DownloadPath
        $script:jobInfo.download_ready = $true
    }
    $json = $script:jobInfo | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($statusFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

try {
$projectRoot = $PSScriptRoot
$defaultIpaName = if (Test-Path -LiteralPath (Join-Path $projectRoot ".ipa-forge-name")) { (Get-Content -LiteralPath (Join-Path $projectRoot ".ipa-forge-name") -Raw).Trim() } else { "ipa" }
Set-JobStatus -State "preparing" -Message "Đang kiểm tra Tool chuẩn bị Build." -Progress 3
$workflow = Join-Path $projectRoot ".github\workflows\ios-ipa.yml"
if (-not (Test-Path -LiteralPath $workflow)) {
    throw "Không tìm thấy workflow tại $workflow. Hãy chạy script từ thư mục xcode đã giải nén."
}

$git = Get-Command git -ErrorAction SilentlyContinue
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $git) { throw "Máy chưa cài Git. Hãy cài Git for Windows rồi chạy lại script." }
if ($gh) { $ghPath = $gh.Source } else { $ghPath = Join-Path $env:ProgramFiles "GitHub CLI\gh.exe" }
if (-not (Test-Path -LiteralPath $ghPath)) { throw "Máy chưa cài Tool. Hãy cài Tool rồi chạy lại job" }

# GitHub CLI checks can take longer than the short startup window. Mark the
# job active before making network calls so the website doesn't flag it stale.
Set-JobStatus -State "uploading" -Message "Đang kiểm tra kết nối GitHub và chuẩn bị project." -Progress 5
& $ghPath auth status
if ($LASTEXITCODE -ne 0) {
    throw "Tool chưa đăng nhập hoặc Token đã hết hạn"
}
Invoke-Checked $ghPath @("auth", "setup-git")
$marker = Join-Path $projectRoot ".ipa-forge-name"
$defaultIpaName = if (Test-Path -LiteralPath $marker) { (Get-Content -LiteralPath $marker -Raw).Trim() } else { "ipa" }
$ipaName = Read-TextWithTimeout -Prompt "Tên file IPA (Enter để dùng $defaultIpaName, tự động sau 5 giây): " -Default $defaultIpaName -TimeoutSeconds 5
if ([string]::IsNullOrWhiteSpace($ipaName)) { $ipaName = $defaultIpaName }
$ipaName = $ipaName -replace '\.[iI][pP][aA]$', ''
if ($ipaName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw "Tên IPA chỉ được có tối đa 64 ký tự chữ, số, dấu chấm, gạch ngang hoặc gạch dưới."
}

$login = (& $ghPath api user --jq '.login').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($login)) { throw "Không đọc được tài khoản Tool đang đăng nhập." }
$ownedRepoNames = @(& $ghPath repo list $login --limit 1000 --json name --jq '.[].name')
if ($LASTEXITCODE -ne 0) { throw "Không thể liệt kê repository của $login." }
$repoMarker = Join-Path $projectRoot ".ipa-forge-repo"
$repoName = $ipaName
$suffix = 2
while ($ownedRepoNames | Where-Object { $_ -ieq $repoName } | Select-Object -First 1) {
    $repoName = "$ipaName-$suffix"
    $suffix++
}
$defaultRepo = if (Test-Path -LiteralPath $repoMarker) { (Get-Content -LiteralPath $repoMarker -Raw).Trim() } else { "https://github.com/$login/$repoName" }
$repoInput = Read-TextWithTimeout -Prompt "Repository (Enter để dùng $defaultRepo, tự động sau 5 giây): " -Default $defaultRepo -TimeoutSeconds 5
if ([string]::IsNullOrWhiteSpace($repoInput)) { $repoInput = $defaultRepo }
$repo = $repoInput.Trim().TrimEnd('/') -replace '\.git$', ''
if ($repo -match '^https?://github\.com/') { $repo = $repo -replace '^https?://github\.com/', '' }
if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Repository không hợp lệ. Nhập dạng owner/repo hoặc link https://github.com/owner/repo."
}
Set-Content -LiteralPath $repoMarker -Value "https://github.com/$repo" -NoNewline -Encoding utf8
Set-JobStatus -State "uploading" -Message "Đang chuẩn bị File $repo." -Progress 8 -Repo $repo

$repoParts = $repo.Split('/')
$repoOwner = $repoParts[0]
$repoName = $repoParts[1]
$repoNames = @(& $ghPath repo list $repoOwner --limit 1000 --json name --jq '.[].name')
if ($LASTEXITCODE -ne 0) { throw "Không thể liệt kê repository của $repoOwner. Kiểm tra quyền Admin rồi chạy lại." }
$existingRepo = $repoNames | Where-Object { $_ -ieq $repoName } | Select-Object -First 1
if (-not $existingRepo) {
    $ownerType = (& $ghPath api "users/$repoOwner" --jq '.type').Trim()
    if ($LASTEXITCODE -ne 0) { throw "Không xác định được chủ sở hữu GitHub $repoOwner." }
    if ($ownerType -eq "User" -and $repoOwner -ine $login) {
        throw "Repository $repo chưa tồn tại. Tài khoản $login không thể tạo file dưới tài khoản cá nhân $repoOwner. Hãy đăng nhập bằng tài khoản $repoOwner hoặc đổi chủ sở hữu."
    }
    Write-Host "Đang tạo file riêng tư mới: $repo"
    Invoke-Checked $ghPath @("repo", "create", $repo, "--private", "--description", "Xcode project for IPA build")
} else {
    $permission = (& $ghPath repo view $repo --json viewerPermission --jq '.viewerPermission').Trim()
    if ($LASTEXITCODE -ne 0 -or $permission -notin @("WRITE", "MAINTAIN", "ADMIN")) {
        throw "Tài khoản hiện tại chỉ có quyền $permission với $repo. Hãy đăng nhập tài khoản có quyền ghi."
    }
}

$branch = "main"

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("ipa-forge-push-" + [guid]::NewGuid().ToString("N"))
try {
    Invoke-Checked $ghPath @("repo", "clone", $repo, $tempRoot)
    Invoke-Checked $git.Source @("-C", $tempRoot, "config", "user.name", $login)
    Invoke-Checked $git.Source @("-C", $tempRoot, "config", "user.email", "$login@users.noreply.github.com")

    Get-ChildItem -LiteralPath $projectRoot -Force | Where-Object { $_.Name -ne ".git" } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $tempRoot $_.Name) -Recurse -Force
    }

    Push-Location $tempRoot
    try {
        Invoke-Checked $git.Source @("add", ".")
        & $git.Source diff --cached --quiet
        $hasChanges = $LASTEXITCODE -ne 0
        if ($hasChanges) {
            Write-Host "Đang commit và đẩy project lên $repo nhánh $branch."
            Invoke-Checked $git.Source @("commit", "-m", "first commit")
            Invoke-Checked $git.Source @("branch", "-M", "main")
            Invoke-Checked $git.Source @("push", "-u", "origin", "main")
        } else {
            Write-Host "Xcode đã giống nội dung cần build."
        }
    } finally {
        Pop-Location
    }

    $dispatchStartedAt = [DateTimeOffset]::UtcNow.AddSeconds(-1)
    Set-JobStatus -State "queued" -Message "XCODE đã được đẩy lên Tool. Đang yêu cầu workflow build IPA." -Progress 16 -Repo $repo
    Invoke-Checked $ghPath @("workflow", "run", "ios-ipa.yml", "--repo", $repo, "--ref", $branch, "--field", "ipa_name=$ipaName")
    Write-Host "Đã yêu cầu GitHub Actions chạy Build iOS IPA với tên $ipaName."
    $actionsUrl = "https://github.com/$repo/actions"
    Write-Host "Workflow đã được gửi; theo dõi trạng thái tại trang IPA."

    Write-Host "Đang chờ Tool tạo lượt chạy workflow..."
    $runId = $null
    $runSearchDeadline = [DateTimeOffset]::UtcNow.AddMinutes(3)
    while (-not $runId -and [DateTimeOffset]::UtcNow -lt $runSearchDeadline) {
        $runsJson = (& $ghPath run list --workflow "ios-ipa.yml" --repo $repo --branch $branch --limit 20 --json databaseId,createdAt,event,headBranch) -join "`n"
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($runsJson)) {
            $runs = @($runsJson | ConvertFrom-Json)
            $matchingRun = $runs | Where-Object {
                $_.event -eq "workflow_dispatch" -and $_.headBranch -eq $branch -and
                [DateTimeOffset]::Parse($_.createdAt).ToUniversalTime() -ge $dispatchStartedAt
            } | Sort-Object createdAt -Descending | Select-Object -First 1
            if ($matchingRun) { $runId = [string]$matchingRun.databaseId }
        }
        if (-not $runId) { Start-Sleep -Seconds 5 }
    }
    if (-not $runId) { throw "Không tìm thấy lượt chạy workflow mới sau 3 phút. Mở trang Tool để kiểm tra." }

    Set-JobStatus -State "running" -Message "Tool đang build IPA." -Progress 20 -RunId $runId -Repo $repo
    Write-Host "Workflow #$runId đang chạy. PowerShell sẽ chờ đến khi build hoàn tất."
    while ($true) {
        $runJson = (& $ghPath run view $runId --repo $repo --json status,conclusion,jobs) -join "`n"
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($runJson)) { throw "Không đọc được tiến trình workflow #$runId." }
        $run = $runJson | ConvertFrom-Json
        $steps = @($run.jobs | ForEach-Object { $_.steps })
        $stepCount = $steps.Count
        $completedSteps = @($steps | Where-Object { $_.status -eq "completed" }).Count
        $progress = if ($stepCount -gt 0) { [Math]::Min(94, 20 + [Math]::Floor(74 * $completedSteps / $stepCount)) } else { 20 }
        if ($run.status -eq "completed") {
            if ($run.conclusion -ne "success") {
                Set-JobStatus -State "failed" -Message "Build thất bại: $($run.conclusion). Liên Hệ ADMIN để xem log." -Progress $progress -RunId $runId -Repo $repo
                throw "Tool build thất bại ($($run.conclusion)). Xem log tại $actionsUrl."
            }
            break
        }
        if (($run.status -eq "queued") -or ($run.status -eq "requested") -or ($run.status -eq "waiting")) {
            $state = "queued"
        } else {
            $state = "running"
        }
        $message = if ($state -eq "queued") { "Workflow đang chờ máy build." } else { "Tool đang build IPA ($completedSteps/$stepCount bước)." }
        Set-JobStatus -State $state -Message $message -Progress $progress -RunId $runId -Repo $repo
        Start-Sleep -Seconds 8
    }

    Set-JobStatus -State "downloading" -Message "Build thành công. Đang tải IPA Lên Server WEB." -Progress 96 -RunId $runId -Repo $repo
    $artifactRoot = Join-Path $projectRoot ".ipa-forge-artifacts"
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
    $artifactDir = Join-Path $artifactRoot $runId
    New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    Invoke-Checked $ghPath @("run", "download", $runId, "--repo", $repo, "--dir", $artifactDir)
    $ipaFiles = @(Get-ChildItem -LiteralPath $artifactDir -Filter "*.ipa" -File -Recurse)
    if ($ipaFiles.Count -eq 0) {
        Set-JobStatus -State "failed" -Message "Build xong nhưng Server không có file IPA." -Progress 100 -RunId $runId -Repo $repo
        Write-Host "Quy Trình đã xong nhưng Server không chứa file .ipa. Hãy liên Hệ Chủ WEB Để Xem Lỗi."
    } else {
        foreach ($ipaFile in $ipaFiles) {
            $destination = Join-Path $artifactRoot "$ipaName.ipa"
            Copy-Item -LiteralPath $ipaFile.FullName -Destination $destination -Force
            Write-Host "IPA sẵn sàng cho trang web: $destination"
        }
        # Leave the project folder free so the local service can clean it up.
        Set-Location -LiteralPath $env:TEMP
        Set-JobStatus -State "completed" -Message "Build hoàn tất. IPA đã sẵn sàng để tải." -Progress 100 -RunId $runId -Repo $repo -DownloadPath $destination
        $script:buildSucceeded = $true
        Write-Host "Mở trang IPA và nhấn Tải IPA để trừ 10.000đ từ số dư ví."
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
} catch {
    Set-JobStatus -State "failed" -Message $_.Exception.Message -Progress $script:jobProgress
    throw
}
if ($script:buildSucceeded) {
    Write-Host "Build đã hoàn tất 100%. APP sẽ tự đóng sau 30 giây."
    Start-Sleep -Seconds 30
    exit 0
}
