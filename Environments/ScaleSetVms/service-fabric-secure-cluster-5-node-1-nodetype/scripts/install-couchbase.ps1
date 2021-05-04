Param
(
    [int]
    $numClusterNodes
)

function Log ($text) {
    $ts = Get-Date -Format "o"
    Write-Output "$ts    $text"
    "$ts    $text" >> 'c:/logs/install-couhbase.txt'
}

function CreateLogsFolder {
    #make sure we have a log folder
    $LogFolder = 'c:\logs'
    if (!(Test-Path -Path $LogFolder )) {
        New-Item -ItemType directory -Path $LogFolder
    }
}
function InstallCouchbase {

    #assume msi downloaded from in current folder
    #https://packages.couchbase.com/releases/6.5.1/couchbase-server-community_6.5.1-windows_amd64.msi
    $logFile = "c:\logs\cb-install.log"
    $MSIArguments = @(
        "/i"
        "couchbase-server-community_6.5.1-windows_amd64.msi"
        "/qn"
        "/norestart"
        "/L*v"
        $logFile
    )
    Start-Process "msiexec.exe" -ArgumentList $MSIArguments -Wait -NoNewWindow 

    New-NetFirewallRule -DisplayName "Couchbase" -Direction Inbound -Action Allow -Protocol TCP `
        -EdgeTraversalPolicy Allow `
        -LocalPort 4369, 8091-8096, 9100-9105, 9110-9118, 9119, 9120-9122, 9130, 9998, 9999, 11207, 11209, 11210, 11213, 18091-18094, 19130, 21100-21300
}

function isNodeOne($ipAddress) {
    return $ipAddress -eq "10.0.0.4"
}


