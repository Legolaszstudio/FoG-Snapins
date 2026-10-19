# Define the installer and paths
$installerName = "bambu-farm-manager-client-v3.0.0-8c114304-win32-x64.exe"
$installerPath = Join-Path -Path $PSScriptRoot -ChildPath $installerName
$logPath = "$env:TEMP\BambuFarmManager_Install.log"

# /S = Silent install (NSIS standard)
# /allusers = Forces system-wide installation (crucial since FOG runs as SYSTEM)
$installArgs = "/S /allusers"

"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Starting Bambu Farm Manager deployment..." | Out-File -FilePath $logPath -Append

# Verify the executable actually made it to the client machine
if (-not (Test-Path -Path $installerPath)) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - ERROR: Installer not found at $installerPath" | Out-File -FilePath $logPath -Append
    Exit 1
}

try {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Executing: $installerPath $installArgs" | Out-File -FilePath $logPath -Append
    
    # Run the installer and wait for it to finish
    $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru
    $exitCode = $process.ExitCode
    
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Installation finished with exit code: $exitCode" | Out-File -FilePath $logPath -Append
    
    # Pass the exact exit code back to FOG so the web UI reports Success/Failure accurately
    Exit $exitCode
}
catch {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - FATAL ERROR: $($_.Exception.Message)" | Out-File -FilePath $logPath -Append
    Exit 1
}