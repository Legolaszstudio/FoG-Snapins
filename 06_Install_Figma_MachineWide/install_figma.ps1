$Arguments = @(
    "/i",
    "`"$PSScriptRoot\Figma.msi`"",
    "ALLUSERS=1",
    "/qn",
    "/norestart",
    "/log",
    "`"$env:ProgramData\Figma_Install.log`""
)

$Process = Start-Process -FilePath "msiexec.exe" -ArgumentList $Arguments -Wait -PassThru

if ($Process.ExitCode -in 0, 3010) {
    Write-Output "Figma installed successfully (Exit Code: $($Process.ExitCode))."
} else {
    Write-Error "Figma installation failed with exit code $($Process.ExitCode). Check $env:ProgramData\Figma_Install.log for details."
}