function AddCouchbaseNode($ipAddress) {
    #passing headers as param failed
    $user = "Administrator"
    $pass = "password"
    $pair = "${user}:${pass}"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $base64 = [System.Convert]::ToBase64String($bytes)
    $basicAuthValue = "Basic $base64"
    $headers = @{ Authorization = $basicAuthValue }

    Invoke-WebRequest -Method POST `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/node/controller/rename `
        -Body ("hostname=" + $ipAddress) `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing

    #The quota and rename does not seem to matter on the secondary nodes

    #echo Configuring Couchbase cluster
    #curl -v -X POST http://127.0.0.1:8091/pools/default -d memoryQuota=1024 -d indexMemoryQuota=512
    Invoke-WebRequest -Method POST `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/pools/default `
        -Body "memoryQuota=1024&indexMemoryQuota=512" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing

    #echo Configuring Couchbase indexes
    #curl -v http://127.0.0.1:8091/node/controller/setupServices -d services=kv%2cn1ql%2Cindex
    Invoke-WebRequest -Method POST `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/node/controller/setupServices `
        -Body "services=kv%2cn1ql%2Cindex" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing

    # add this node to cluster
    $tries = 0
    $status = 0
    $body = "user=Administrator&password=password&services=kv%2cn1ql%2Cindex&hostname=" + $ipAddress
    do {
        Log('Trying to add node in 30s')
        Start-Sleep -s 15
        Log('Trying to add node in 15s')
        Start-Sleep -s 15

        $tries++

        Log("Trying to add node now, attempt $tries")

        try {
            $response = Invoke-WebRequest -Method POST `
                -Headers $headers `
                -Uri http://10.0.0.4:8091/controller/addNode `
                -Body $body `
                -ContentType application/x-www-form-urlencoded -UseBasicParsing

            Log($response)
            $status = $response.StatusCode
        }
        catch {
            Log('Exception: Failed to add node')
            Log("Exception: Failed to add node $response")
            $status = 0
        }

        
    } While (($tries -lt 30) -and ($status -ne 200) )
    
    Log('Checking if i am last') 
    # get info about added nodes
    #curl -v -u Administrator:couchbase http://cb1.local:8091/pools/nodes
    try {
        Log("Trying to get node info now, attempt $tries")
        $response = Invoke-WebRequest -Method GET `
            -Headers $headers `
            -Uri http://10.0.0.4:8091/pools/nodes `
            -ContentType application/x-www-form-urlencoded -UseBasicParsing
        $status = $response.StatusCode
        Log("Response was $response.StatusCode" )
    }
    catch {
        Log('Exception: Failed to get node info' )
        Log("Exception: Failed to get node info $response")
    }
    $nodesCount = 0
    if ($status -eq 200) {
        $json = $response | ConvertFrom-Json 
        $hash = @{}
        foreach ($property in $json.PSObject.Properties) {
            $hash[$property.Name] = $property.Value
        }
        $nodes = $hash['nodes']
        $nodesCount = $nodes.Count
        Log("Node count is $nodesCount" )
    }
    Log("Node count is $nodesCount" )

    if ($nodesCount -eq $numClusterNodes) {
        Log("Starting rebalance" )

        $nodesCount = 3
        $knownNodes = "knownNodes=ns_1@10.0.0.4"
        For ($i=1; $i -lt $nodesCount; $i++) {
            $ip = $i+4
            $knownNodes = "$knownNodes,ns_1@10.0.0.$ip"
        }

        # start rebalance
        #curl -v -X POST -u Administrator:password \
        #'http://192.168.0.77:8091/controller/rebalance'\
        #-d 'knownNodes=ns_1@192.168.0.77,ns_1@192.168.0.56'
        $response = Invoke-WebRequest -Method POST `
            -Headers $headers `
            -Uri http://10.0.0.4:8091/controller/rebalance `
            -Body $knownNodes `
            -ContentType application/x-www-form-urlencoded -UseBasicParsing

        Log("Starting rebalance result $response" )
    }
}

function ConfigureCouchbase ($ipAddress) {

    #passing headers as param failed
    $user = "Administrator"
    $pass = "password"
    $pair = "${user}:${pass}"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $base64 = [System.Convert]::ToBase64String($bytes)
    $basicAuthValue = "Basic $base64"
    $headers = @{ Authorization = $basicAuthValue }


    # Initialize disk paths for Node
    # curl -u Administrator:password -v -X POST http://[localhost]:8091/nodes/self/controller/settings
    #   -d path=[location]
    #   -d index_path=[location]
    # Invoke-WebRequest -Method POST `
    #    -Headers $headers `
    #    -Uri http://127.0.0.1:8091/nodes/self/controller/settings `
    #    -Body "path=[location]&index_path=[location]" `
    #    -ContentType application/x-www-form-urlencoded

    # Rename Node
    # curl -u Administrator:password -v -X POST http://[localhost]:8091/node/controller/rename 
    #   -d hostname=[localhost]
    Invoke-WebRequest -Method POST `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/node/controller/rename `
        -Body "hostname=10.0.0.4" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing

    # assign 1/3 memory to couchbase
    $PysicalMemory = Get-WmiObject -class "win32_physicalmemory" -namespace "root\CIMV2"
    [int] $megaBytes = (($PysicalMemory).Capacity |  Measure-Object -Sum).Sum / 1048576
    [int] $memoryQuota = $megaBytes / 2
    [int] $wfmsQuota = 256
    [int] $eventsQuota = 512
    [int] $tsQuota = $memoryQuota - $eventsQuota - $wfmsQuota

    #echo Configuring Couchbase cluster
    #curl -v -X POST http://127.0.0.1:8091/pools/default -d memoryQuota=1024 -d indexMemoryQuota=512
    Invoke-WebRequest -Method POST `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/pools/default `
        -Body "memoryQuota=$memoryQuota&indexMemoryQuota=512" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing

    #echo Configuring Couchbase indexes
    #curl -v http://127.0.0.1:8091/node/controller/setupServices -d services=kv%2cn1ql%2Cindex
    Invoke-WebRequest -Method POST `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/node/controller/setupServices `
        -Body "services=kv%2cn1ql%2Cindex" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing

    #echo Creating Couchbase admin user
    #curl -v http://127.0.0.1:8091/settings/web -d port=8091 -d username=Administrator -d password=password
    Invoke-WebRequest -Method POST `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/settings/web `
        -Body "port=8091&username=Administrator&password=password" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing

    #echo Creating Couchbase buckets
    #curl -v -u Administrator:password -X POST http://127.0.0.1:8091/pools/default/buckets -d name=wfms -d replicaIndex=0 -d flushEnabled=1 -d bucketType=couchbase -d ramQuotaMB=256 -d authType=sasl -d saslPassword=password
    Invoke-WebRequest -Method POST `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/pools/default/buckets `
        -Body "name=wfms&replicaIndex=0&flushEnabled=1&bucketType=couchbase&ramQuotaMB=$wfmsQuota&authType=sasl&saslPassword=password" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing
    #curl -v -u Administrator:password -X POST http://127.0.0.1:8091/pools/default/buckets -d name=timeseries -d replicaIndex=0 -d flushEnabled=1 -d bucketType=couchbase -d ramQuotaMB=512 -d authType=sasl -d saslPassword=password
    Invoke-WebRequest -Method POST `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/pools/default/buckets `
        -Body "name=timeseries&replicaIndex=0&flushEnabled=1&bucketType=couchbase&ramQuotaMB=$tsQuota&authType=sasl&saslPassword=password" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing
    #curl -v -u Administrator:password -X POST http://127.0.0.1:8091/pools/default/buckets -d name=events -d replicaIndex=0 -d flushEnabled=1 -d bucketType=couchbase -d ramQuotaMB=256 -d authType=sasl -d saslPassword=password
    Invoke-WebRequest -Method POST `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/pools/default/buckets `
        -Body "name=events&replicaIndex=0&flushEnabled=1&bucketType=couchbase&ramQuotaMB=$eventsQuota&authType=sasl&saslPassword=password" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing

    #echo Creating Couchbase bucket users
    #curl -X PUT --data "name=wfms&roles=bucket_full_access[wfms]&password=wfmswfms" -H "Content-Type: application/x-www-form-urlencoded" http://Administrator:password@127.0.0.1:8091/settings/rbac/users/local/wfms
    Invoke-WebRequest -Method PUT `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/settings/rbac/users/local/wfms `
        -Body "name=wfms&roles=bucket_full_access[wfms]&password=wfmswfms" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing
    #curl -X PUT --data "name=timeseries&roles=bucket_full_access[timeseries]&password=timeseries" -H "Content-Type: application/x-www-form-urlencoded" http://Administrator:password@127.0.0.1:8091/settings/rbac/users/local/timeseries
    Invoke-WebRequest -Method PUT `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/settings/rbac/users/local/timeseries `
        -Body "name=timeseries&roles=bucket_full_access[timeseries]&password=timeseries" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing
    #curl -X PUT --data "name=events&roles=bucket_full_access[events]&password=events" -H "Content-Type: application/x-www-form-urlencoded" http://Administrator:password@127.0.0.1:8091/settings/rbac/users/local/events         
    Invoke-WebRequest -Method PUT `
        -Headers $headers `
        -Uri http://127.0.0.1:8091/settings/rbac/users/local/events `
        -Body "name=events&roles=bucket_full_access[events]&password=events" `
        -ContentType application/x-www-form-urlencoded -UseBasicParsing
}

CreateLogsFolder 

Start-Transcript -Path 'c:\logs\install-couchbase-ps1-transcript.txt'

Get-Date -Format "o"

$hello = "Installing couchbase `n"

$hello >> 'c:/logs/install-couhbase.txt'

$ipAddress = (Get-NetIPAddress | ? { $_.AddressFamily -eq "IPv4" -and ($_.IPAddress -match "10.0.0") }).IPAddress
$ipAddress >> 'c:/logs/install-couhbase.txt'


InstallCouchbase

$user = "Administrator"
$pass = "password"
$pair = "${user}:${pass}"
$bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
$base64 = [System.Convert]::ToBase64String($bytes)
$basicAuthValue = "Basic $base64"
$headers = @{ Authorization = $basicAuthValue }

#TODO: failed to pass headers as param, fixit
# configure for all nodes
if (isNodeOne($ipAddress)) {
    ConfigureCouchbase($ipAddress)
}
else {
    addCouchbaseNode($ipAddress)
}

# prevent antimalware from scanning some folders
Set-MpPreference -ExclusionPath "C:\logs", "C:\Program Files\Couchbase\Server"

Stop-Transcript
