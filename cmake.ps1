param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

# 如果是通过 cmd 调用（如 ps2exe 转换后的 exe），可能需要处理参数传递方式
# 但直接作为 ps1 运行时，参数应该已经正确传递

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

# 设置默认的详细日志环境变量
if (-not $env:CMAKE_WRAPPER_VERBOSE -or [string]::IsNullOrWhiteSpace($env:CMAKE_WRAPPER_VERBOSE)) {
    $env:CMAKE_WRAPPER_VERBOSE = "1"
}
$VerboseOn = $env:CMAKE_WRAPPER_VERBOSE -eq '1' -or $env:CMAKE_WRAPPER_VERBOSE.ToLower() -eq 'true'

function Write-Log($msg) { 
    if ($VerboseOn) { 
        Write-Host "[cmake-wrapper] $msg" -ForegroundColor Cyan
    } 
}

function First-Existing([string[]]$cands) {
    foreach ($p in $cands) { 
        if ($p -and (Test-Path $p)) { 
            return $p 
        } 
    }
    return $null
}

# 配置三套 cmake 路径（支持环境变量覆盖；否则使用相对脚本目录的默认位置）
$Cmake35 = if ($env:CMAKE3_5_PATH) { $env:CMAKE3_5_PATH } else {
    First-Existing @(
        (Join-Path $ScriptDir "cmake-3.5.2\bin\cmake.exe"),
        (Join-Path $ScriptDir "cmake-3.5.2.exe")
    )
}

$Cmake331 = if ($env:CMAKE3_31_PATH) { $env:CMAKE3_31_PATH } else {
    First-Existing @(
        (Join-Path $ScriptDir "cmake-3.31.8\bin\cmake.exe"),
        (Join-Path $ScriptDir "cmake3.exe"),
        (Join-Path $ScriptDir "cmake.exe")
    )
}

$Cmake41 = if ($env:CMAKE4_1_PATH) { $env:CMAKE4_1_PATH } else {
    First-Existing @(
        (Join-Path $ScriptDir "cmake-4.1.1\bin\cmake.exe"),
        "cmake.exe" # 落到 PATH
    )
}

# 工具/脚本/帮助/版本：直接用最新版
$specialModes = @("-E", "-P", "--help", "-help", "--version", "-version", "--build")
$hasSpecialMode = $false
foreach ($arg in $Args) {
    if ($specialModes -contains $arg) {
        $hasSpecialMode = $true
        break
    }
}

if ($hasSpecialMode) {
    Write-Log "Special mode (-E/-P/help/version/build) -> $Cmake41"
    & $Cmake41 @Args
    exit $LASTEXITCODE
}

# 无参数时，直接使用 4.1.1
if ($Args.Count -eq 0) {
    Write-Log "No relevant args -> cmake-4.1.1"
    & $Cmake41 @Args
    exit $LASTEXITCODE
}

# 推断源码目录：-S / -H / 位置参数 / 当前目录
$srcDir = $null
for ($i = 0; $i -lt $Args.Count; $i++) {
    if ($Args[$i] -eq "-S" -and ($i + 1) -lt $Args.Count) { 
        $srcDir = [IO.Path]::GetFullPath($Args[$i+1]); 
        break 
    }
}
if (-not $srcDir) {
    for ($i = 0; $i -lt $Args.Count; $i++) {
        if ($Args[$i] -eq "-H" -and ($i + 1) -lt $Args.Count) { 
            $srcDir = [IO.Path]::GetFullPath($Args[$i+1]); 
            break 
        }
    }
}
if (-not $srcDir) {
    foreach ($a in $Args) {
        if ($a -and ($a -notmatch '^-') -and (Test-Path $a)) {
            $p = [IO.Path]::GetFullPath($a)
            if (Test-Path (Join-Path $p "CMakeLists.txt")) { 
                $srcDir = $p; 
                break 
            }
        }
    }
}
if (-not $srcDir) {
    $p = (Get-Location).Path
    if (Test-Path (Join-Path $p "CMakeLists.txt")) { 
        $srcDir = $p 
    }
}

# 解析最低版本
$minVer = $null
if ($srcDir) {
    $cmakelists = Join-Path $srcDir "CMakeLists.txt"
    if (Test-Path $cmakelists) {
        $content = Get-Content -Raw -LiteralPath $cmakelists
        $m = [regex]::Match($content, '(?is)cmake_minimum_required\s*\(\s*VERSION\s+([0-9]+(?:\.[0-9]+){0,2})')
        if ($m.Success) { 
            $minVer = $m.Groups[1].Value.Trim() 
        }
        if (-not $minVer) {
            $m2 = [regex]::Match($content, '(?is)cmake_policy\s*\(\s*VERSION\s+([0-9]+(?:\.[0-9]+){0,2})')
            if ($m2.Success) { 
                $minVer = $m2.Groups[1].Value.Trim() 
            }
        }
    }
}

# 选择版本：根据新的版本选择策略
$chosen = $Cmake41  # 默认最新版
if ($minVer) {
    try {
        if ($minVer -notmatch '\.') { 
            $minVer = "$minVer.0" 
        }
        $v = [version]$minVer
        
        # 新版本选择逻辑
        if ($v.Major -lt 3 -or ($v.Major -eq 3 -and $v.Minor -lt 5)) {
            $chosen = $Cmake35
            Write-Log "Detected minimum $($v.Major).$($v.Minor) (<3.5) -> cmake-3.5.2"
        } elseif ($v.Major -lt 4) {
            $chosen = $Cmake331
            Write-Log "Detected minimum $($v.Major).$($v.Minor) (>=3.5 and <4.0) -> cmake-3.31.8"
        } else {
            $chosen = $Cmake41
            Write-Log "Detected minimum $($v.Major).$($v.Minor) (>=4.0) -> cmake-4.1.1"
        }
    } catch {
        Write-Log "Parse version '$minVer' failed; use latest"
        $chosen = $Cmake41
    }
} else {
    Write-Log "No minimum found; default to cmake-4.1.1 -> $Cmake41"
}

if (-not $chosen -or -not (Test-Path $chosen)) {
    Write-Error "Selected CMake not found: $chosen`nPlace cmake-3.5.2, cmake-3.31.8 or cmake-4.1.1 under $ScriptDir, or set CMAKE3_5_PATH / CMAKE3_31_PATH / CMAKE4_1_PATH."
    exit 1
}

Write-Log "Executing: $chosen $Args"
& $chosen @Args
exit $LASTEXITCODE