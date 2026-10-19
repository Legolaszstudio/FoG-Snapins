# Automatically locate the .ppkg file in the directory where FOG extracts it
$PpkgPath = Join-Path -Path $PSScriptRoot -ChildPath "azure_join.ppkg"

# Install the package silently
Install-ProvisioningPackage -PackagePath $PpkgPath -ForceInstall -QuietInstall
