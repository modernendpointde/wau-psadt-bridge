[CmdletBinding()]
param()

$psExecutable = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sysnative = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $sysnative) {
    $psExecutable = $sysnative
}

$invokeScript = Join-Path $PSScriptRoot 'Invoke-AppDeployToolkit.ps1'
$arguments = @(
    '-NoProfile'
    '-ExecutionPolicy','Bypass'
    '-WindowStyle','Hidden'
    '-File',('"{0}"' -f $invokeScript)
    '-DeploymentType','Install'
    '-DeployMode','Interactive'
    '-InvocationSource','Bootstrap'
)

$process = Start-Process -FilePath $psExecutable -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
exit $process.ExitCode
