Param
(
    [String]
    $ServerUrl,

    [String]
    $PersonalAccessToken,

    [String]
    $PoolName,

    [String]
    $AgentName
)

function isNodeOne($ipAddress) {
    return $ipAddress -eq "10.0.0.4"
}

Start-Transcript -Path 'c:\logs\install-buildagent-ps1-transcript.txt'

$ipAddress = (Get-NetIPAddress | ? { $_.AddressFamily -eq "IPv4" -and ($_.IPAddress -match "10.0.0") }).IPAddress

if (isNodeOne($ipAddress)) {

    Write-Host "Installing build agent"
    Get-Date

    $CurDir = get-location
    mkdir c:\agent
    Set-Location c:\agent
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory("$CurDir\vsts-agent-win-x64-2.177.1.zip", "$PWD")

    .\config.cmd --unattended --url $ServerUrl --auth PAT --token $PersonalAccessToken --pool $PoolName --agent $AgentName --runasservice --replace

    Set-Location $CurDir

    Write-Host "Installing .net core 3.1 sdk "
    Get-Date

    ./dotnet-sdk-3.1.404-win-x64.exe /install /quiet /norestart /log "c:\logs\Dotnet Core SDK 3.1.404.log"

    Write-Host "Done installing .net core sdk "
    Get-Date

    Write-Host "Restarting build agent in one minute"

    Start-Process powershell -ArgumentList "-Command Start-Sleep -Seconds 60; Restart-Service -Name vstsagent.kognifai.GaloreSF1; Write-Host 'done restart agent'"

    Write-Host "Build agent done"
    Get-Date
}

Stop-Transcript
