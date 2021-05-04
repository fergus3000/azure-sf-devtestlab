Param
(
    [String]
    $ServerUrl,

    [String]
    $PersonalAccessToken,

    [String]
    $PoolName,

    [String]
    $AgentName,

    [int]
    $numClusterNodes
    )


function isNodeOne($ipAddress) {
    return $ipAddress -eq "10.0.0.4"
}

Start-Transcript -Path 'c:\logs\run-scripts-ps1-transcript.txt'

& ($PSScriptRoot + "\install-couchbase.ps1") -numClusterNodes $numClusterNodes

Write-Host "running install-buildagent.ps1 "
Get-Date

& ($PSScriptRoot + "\install-buildagent.ps1") -ServerUrl $ServerUrl -PersonalAccessToken $PersonalAccessToken -PoolName $PoolName -AgentName $AgentName
#Start-Process -FilePath "$PSScriptRoot\install-buildagent.ps1" -ArgumentList "-ServerUrl $ServerUrl -PersonalAccessToken $PersonalAccessToken -PoolName $PoolName -AgentName $AgentName" -PassThru -Wait
Write-Host "running install-couchbase.ps1"
Get-Date


Write-Host "done"

Stop-Transcript