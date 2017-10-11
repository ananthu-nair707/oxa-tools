﻿##  Function: Log-Message
##
##  Purpose: Write a message to a log file
##
##  Input: 
##      Message          - string - message to write
##      LogType          - string - message type
##      Foregroundcolor  - string - color of the output for Log-Messageonly
##
##  Ouput: null
function Log-Message
{
    param(
            [Parameter(Mandatory=$false)][object]$Message,
            [Parameter(Mandatory=$false)][ValidateSet("Verbose","Output", "Host", "Error", "Warning")][string]$LogType="Host",
            [Parameter(Mandatory=$false)][string]$Foregroundcolor = "White",
            [Parameter(Mandatory=$false)][string]$Context = "",
            [Parameter(Mandatory=$false)][switch]$NoNewLine,
            [Parameter(Mandatory=$false)][switch]$ClearLine,
            [Parameter(Mandatory=$false)][switch]$SkipTimestamp,
            [Parameter(Mandatory=$false)][switch]$ClearLineAfter
         )

    
    # append header to identify where the call came from for debugging purposes
    if ($Context -ne "")
    {
        $Message = "$Context - $Message";
    }

    # if necessary, prepend a blank line
    if ($ClearLine -eq $true)
    {
        $logTime = [System.Environment]::NewLine
    }

    # prepend log time
    $logTime += "[$(get-date -format u)]";

    if($NoNewLine -eq $false -and $SkipTimestamp -eq $false)
    {
        $logLine = "$logTime :: $Message";
    }
    else
    {
        $logLine = $Message;
    }

    # if necessary, prepend a blank line
    if ($ClearLineAfter -eq $true)
    {
        $logTime += [System.Environment]::NewLine
    }

    switch($LogType)
    {
        "Verbose" {  Write-Verbose $logLine; }
        "Output"  {  Write-Output $logLine ; }
        "Host"    {  Write-Host $logLine -ForegroundColor $ForegroundColor -NoNewline:$NoNewLine; }
        "Error"   {  Write-Error $logLine; }
        "Warning" {  Write-Warning $logLine ; }
        default   {  Write-Host $logLine -ForegroundColor $ForegroundColor -NoNewline:$NoNewLine; }
    }
}

## Function: Capture-ErrorStack
##
## Purpose: 
##    Capture an exception error stack and return a formatted output 
##
## Input: 
##   ForceStop       stop script execution on error
##   GetOutput       indicator of whether or not to return the error output or print it to console
##
## Output:
##   formatted output
##
function Capture-ErrorStack
{
    param(
            [Parameter(Mandatory=$false)][switch]$ForceStop,
            [Parameter(Mandatory=$false)][switch]$GetOutput
         )

    if ($global:Error.Count -eq 0)
    {
        return
    }

    [int]$decoratorLength = 75;

    $lastError = $global:Error[0];
    $message1 = "Error [$($lastError.Exception.GetType().FullName)]:`r`n`r`n"
    $message1 += "$($lastError.Exception.Message)`r`n`r`n";

    $message2 = $lastError.Exception | format-list -force | Out-String;
    
    $errorMessage = "`r`n`r`n";
    $errorMessage += "#" * $decoratorLength;
    $errorMessage += "`r`nERROR ENCOUNTERED`r`n";
    $errorMessage += "#" * $decoratorLength;
    $errorMessage += "`r`n$($message1)";

    if ($message2 -ne "")
    {
        $errorMessage += "`r`n`r`n$($message2)";
    }

    if ($ForceStop)
    {
        Log-Message -Message $errorMessage -LogType Error;
    }
    else
    {
         Log-Message -Message $errorMessage;
    }

    if ($GetOutput)
    {
        return $errorMessage;
    }
}

## Function: Get-DirectorySeparator
##
## Purpose: 
##    Get the directory separator appropriate for the OS
##
## Input: 
##
## Output:
##   OS-specific directory separator
##
function Get-DirectorySeparator
{
    $separator = "/";
    if ($env:ComSpec)
    {
        $separator = "\"
    }

    return $separator
}

## Function: Update-RuntimeParameters
##
## Purpose: 
##    Update the runtime parameters
##
## Input: 
##   ParametersFile                   path to the file holding the deployment parameters (the parameters.json file)
##   ReplacementHash                  hash table of replacement key and value pairs
##
## Output:
##   updated arm deployment parameter file
##
function Update-RuntimeParameters
{
    param(
            [Parameter(Mandatory=$true)][string]$ParametersFile,
            [Parameter(Mandatory=$true)][hashtable]$ReplacementHash
         )

    # check if the file exists and resolve it's path
    $ParametersFile = Resolve-Path -Path $ParametersFile -ErrorAction Stop
    
    # create a temp file and perform the necessary template replacements
    $tempParametersFile = [System.IO.Path]::GetTempFileName();
    if ((Test-Path -Path $tempParametersFile) -eq $false)
    {
        throw "Could not create a temporary file"
    }

    Log-Message "Parameters File: $($ParametersFile)" -ClearLine;
    $parametersContent = gc $ParametersFile -Encoding UTF8
    foreach($key in $ReplacementHash.Keys)
    {
        # todo: track cases where search key is not found and provide notification that replacement was skipped
        Log-Message "Replacing '{$key}' with '$($ReplacementHash[ $key ])'"
        $parametersContent = $parametersContent -ireplace "{$key}", $ReplacementHash[ $key ];
    }

    # save the output
    [IO.File]::WriteAllText($tempParametersFile, $parametersContent);

    return $tempParametersFile
}

##  Function: Parse-Json
##
##  Purpose: Parse a json string and return its json object
##
##  Input: 
##      JsonString     - the json string
##
##  Ouput: the corresponding json object
##
function Parse-Json
{
    param(
            [Parameter(Mandatory=$true)][string]$jsonString
         )

    $jsonObject = $null;

    try
    {
        $jsonObject = ConvertFrom-Json -InputObject $jsonString;
    }
    catch
    {
        [string]$exception = $error[0].ToString()
        if (!$exception.contains("Conversion from JSON failed with error"))
        {
            # this is not a case where no data is returned or the json string is not valid
            throw
        }
    }

    return $jsonObject
}

##  Function: Process-SecretName
##
##  Purpose: Encode or Decode a keyvault secret name
##
##  Input: 
##      SecretName     - the secret name
##      Prefix         - the secret name prefix
##      Operation      - the operation to perform (Encode or Decode)
##      ProcessPrefix  - indicator for processing or not processing the prefix
##
##  Ouput: the secret name
function Process-SecretName
{
    param(
            [Parameter(Mandatory=$true)][string]$SecretName,
            [Parameter(Mandatory=$false)][string]$Prefix="",
            [Parameter(Mandatory=$true)][ValidateSet("Decode","Encode")][string]$Operation,
            [Parameter(Mandatory=$false)][switch]$ProcessPrefix
         )

    
    # Keyvault secret names are limited to alpha numeric values only
    # therefore, we have to perform some string replacements to ensure that we can setup the required secrets/keys
    [hashtable]$replacements = @{ "_" = "zzz";  "." = "yyy";}

    if ($Operation -eq "Encode")
    { 
        # perform the string replacements
        foreach ($key in $replacements.Keys)
        {
            $secretName = $secretName.replace($key, $replacements[$key]);
        }

        # add the configuration name prefix
        if ($ProcessPrefix -eq $true)
        {
            $secretName = "$($Prefix)$($secretName)"
        }
    }
    elseif ($Operation -eq "Decode")
    {
        # remove the configuration name prefix
        if ($ProcessPrefix -eq $false)
        {
            $secretName = $secretName.Replace($Prefix, "");
        }

        # reverse the string replacements
        foreach($key in $replacements.Keys)
        {
            $secretName = $secretName.replace($replacements[$key], $key);
        }
    }

    return $secretName;
}

## Function: Set-AzureSubscriptionContext
##
## Purpose: 
##   Set the cli context to the appropriate azure subscription after login
##
## Input: 
##   AzureSubscriptionId      the azure subscription id to set as current
##   IsCli2                   indicator of whether or not azure cli 2.0 is used
##
## Output:
##   nothing
##
function Set-AzureSubscriptionContext
{
    param(
            [Parameter(Mandatory=$true)][string]$AzureSubscriptionId,
            [Parameter(Mandatory=$false)][boolean]$IsCli2=$false
         )

    Log-Message "Setting execution context to the '$($AzureSubscriptionId)' azure subscription"

    if ($IsCli2)
    {
        $results = az account set --subscription $AzureSubscriptionId --output json | out-string
        if ($results.Length -gt 0)
        {
            throw "Could not set execution context to the '$($AzureSubscriptionId)' azure subscription"
        }
    }
    else
    {
        $results = azure account set  $AzureSubscriptionId  -vv --json | Out-String
        if (!$results.Contains("account set command OK"))
        {
            throw "Could not set execution context to the '$($AzureSubscriptionId)' azure subscription"
        }
    }
}

## Function: Authenticate-AzureRmUser
##
## Purpose: 
##    Authenticate the AAD user that will interact with KeyVault
##
## Input: 
##   AadWebClientId           the azure active directory web application client id
##   AadWebClientAppKey       the azure active directory web application key
##   AadTenantId              the azure active directory tenant id
##   IsCli2                   indicator of whether or not azure cli 2.0 is used
##
## Output:
##   nothing
##
function Authenticate-AzureRmUser
{
    param(
            [Parameter(Mandatory=$true)][string]$AadWebClientId,
            [Parameter(Mandatory=$true)][string]$AadWebClientAppKey,
            [Parameter(Mandatory=$true)][string]$AadTenantId,
            [Parameter(Mandatory=$false)][boolean]$IsCli2=$false
         )

    Log-Message "Logging in as service principal for '$($AadTenantId)'"
    if ($IsCli2)
    {
        $results = az login -u $AadWebClientId --service-principal --tenant $AadTenantId -p $AadWebClientAppKey --output json | Out-String
        if ($results.Contains("error"))
        {
            throw "Login failed"
        }
    }
    else
    {
        $results = azure login -u $AadWebClientId --service-principal --tenant $AadTenantId -p $AadWebClientAppKey -vv --json | Out-String
        if (!$results.Contains("login command OK"))
        {
            throw "Login failed"
        }
    }
}

## Function: Create-StorageContainer
##
## Purpose: 
##    Create a container in the specified storage account
##
## Input: 
##   StorageAccountName       name of the storage account
##   StorageAccountKey        access key for the specified storage account
##   StorageContainerName     name of the container to create within the specified storage account
##
## Output:
##   nothing
##
function Create-StorageContainer
{
    param(
            [Parameter(Mandatory=$true)][string]$StorageAccountName,
            [Parameter(Mandatory=$true)][string]$StorageAccountKey,
            [Parameter(Mandatory=$true)][string]$StorageContainerName
         )

    # get a storage context
    $storageContext = New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
    New-AzureStorageContainer -Name $StorageContainerName -Context $storageContext
}

## Function: Start-AzureCommand
##
## Purpose: 
##   one generic call for every wrapped Azure Cmdlet
##
## Input: 
##   InputParameters         Azure Cmdlet & Context Name
##
## Output:
##   nothing
##
function Start-AzureCommand
{
    param( [Parameter(Mandatory=$true)][hashtable]$InputParameters )

    # we will make one generic call for every wrapped Azure Cmdlet
    # With that approach, we unify the call pattern, retries & error handling
    # special error handling will still be the responsibility of the caller

    # the object we will return
    $response = $null;

    # we support individual function using custom maximum retries
    # right now, they are not all enabled (but wired to do so)
    [int]$MaxRetries = 3;
    if ($InputParameters.ContainsKey("MaxRetries"))
    {
        try
        {
            $MaxRetries = [int]$InputParameters['MaxRetries'];
        }
        catch{ }
    }

    # check the expected exceptions
    if ($InputParameters.ContainsKey('ExpectedException') -eq $false)
    {
        $InputParameters['ExpectedException'] = "";
    }

    # track the retries
    $retryAttempt = 1;
    while ($retryAttempt -le $MaxRetries)
    {
        try
        {
            Log-Message "Attempt [$($retryAttempt)|$($MaxRetries)] - $($InputParameters['Activity']) started." -Context $Context;
            # handle the commands appropriately
            switch ($InputParameters['Command']) 
            {
                "Find-AzureRmResource"
                {
                    $response = Find-AzureRmResource -ResourceGroupNameContains $InputParameters['ResourceGroupName'] -ResourceType $InputParameters['ResourceType'] -Verbose ;  
                }
                
                "Get-AzureRmLoadBalancer"
                {
                    $response = Get-AzureRmLoadBalancer -Name $InputParameters['Name'] -ResourceGroupName $InputParameters['ResourceGroup'] -Verbose ;  
                }

                "Get-AzureRmLoadBalancerRuleConfig"
                {
                    $response = Get-AzureRmLoadBalancerRuleConfig -LoadBalancer $InputParameters['LoadBalancer'] -Verbose;
                }

                "Remove-AzureRmLoadBalancerRuleConfig"
                {
                    $response = Remove-AzureRmLoadBalancerRuleConfig -Name $InputParameters['Name'] -LoadBalancer $InputParameters['LoadBalancer'] -Verbose;
                }

                "Set-AzureRmLoadBalancer"
                {
                    $response = Set-AzureRmLoadBalancer -LoadBalancer $InputParameters['LoadBalancer'] -Verbose;
                }

                "Get-AzureRmVmss"
                {
                    $response = Get-AzureRmVmss -ResourceGroupName $InputParameters['ResourceGroup'] -Verbose;
                }
                
                "Remove-AzureRmVmss"
                {
                    $response = Remove-AzureRmVmss -ResourceGroupName $InputParameters['ResourceGroupName'] -VMScaleSetName $InputParameters['VMScaleSetName'] -Verbose;
                }
                 
                "Remove-AzureRmLoadBalancerBackendAddressPoolConfig"
                {
                    $response = Remove-AzureRmLoadBalancerBackendAddressPoolConfig -LoadBalancer $InputParameters['LoadBalancer'] -Name $InputParameters['Name'] -Verbose;
                }
                                 
                "Remove-AzureRmLoadBalancerFrontendIpConfig"
                {
                    $response = Remove-AzureRmLoadBalancerFrontendIpConfig -Name $InputParameters['Name'] -LoadBalancer $InputParameters['LoadBalancer'] -Verbose;
                }
                  
                "Remove-AzureRmLoadBalancer"
                {
                    $response = Remove-AzureRmLoadBalancer -ResourceGroupName $InputParameters['ResourceGroupName'] -Name $InputParameters['Name'] -Verbose -Force;
                }

                "Get-AzureRmPublicIpAddress"
                {
                    $response = Get-AzureRmPublicIpAddress -Name $InputParameters['Name'] -ResourceGroupName $InputParameters['ResourceGroupName'] -Verbose;
                }

                "Remove-AzureRmPublicIpAddress"
                {
                    $response = Remove-AzureRmPublicIpAddress -ResourceGroupName $InputParameters['ResourceGroupName'] -Name $InputParameters['Name'] -Verbose -Force;
                }

                "Get-AzureRmTrafficManagerProfile"
                {
                    $response = Get-AzureRmTrafficManagerProfile -Name $InputParameters['Name'] -ResourceGroupName $InputParameters['ResourceGroupName'] -Verbose ;
                }

                "New-AzureRmResourceGroupDeployment"
                {
                    $response = New-AzureRmResourceGroupDeployment -ResourceGroupName $InputParameters['ResourceGroupName'] -TemplateFile $InputParameters['TemplateFile'] -TemplateParameterFile $InputParameters['TemplateParameterFile'] -Force -Verbose
                }
                

                default 
                { 
                    throw "$($InputParameters['Command']) is not a supported call."; 
                    break; 
                }
            }            
            
            Log-Message "Attempt [$($retryAttempt)|$($MaxRetries)] - $($InputParameters['Activity']) completed." -Context $Context;
            break;
        }
        catch
        {
            # check for expected exceptions
            if (([string]$InputParameters['ExpectedException']).Trim() -ne "" -and ($_.Exception.Message -imatch $InputParameters['ExpectedException']))
            {
                # at this level, we don't do special handling for exceptions
                # Therefore, rethrowing the exception so the caller can handle it appropriately

                throw $_.Exception;
            }

            Capture-ErrorStack;

            # check if we have exceeded our retry count
            if ($retryAttempt -eq $MaxRetries)
            {
                # we have had 3 tries and failed when an error wasn't expected. throwing a fit.
                $errorMessage = "Azure Call Failure [$($InputParameters['Command'])]: $($InputParameters['Activity']) failed. Error: $($_.Exception.Message)";
                throw $errorMessage;
            }
        }

        $retryAttempt++;

        [int]$retryDelay = $env:RetryDelaySeconds;

        Log-Message -Message "Waiting $($retryDelay) seconds between retries" -Context $Context -Foregroundcolor Yellow;
        #Start-Sleep -Seconds $retryDelay;
    }

    return $response;    
}

#################################
# Wrapped function
#################################

<#
.SYNOPSIS
Get a list of Oxa network-related resources.

.DESCRIPTION
Get a list of Oxa network-related resources.

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the network resources

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
System.Array. Get-OxaNetworkResources returns an array of discovered azure network-related resource objects
#>
function Get-OxaNetworkResources
{
    param( 
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    $resourceTypes = @(
                         "Microsoft.Network/loadBalancers", 
                         "Microsoft.Network/publicIPAddresses",
                         "Microsoft.Network/trafficManagerProfiles"
                      );

    [array]$resourceList = $();
    
    foreach ($resourceType in $resourceTypes)
    {
        [hashtable]$parameters = @{'ResourceGroupNameEquals' = $ResourceGroupName; 'ResourceType' = $resourceType }
        
        # get the azure resources based on provided resourcetypes in the resourcegroup
        [array]$response = Find-OxaResource -ResourceGroupName $ResourceGroupName -ResourceType $resourceType -MaxRetries $MaxRetries;

        if($response -ne $null)
        {
            $resourceList += $response;
        }                               
    }

    return $resourceList;
}

#################################
# Wrapped Azure Cmdlets
#################################

<#
.SYNOPSIS
Finds the specfied azure resource.

.DESCRIPTION
Finds the specfied azure resource.

.PARAMETER ResourceGroupName
Name of the azurer resource group containing the network resources

.PARAMETER ResourceType
Specifies the type of azure resource resource

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
System.Array. Find-OxaResource returns an array of discovered azure resource objects of the specified type
#>
function Find-OxaResource
{
    param(
            [Parameter(Mandatory=$true)][object]$ResourceGroupName,
            [Parameter(Mandatory=$true)][object]$ResourceType,
            [Parameter(Mandatory=$false)][string]$Context="Finding OXA Azure resources",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "ResourceGroupName" = $ResourceGroupName;
                                        "ResourceType" = $ResourceType;
                                        "Command" = "Find-AzureRmResource";
                                        "Activity" = "Fetching all azure resources of '$($ResourceType)' type from resource group '$($ResourceGroupName)'"
                                        "ExecutionContext" = $Context;
                                        "MaxRetries" = $MaxRetries;
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Gets the disabled azure traffic manager endpoint.

.DESCRIPTION
Gets the disabled azure traffic manager endpoint.

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the network resources

.PARAMETER ResourceList
Array of of discovered azure network-related resource objects

.PARAMETER TrafficManagerProfileSite
One of three expected traffic manager sites: lms, cms or preview

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
System.String. Get-OxaDisabledDeploymentSlot returns name of the identified disabled deployment slot (slot1, slot2 or null)
#>
function Get-OxaDisabledDeploymentSlot
{
    param(
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,    
            [Parameter(Mandatory=$true)][array]$ResourceList,
            [Parameter(Mandatory=$false)][ValidateSet("lms", "cms", "preview")][string]$TrafficManagerProfileSite="lms",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # Assign the slot names
    [hashtable]$trafficManagerEndpointNameMap = @{
                                                    "EndPoint1" = "endpoint1";
                                                    "EndPoint2" = "endpoint2";
                                                 };

    # the slot to target
    [string]$targetSlot = $null;

    Log-Message "$($ResourceList.Count) network resources identified." -ClearLineAfter;

    if ( $ResourceList.Count -eq 0 )
    {
        # at this point, no network resource has been provisioned. 
        # This suggests, DeploymentType=bootstrap. Therefore, default to targetSlot=slot1
        Log-Message "Defaulting to 'slot1' since no network resources was identified."
        $targetSlot = "slot1";
    }
    else
    {
        # There are three (3) TM profiles, each mapped to a site: lms, cms, preview.
        # The following are assumed about these profiles:
        #   1. all profiles have the same state (mix-mode is not supported)
        #   2. each profile has two (2) endpoints: endpoint1 & endpoint2 (one of which is live)

        try
        {
            Log-Message "Getting '$($TrafficManagerProfileSite)' traffic manager profile:";

            # Getting LMS traffic manager profile to identify the disabled slot
            $trafficManager = $resourceList -match "Microsoft.Network/trafficManagerProfiles" | Where-Object{ $_ -imatch $TrafficManagerProfileSite };

            if ( !$trafficManager )
            {
                throw "Traffic manager profile for '$($TrafficManagerProfileSite)' site was not found.";
                exit;
            }

            $trafficManagerProfile = Get-OxaTrafficManagerProfile -TrafficManagerProfileName $trafficManager.Name -ResourceGroupName $resourceGroupName -MaxRetries $MaxRetries;

            if ( !$trafficManagerProfile )
            {
                throw "Could not get the traffic manager profile object reference for '$($TrafficManagerProfileSite)'"
                exit;
            }

            # track number of endpoints (we expect 2 endpoints)
            [int]$endpointsCount = $trafficManagerProfile.Endpoints.Count

            if ( $endpointsCount -ne 2)
            {
                throw "The '$($TrafficManagerProfileSite)' traffic manager profile site is expected to have two (2) endpoints. $($endpointsCount) endpoint(s) found.";
                exit;
            }

            # iterate the endpoints
            foreach ( $endpoint in $trafficManagerProfile.Endpoints )
            {
                if ( $endpoint.EndpointMonitorStatus -eq "Disabled" )
                {           
                    if ( $endpoint.Name.Contains($trafficManagerEndpointNameMap['EndPoint1'] ))
                    {
                        $targetSlot="slot1";
                    }

                    if ( $endpoint.Name.Contains($trafficManagerEndpointNameMap['EndPoint2'] ))
                    {
                        $targetSlot="slot2";
                    }
                }
            }

            # if both slots are active
            if ( $endpointsCount -eq 2 -and $targetSlot -eq $null )
            {
                throw "All available slots are active!";
                exit;
            }
        }
        catch   
        {
            Capture-ErrorStack;
            throw "Error in identifying the traffic manager profile: $($_.Message)";
            exit;
        }

        if ( $endpointsCount -eq 2 -and !$targetSlot )
        {
            Log-Message "No disabled slot identified: first deployment to second slot detected. Defaulting to Slot 2!";
            $targetSlot = "slot1";
        }
    }

    return $targetSlot;
}

<#
.SYNOPSIS
Removes all rule configurations for an azure load balancer.

.DESCRIPTION
Removes all rule configurations for an azure load balancer.

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the network resources.

.PARAMETER LoadBalancer
Name of the load balancer

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
Microsoft.Azure.Commands.Network.Models.PSLoadBalancer. Remove-OxaLoadBalancerRuleConfigs returns an updated azure load balancer object.
#>
function Remove-OxaLoadBalancerRuleConfigs
{
    param(
            [Parameter(Mandatory=$false)][array]$LoadBalancerRules=@(),
            [Parameter(Mandatory=$true)][object]$LoadBalancer,
            [Parameter(Mandatory=$false)][string]$Context="Load Balancer Rules",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    foreach($rule in $loadBalancerRules)
    {
        Log-Message "Removing load balancer rule: $($rule.Name)"
        $LoadBalancer = Remove-OxaLoadBalancerRuleConfig -LoadBalancerRuleConfigName $rule.Name -LoadBalancer $LoadBalancer -Context $context
        
        # TODO: process the process and confirm success
        if (!$LoadBalancer)
        {
            throw "Unable to remove load balancer rule: $($rule.Name)"
        }
    }

    # at this point, all rules have been removed, now save/persist the loadbalancer settings
    # should save the loadbalancer setttings once we remove the rules from the loadbalancer settings
    return Set-OxaAzureLoadBalancer -LoadBalancer $LoadBalancer;
} 

<#
.SYNOPSIS
Get the VMSS name(s) from load balancer's backend address pool.

.DESCRIPTION
Get the VMSS name(s) from load balancer's backend address pool.

.PARAMETER VmssBackendAddressPools
Array of VMSS address pools from an azure load balancer

.OUTPUTS
System.Array. Get-VmssName returns an array of unique VMSS names from teh specified backend address pool.
#>
function Get-VmssName
{
    param( [Parameter(Mandatory=$true)][array]$VmssBackendAddressPools )

    $vmssNames = @();

    foreach( $backendPool in $VmssBackendAddressPools )
    {
        foreach( $backendIpConfiguration in $backendPool.BackendIpConfigurations )
        {
            $backendIpConfigurationParts = $backendIpConfiguration.Id.split("/");

            # the vmss name is at a fixed position in the Id of the backend configuration
            $vmssNames += $backendIpConfigurationParts[8];
        }
    }

    $uniqueVmssNames = $vmssNames | Select-Object -Unique

    return $uniqueVmssNames
}

<#
.SYNOPSIS
Remove an azure load balancer and all associated resources.

.DESCRIPTION
Remove an azure load balancer and all associated resources.

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the network resources.

.PARAMETER LoadBalancerName
Name of the load balancer to remove

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
System.Boolean. Remove-OxaDeploymentSlotResources returns a boolean indicator of whether or not the delete operation succeeded.
#>
function Remove-OxaNetworkLoadBalancerResource
{
    param(
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$true)][string]$LoadBalancerName,
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # Fetch the specified loadbalancer object
    $loadbalancer = Get-OxaLoadBalancer -Name $LoadBalancerName -ResourceGroupName $ResourceGroupName -MaxRetries $MaxRetries;

    if ( !$loadbalancer )
    {
        Log-Message "Could not get the specified load balancer: $($LoadBalancerName)"
        return
    }

    # Fetch the loadbalancer rules
    $loadBalancerRules = Get-OxaLoadBalancerRuleConfig -LoadBalancer $loadbalancer -MaxRetries $MaxRetries;
    Log-Message "Retrieved $($loadBalancerRules.Count) load balancer rule(s)"

    # 1. Remove the identified load balancer rules
    $loadbalancer = Remove-OxaLoadBalancerRuleConfigs -LoadBalancerRules $loadBalancerRules -LoadBalancer $loadbalancer -MaxRetries $MaxRetries;
    if ( !$loadbalancer )
    {
        throw "Could not removed the $($loadBalancerRules.Count) load balancer rule(s) retrieved."
    }

    # 2. Remove the VMSS in the backend pool of the specified load balancer (filter to the correct VMSS)
    [array]$vmssNamesToRemove = Get-VmssName -VmssBackendAddressPools $loadbalancer.BackendAddressPools;
    Log-Message "$($vmssToRemove.Count) VMSS(s) retrieved.";

    if ( $vmssNamesToRemove.Count -gt 0 )
    {
        $vmssToRemove = Get-OxaVmss -ResourceGroupName $ResourceGroupName -MaxRetries $MaxRetries | Where-Object { $vmssNamesToRemove.Contains($_.Name)};
        if ( $vmssToRemove )
        {
            Remove-OxaVmss -ResourceGroupName $ResourceGroupName -VMScaleSetName $vmssToRemove.Name -MaxRetries $MaxRetries;
        }
    }

    # 3. Remove the LoadBalancer Backend Pool
    Log-Message "$($loadbalancer.BackendAddressPools.Count) backend address pool(s) retrieved for '$($loadbalancer.Name)' loadbalancer.";
    $loadbalancer = Remove-OxaLoadBalancerBackendAddressPoolConfigs -LoadBalancerBackendPools $loadbalancer.BackendAddressPools -LoadBalancer $loadbalancer -MaxRetries $MaxRetries;

    if ( !$loadbalancer )
    {
        throw "Could not removed the $($loadBalancerRules.Count) load balancer backend address pool(s) retrieved.";
    }


    ############################################
    # 4. Remove the LoadBalancer Frontend Pool
    Log-Message "$($loadbalancer.FrontendIpConfigurations.Count) frontend address pool(s) retrieved for '$($loadbalancer.Name)' loadbalancer.";
    $loadbalancer = Remove-OxaLoadBalancerFrontEndIpConfigs -LoadBalancerFrontendIpConfigurations $loadbalancer.FrontendIpConfigurations -LoadBalancer $loadbalancer -MaxRetries $MaxRetries;

    if ( !$loadbalancer )
    {
        throw "Could not remove the $() load balancer frontend address configurations.";
    }
    
    ############################################
    # 5. Remove the LoadBalancer
    Remove-OxaLoadBalancer -ResourceGroupName $ResourceGroupName -Name $loadbalancer.Name  -MaxRetries $MaxRetries;

    return $true;
}


<#
.SYNOPSIS
Remove all frontend ip configurations for a load balancer.

.DESCRIPTION
Remove all frontend ip configurations for a load balancer.

.PARAMETER FrontendIpConfigurations
Array of FrontEnd Ip Configurations.

.PARAMETER LoadBalancer
Name of the load balancer.

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
System.Boolean. Remove-OxaDeploymentSlotResources returns a boolean indicator of whether or not the delete operation succeeded.
#>
function Remove-OxaLoadBalancerFrontEndIpConfigs
{
    param(
            [Parameter(Mandatory=$true)][array]$LoadBalancerFrontendIpConfigurations,
            [Parameter(Mandatory=$true)][object]$LoadBalancer,
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # TODO: exclude preview since it throws an unexpected error while attempting to delete it.
    # Investigate why.
    [array]$filteredFrontendIpConfigurations = $LoadBalancerFrontendIpConfigurations | Where-Object { $_.Name -inotmatch "preview" };
    Log-Message "Removing $($filteredFrontendIpConfigurations.count) frontend ip configurations."

    foreach ( $frontendIpConfiguration in $filteredFrontendIpConfigurations )
    {
        # Deleting the loadbalancerFrontendIP configurations
        $LoadBalancer = Remove-OxaLoadBalancerFrontendIpConfig -Name $frontendIpConfiguration.Name -LoadBalancer $LoadBalancer;
        if ( !$LoadBalancer )
        {
            throw "Unable to remove load balancer frontend ip configuration: $($frontendIpConfiguration.Name)";
        }
    }

    # should save the loadbalancer setttings once we remove the rules from the loadbalancer settings
    return Set-OxaAzureLoadBalancer -LoadBalancer $LoadBalancer;
}

<#
.SYNOPSIS
Remove all resources associated with an Oxa deployment slot.

.DESCRIPTION
Remove all resources associated with an Oxa deployment slot.

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the network resources.

.PARAMETER TargetDeploymentSlot
Name of the deployment slot to deploy to.

.PARAMETER ResourceList
Array of of discovered azure network-related resource objects.

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
System.Boolean. Remove-OxaDeploymentSlotResources returns a boolean indicator of whether or not the delete operation succeeded.
#>
function Remove-OxaDeploymentSlotResources
{
    param(
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$true)][ValidateSet("slot1", "slot2")][string]$TargetDeploymentSlot,
            [Parameter(Mandatory=$true)][array]$NetworkResourceList,
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # if there are no resource groups to delete, default to true
    $response = $($targetedResources.Count -eq 0)

    # Filter the resources based on the targeted slot
    [array]$targetedResources = $resourceList | Where-Object { $_.ResourceName.Contains($TargetDeploymentSlot) };
    Log-Message "$($targetedResources.Count) resources targeted for removal from '$($TargetDeploymentSlot)'" -ClearLine -ClearLineAfter

    # iterate the targeted resources
    foreach($resource in $targetedResources)
    {
        switch ( $resource.resourcetype )
        {  
            "Microsoft.Network/loadBalancers"
            {
                # TODO: handle response 
                $response = Remove-OxaNetworkLoadBalancerResource -LoadBalancerName $resource.Name -MaxRetries $MaxRetries -ResourceGroupName $ResourceGroupName;
            }

            "Microsoft.Network/publicIPAddresses"
            {
                # TODO: handle response 
                $requestResponse = Remove-OxaNetworkIpAddress -Name $resource.Name -ResourceGroupName $ResourceGroupName  -MaxRetries $MaxRetries;

                if ( $requestResponse )
                {
                    $response = $true;
                }
            }
        }

        if ( !$response )
        {
            throw "Unable to remove the specified resource: Name=$($resource.Name), Type=$($resource.resourcetype)";
        }
    }
    
    return $response
}

<#
.SYNOPSIS
Get a list of Oxa Azure load balancers

.DESCRIPTION
Get a list of Oxa Azure load balancers.

.PARAMETER Name
Name of the load balancer

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the load balancer

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
Microsoft.Azure.Commands.Network.Models.PSLoadBalancer. Get-OxaLoadBalancer returns an azure load balancer object.
#>
function Remove-OxaNetworkIpAddress
{       
    param(
            [Parameter(Mandatory=$true)][string]$Name,
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$false)][string]$Context="Load Balancer",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
        )

    return Remove-OxaPubicIpAddress -Name $Name -ResourceGroupName $ResourceGroupName; 
}

<#
.SYNOPSIS
Get a list of Oxa Azure load balancers

.DESCRIPTION
Get a list of Oxa Azure load balancers.

.PARAMETER Name
Name of the load balancer

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the load balancer

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
Microsoft.Azure.Commands.Network.Models.PSLoadBalancer. Get-OxaLoadBalancer returns an azure load balancer object.
#>
 function Get-OxaLoadBalancer
{
    param(
            [Parameter(Mandatory=$true)][string]$Name,
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$false)][string]$Context="Load Balancer",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "Name" = $Name
                                        "ResourceGroup" = $ResourceGroupName
                                        "Command" = "Get-AzureRmLoadBalancer";
                                        "Activity" = "Getting azure LoadBalancer '$($Name)'"
                                        "ExecutionContext" = $Context
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Gets the rule configuration for a load balancer.

.DESCRIPTION
Gets the rule configuration for a load balancer.

.PARAMETER LoadBalancer
Name of the load balancer

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
Microsoft.Azure.Commands.Network.Models.PSLoadBalancingRule. Get-OxaLoadBalancerRuleConfig returns an array of rules associated with a specified load balancer object.
#>
function Get-OxaLoadBalancerRuleConfig
{
    param(
            [Parameter(Mandatory=$true)][Object]$LoadBalancer,
            [Parameter(Mandatory=$false)][string]$Context="Load Balancer Rules",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "LoadBalancer" = $LoadBalancer
                                        "Command" = "Get-AzureRmLoadBalancerRuleConfig";
                                        "Activity" = "Getting azure LoadBalancerRules for '$($LoadBalancer.Name)'";
                                        "ExecutionContext" = $Context;
                                        "MaxRetries" = $MaxRetries;
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Gets a Traffic Manager profile.

.DESCRIPTION
Gets a Traffic Manager profile.

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the network resources

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
System.Array. Get-OxaNetworkResources returns an array of discovered azure network-related resource objects
#>
function Get-OxaTrafficManagerProfile
{
    param(
            [Parameter(Mandatory=$true)][string]$TrafficManagerProfileName,
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$false)][string]$Context="Traffic Manager Profile",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "Name" = $TrafficManagerProfileName;
                                        "ResourceGroupName" = $ResourceGroupName;
                                        "Command" = "Get-AzureRmTrafficManagerProfile";
                                        "Activity" = "Getting azure Traffic Manager profile for '$($TrafficManagerProfileName)' in '$($ResourceGroupName)'"
                                        "ExecutionContext" = $Context
                                        "MaxRetries" = $MaxRetries
                                   };
    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Removes a rule configuration for a load balancer.

.DESCRIPTION
Removes a rule configuration for a load balancer.

.PARAMETER LoadBalancerRuleConfigName
Name of the load balancer configuration.

.PARAMETER LoadBalancer
Azure load balancer object.

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
Microsoft.Azure.Commands.Network.Models.PSLoadBalancer. Remove-OxaLoadBalancerRuleConfig returns a load balancer object with updated configuration.
#>
function Remove-OxaLoadBalancerRuleConfig
{
    param(
            [Parameter(Mandatory=$true)][string]$LoadBalancerRuleConfigName,
            [Parameter(Mandatory=$true)][Object]$LoadBalancer,
            [Parameter(Mandatory=$false)][string]$Context="Load Balancer Rules",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "Name" = $LoadBalancerRuleConfigName
                                        "LoadBalancer" = $LoadBalancer
                                        "Command" = "Remove-AzureRmLoadBalancerRuleConfig";
                                        "Activity" = "Removing azure LoadBalancerRules from '$($LoadBalancerName)'"
                                        "ExecutionContext" = $Context
                                        "MaxRetries" = $MaxRetries
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Sets the goal state for a load balancer.

.DESCRIPTION
Sets the goal state for a load balancer.

.PARAMETER LoadBalancer
Azure load balancer object.

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
Microsoft.Azure.Commands.Network.Models.PSLoadBalancer. Set-OxaLoadBalancer returns a load balancer object with updated configuration.
#>
function Set-OxaAzureLoadBalancer
{
    param(
            [Parameter(Mandatory=$true)][Object]$LoadBalancer,
            [Parameter(Mandatory=$false)][string]$Context="Load Balancer Settings",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "LoadBalancer" = $LoadBalancer
                                        "Command" = "Set-AzureRmLoadBalancer";
                                        "Activity" = "Saving LoadBalancerRules for '$($LoadBalancer.Name)'"
                                        "MaxRetries" = $MaxRetries
                                        "ExecutionContext" = $Context
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Gets the properties of a VMSS.

.DESCRIPTION
Gets the properties of a VMSS.

.PARAMETER LoadBalancer
Azure load balancer object.

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
System.Object. Get-OxaVmss returns an azure Vmss and its properties.
#>
function Get-OxaVmss
{
    param(
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$false)][string]$Context="VMSS",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                       "ResourceGroup" = $ResourceGroupName
                                        "Command" = "Get-AzureRmVmss";
                                        "Activity" = "Fetching VMSS details from '$($ResourceGroupName)'";
                                        "ExecutionContext" = $Context;
                                        "MaxRetries" = $MaxRetries;
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Removes the VMSS or a virtual machine that is within the VMSS.

.DESCRIPTION
Removes the VMSS or a virtual machine that is within the VMSS.

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the network resources.

.PARAMETER VMScaleSetName
Name of the VMSS to remove.

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
None.
#>
function Remove-OxaVmss
{
    param(
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$true)][Object]$VMScaleSetName,
            [Parameter(Mandatory=$false)][string]$Context="VMSS",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "ResourceGroupName" = $ResourceGroupName;
                                        "VMScaleSetName" = $VMScaleSetName;
                                        "Command" = "Remove-AzureRmVmss";
                                        "Activity" = "Removing azure VMSS '$($VMScaleSetName)'";
                                        "ExecutionContext" = $Context;
                                        "MaxRetries" = $MaxRetries;
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Removes all backend address pool configurations from a load balancer.

.DESCRIPTION
Removes all backend address pool configurations from a load balancer.

.PARAMETER LoadBalancer
Specifies the load balancer that contains the backend address pool to remove.

.PARAMETER LoadBalancerBackendPools
Specifies an array of backend pools to remove.

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
Microsoft.Azure.Commands.Network.Models.PSLoadBalancer. Remove-OxaLoadBalancerBackendAddressPoolConfig returns an updated azure load balancer object.
#>
function Remove-OxaLoadBalancerBackendAddressPoolConfigs
{
    param(
            [Parameter(Mandatory=$true)][object]$LoadBalancer,
            [Parameter(Mandatory=$true)][array]$LoadBalancerBackendPools,
            [Parameter(Mandatory=$false)][string]$Context="Load Balancer",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
        )

    foreach( $backendPool in $LoadBalancerBackendPools )
    {
        $LoadBalancer = Remove-OxaLoadBalancerBackendAddressPoolConfig -LoadBalancer $LoadBalancer -Name $backendPool.Name -Context $Context -MaxRetries $MaxRetries;

        if ( !$LoadBalancer )
        {
            throw "Unable to remove load balancer backend address pool configuration: $($backendPool.Name)";
        }
    }

    # at this point, all rules have been removed, now save/persist the loadbalancer settings
    # should save the loadbalancer setttings once we remove the rules from the loadbalancer settings
    return Set-OxaAzureLoadBalancer -LoadBalancer $LoadBalancer;
}

<#
.SYNOPSIS
Removes a backend address pool configuration from a load balancer.

.DESCRIPTION
Removes a backend address pool configuration from a load balancer.

.PARAMETER LoadBalancer
Specifies the load balancer that contains the backend address pool to remove.

.PARAMETER Name
Specifies the name of the backend address pool that this cmdlet removes

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
Microsoft.Azure.Commands.Network.Models.PSLoadBalancer. Remove-OxaLoadBalancerBackendAddressPoolConfig returns an updated azure load balancer object.
#>
function Remove-OxaLoadBalancerBackendAddressPoolConfig
{
    param(
            [Parameter(Mandatory=$true)][object]$LoadBalancer,
            [Parameter(Mandatory=$true)][string]$Name,
            [Parameter(Mandatory=$false)][string]$Context="Load Balancer",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "LoadBalancer" = $LoadBalancer;
                                        "Name" = $Name;
                                        "Command" = "Remove-AzureRmLoadBalancerBackendAddressPoolConfig";
                                        "Activity" = "Removing azure Load balancer BackEnd Addressspool config '$($Name)'";
                                        "ExecutionContext" = $Context;
                                        "MaxRetries" = $MaxRetries;
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Removes a front-end IP configuration from a load balancer.

.DESCRIPTION
Removes a front-end IP configuration from a load balancer.

.PARAMETER LoadBalancer
Specifies the load balancer that contains the front-end IP configuration to remove.

.PARAMETER Name
Specifies the name of the front-end IP address configuration to remove.

.PARAMETER Context
Logging context that identifies the call.

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
Microsoft.Azure.Commands.Network.Models.PSLoadBalancer. Remove-OxaLoadBalancerFrontendIpConfig returns an updated azure load balancer object.
#>
function Remove-OxaLoadBalancerFrontendIpConfig
{
    param(
            [Parameter(Mandatory=$true)][string]$Name,
            [Parameter(Mandatory=$true)][Object]$LoadBalancer,
            [Parameter(Mandatory=$false)][string]$Context="Load Balancer Frontend",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "LoadBalancer" = $LoadBalancer;
                                        "Name" = $Name;
                                        "Command" = "Remove-AzureRmLoadBalancerFrontendIpConfig";
                                        "Activity" = "Removing azure Load balancer FrontEnd Ip config '$($Name)'";
                                        "ExecutionContext" = $Context;
                                        "MaxRetries" = $MaxRetries;
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Removes a backend address pool configuration from a load balancer.

.DESCRIPTION
Removes a backend address pool configuration from a load balancer.

.PARAMETER ResourceGroupName
Specifies the name of the resource group that contains the load balancer to remove.

.PARAMETER Name
Specifies the name of the load balancer to remove.

.PARAMETER Context
Logging context that identifies the call.

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
None.
#>
 function Remove-OxaLoadBalancer
{
    param(
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$true)][string]$Name,
            [Parameter(Mandatory=$false)][string]$Context="Load Balancer",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "Name" = $Name;
                                        "ResourceGroupName" = $ResourceGroupName;
                                        "Command" = "Remove-AzureRmLoadBalancer";
                                        "Activity" = "Removing azure Load balancer '$($Name)' from ResourceGroup $($ResourceGroupName)";
                                        "ExecutionContext" = $Context;
                                        "MaxRetries" = $MaxRetries;
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Gets a public IP address.

.DESCRIPTION
Gets a public IP address.

.PARAMETER ResourceGroupName
Specifies the name of the resource group that contains the public IP address that this cmdlet gets.

.PARAMETER Name
Specifies the name of the public IP address that this cmdlet gets.

.PARAMETER Context
Logging context that identifies the call.

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
Microsoft.Azure.Commands.Network.Models.PSPublicIpAddress. Get-OxaPubicIpAddress returns details for the specified public ip address azure resource.
#>
function Get-OxaPubicIpAddress
{
    param(
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$true)][string]$Name,
            [Parameter(Mandatory=$false)][string]$Context="Ip Address",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "ResourceGroupName" = $ResourceGroupName
                                        "Name" = $Name
                                        "Command" = "Get-AzureRmPublicIpAddress";
                                        "Activity" = "Fetching azure PublicIP Addresses from $($ResourceGroupName)"
                                        "ExecutionContext" = $Context
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Removes a public IP address.

.DESCRIPTION
Removes a public IP address.

.PARAMETER ResourceGroupName
Specifies the name of the resource group that contains the public IP address that this cmdlet removes.

.PARAMETER Name
Specifies the name of the public IP address that this cmdlet removes.

.PARAMETER Context
Logging context that identifies the call.

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
None.
#>
function Remove-OxaPubicIpAddress
{
    param(
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$true)][string]$Name,
            [Parameter(Mandatory=$false)][string]$Context="Ip Address",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "Name" = $Name;
                                        "ResourceGroupName" = $ResourceGroupName;
                                        "Command" = "Remove-AzureRmPublicIpAddress";
                                        "Activity" = "Removing azure PublicIP Address '$($Name)' from '$($ResourceGroupName)'";
                                        "ExecutionContext" = $Context;
                                        "MaxRetries" = $MaxRetries;
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Remove an Oxa deployment slot.

.DESCRIPTION
Remove an Oxa deployment slot.

.PARAMETER DeploymentType
A switch to indicate the deployment type (any of bootstrap, upgrade, swap, cleanup).

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the network resources.

.PARAMETER TargetDeploymentSlot
Name of the deployment slot to deploy to.

.PARAMETER ResourceList
Array of of discovered azure network-related resource objects.

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
System.Boolean. Remove-OxaDeploymentSlot returns a boolean indicator of whether or not the delete operation succeeded.
#>
function Remove-OxaDeploymentSlot
{
    param(
            [Parameter(Mandatory=$true)][ValidateSet("bootstrap", "upgrade", "swap", "cleanup")][string]$DeploymentType,
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$true)][ValidateSet("slot1", "slot2")][string]$TargetDeploymentSlot,
            [Parameter(Mandatory=$true)][array]$NetworkResourceList,
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
    )

    # execute the clean up if:
    #   1. Deployment Type = upgrade
    #   2. Deployment Type = swap & cloud type = test (bvt)

    #cleaning up the resources from the disabled slot (response will be processed by caller)
    return Remove-OxaDeploymentSlotResources -ResourceGroupName $ResourceGroupName -TargetDeploymentSlot $TargetDeploymentSlot -NetworkResourceList $NetworkResourceList -MaxRetries $MaxRetries;
}

<#
.SYNOPSIS
Gets the latest deployment version id from all available VMSS(s).

.DESCRIPTION
Gets the latest deployment version id from all available VMSS(s).

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the network resources.

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
System.String. Get-LatestVmssDeploymentVersionId returns a string value representing the latest deployment version id in the resource group.
#>
function Get-LatestVmssDeploymentVersionId
{
    param( 
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         ) 

    [array]$vmssList = Get-OxaVmss -ResourceGroupName $ResourceGroupName -MaxRetries $MaxRetries;

    # sort in descending order and select the first one (the most recent)
    $vmss = $vmssList | Sort-Object -Descending | Select-Object -First 1;

    # $vmss.Name has the format: {CLUSTER_NAME}-vmss-{DEPLOYMENTVERSIONID}
    # extract the deployment version id
    return $vmss.Name.Split('-') | Select-Object -Last 1;
}

## Function: Get-LatestChanges
##
## Purpose: 
##    Create a container in the specified storage account
##
## Input: 
##   BranchName       name of the branch
##   Tag        name of the Tag
##   enlistmentRootPath     path of the local repo
##   privateRepoGitAccount     github private account url
##
## Output:
##   nothing
function Get-LatestChanges
{
    param(      
             [Parameter(Mandatory=$true)][string]$BranchName,
             [Parameter(Mandatory=$false)][string]$Tag,
             [Parameter(Mandatory=$false)][string]$enlistmentRootPath,
             [Parameter(Mandatory=$false)][string]$privateRepoGitAccount                
          )           
                  
   if ( !(Test-Path -Path $enlistmentRootPath) )
   { 
       cd $enlistmentRootPath -ErrorAction SilentlyContinue;
       # Here we are assuming git is already installed and installed path has been set in environment path variable.
       # SSh key has to be configured with both github & git bash account to authenticate.
       # Clone TFD Git repository
       git clone git@github.com:Microsoft/oxa-tools.git -b $BranchName $enlistmentRootPath -q
   }

   cd $enlistmentRootPath
   
   if ( $tag -eq $null )
   {
       git checkout
       git pull           
   }
   else
   {
       git checkout $tag -q
   }
              
   if ( !(Test-Path -Path $enlistmentRootPath-"config" ))
   { 
       cd $enlistmentRootPath -ErrorAction SilentlyContinue;
       # Clone TFD Git repository
       git clone $privateRepoAccount -b $BranchName $enlistmentRootPath-"config" -q
   }
   cd $enlistmentRootPath-"config"

   if ( $tag -eq $null )
   {
       git checkout
       git pull
   }
    else
   {
       git checkout $tag -q
   }
}

## Function: Set-ScriptDefault
##
## Purpose: 
##    Validate parameter exists and log a message saying the default was set.
##
## Input: 
##   ScriptParamVal      supplied value of script parameter override if it is null or an empty string
##   ScriptParamName     name of script parameter being set to default value
##   DefaultValue        default value provided
##
## Output:
##   The DefaultValue parameter
##
function Set-ScriptDefault
{
    param(
            [Parameter(Mandatory=$true)][AllowEmptyString()][string]$ScriptParamVal,
            [Parameter(Mandatory=$true)][string]$ScriptParamName,
            [Parameter(Mandatory=$true)][string]$DefaultValue
         )

    $response = $ScriptParamVal
    if ($ScriptParamVal.Trim().Length -eq 0 -or $ScriptParamVal -eq $null)
    {        
        Log-Message "Falling back to default value: $($DefaultValue) for parameter $($ScriptParamName) since no value was provided"
        $response = $DefaultValue
    }

    return $response
}

## Function: Get-LocalCertificate
##
## Purpose: 
##    Find a certificate in the local cert store with the given subject
##
## Input: 
##   CertSubject  subject to search for in cert store
##
## Output:
##   The Certificate Thumbprint
##
function Get-LocalCertificate
{
    Param(        
            [Parameter(Mandatory=$true)][String] $CertSubject            
         )
        
    $cert = (Get-ChildItem cert:\CurrentUser\my\ | Where-Object {$_.Subject -match $CertSubject })
    
    if (!$cert)
    {
        throw "Could not find a certificate in the local store with the given subject: $($CertSubject)"
    }

    if ($cert -is [array])
    {
        $cert = $cert[0]
    }

    return $cert.Thumbprint
}

## Function: Get-JsonKeys
##
## Purpose: 
##    Return all top-level keys from a .json file
##
## Input: 
##   TargetPath  Path to .json file
##
## Output:
##   Array of top-level keys
##
function Get-KeyVaultKeyNames
{
    Param(        
            [Parameter(Mandatory=$true)][String] $TargetPath            
         )
        

    $keys = @()
    $json = Get-Content -Raw $TargetPath | Out-String | ConvertFrom-Json

    $json.psobject.properties | ForEach-Object {    
        $keys += $_.Name
    }    
    return $keys
}

<#
.SYNOPSIS
Gets the latest deployment version id from all available VMSS(s).

.DESCRIPTION
Gets the latest deployment version id from all available VMSS(s).

.PARAMETER DeploymentType
A switch to indicate the deployment type (any of bootstrap, upgrade, swap, cleanup).

.PARAMETER ResourceGroupName
Name of the Azure Resource group containing the network resources.

.PARAMETER DeploymentVersionId
Suggested deployment version id to use. This needs to be a timestamp in the following format: yyyyMMddHms

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
System.String. Get-DefaultDeploymentVersionId returns the appropriate default deployment version id for the resource group.
#>
function Get-DefaultDeploymentVersionId
{
    param( 
            [Parameter(Mandatory=$true)][ValidateSet("bootstrap", "upgrade", "swap", "cleanup")][string]$DeploymentType,
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$false)][string]$DeploymentVersionId="",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    $deploymentVersionIdFormat = "yyyyMMddHms";

    if ( $DeploymentType -ne "swap" )
    {
        # this covers: bootstrap, upgrade & cleanup
        # always default to the current timestamp for bootstrap & upgrade operations
        $DeploymentVersionId=$(get-date -f $deploymentVersionIdFormat);
    }
    else
    {
        # for swap operations, we have two options:
        # 1. if the user specified a DeploymentversionId, use it (do not change)
        # 2. if not, default to the most recently deployed VMSS based on the timestamp in its name
        if ( $DeploymentVersionId -eq "" )
        {
            $DeploymentVersionId = Get-LatestVmssDeploymentVersionId -ResourceGroupName $ResourceGroupName -MaxRetries $MaxRetries;
        }
        else 
        {
            # double check the value of the specified deployment version id (let any error bubble up)
            [datetime]::ParseExact($DeploymentVersionId, $deploymentVersionIdFormat, $null);
        }
    }

    return $DeploymentVersionId;
}

<#
.SYNOPSIS
Adds an Azure deployment to a resource group.

.DESCRIPTION
Adds an Azure deployment to a resource group.

.PARAMETER ResourceGroupName
Name of the azurer resource group containing the network resources

.PARAMETER TemplateFile
Specifies the full path of a JSON template file.

.PARAMETER TemplateParameterFile
Specifies the full path of a JSON file that contains the names and values of the template parameters.

.PARAMETER Context
Logging context that identifies the call

.PARAMETER MaxRetries
Maximum number of retries this call makes before failing. This defaults to 3.

.OUTPUTS
Microsoft.Azure.Commands.ResourceManager.Models.PSResourceGroupDeployment. New-OxaResourceGroupDeployment returns a resource group deployment object reflecting the status of the deployment.
#>
function New-OxaResourceGroupDeployment
{
    param(
            [Parameter(Mandatory=$true)][string]$ResourceGroupName,
            [Parameter(Mandatory=$true)][string]$TemplateFile,
            [Parameter(Mandatory=$true)][string]$TemplateParameterFile,
            [Parameter(Mandatory=$false)][string]$Context="Deploying",
            [Parameter(Mandatory=$false)][int]$MaxRetries=3
         )

    # prepare the inputs
    [hashtable]$inputParameters = @{
                                        "ResourceGroupName" = $ResourceGroupName;
                                        "TemplateFile" = $TemplateFile;
                                        "TemplateParameterFile" = $TemplateParameterFile;
                                        "Command" = "New-AzureRmResourceGroupDeployment";
                                        "Activity" = "Deploying OXA Stamp to '$($ResourceGroupName)'"
                                        "ExecutionContext" = $Context;
                                        "MaxRetries" = $MaxRetries;
                                   };

    # this call doesn't require special error handling
    return Start-AzureCommand -InputParameters $inputParameters;
}

<#
.SYNOPSIS
Gets the deployment completion message from all VMSS instances being deployed.

.DESCRIPTION
Gets the deployment completion message from all VMSS instances being deployed.

.PARAMETER ServiceBusNamespace
Name of the Azure Service bus resource

.PARAMETER ServiceBusQueueName
Name of the Azure Service bus Queue resource

.PARAMETER Saskey
Service bus authorization primary key

.PARAMETER SharedAccessPolicyName
Name of the shared access policy

.OUTPUTS
System.Array. Get-DeployymentStatus returns an array containing names of VMSS instances that have been successfully deployed.
#>
function Get-DeploymentStatus
{
    param(
            [Parameter(Mandatory=$true)][string]$ServiceBusNamespace,
            [Parameter(Mandatory=$true)][string]$ServiceBusQueueName,
            [Parameter(Mandatory=$true)][string]$Saskey,
            [Parameter(Mandatory=$false)][string]$SharedAccessPolicyName="RootManageSharedAccessKey"
         )

    # Log-Message "Receiving deployment status from $($ServiceBusNamespace)";
    $messages = @();

    # Rest api url to receive messages from Service bus queue
    # https://docs.microsoft.com/en-us/rest/api/servicebus/receive-and-delete-message-destructive-read
    $servicebusPeekLockRequestUrl = "https://$($ServiceBusNamespace).servicebus.windows.net/$($ServiceBusQueueName)/messages/head";
    
    # Generating SAS token to authenticate Service bus Queue to receive messages
    $authorizedSasToken = Get-SasToken -Saskey $Saskey -ServicebusPeekLockRequestUrl $servicebusPeekLockRequestUrl -SharedAccessPolicyName $SharedAccessPolicyName;

    if (!$authorizedSasToken)
    {
        throw "Could not generate a SAS Token."
    }

    # Assigning generated SAS token to Service bus rest api headers to authorize
    $headers = @{'Authorization'=$authorizedSasToken};
    
    # keep peeking until there is no message
    $getMessage = $true;

    while($getMessage)
    {
        # invoking service bus queue rest api message url : destructive read
        $messageQueue = Invoke-WebRequest -Method DELETE -Uri $servicebusPeekLockRequestUrl -Headers $Headers;

        if (![string]::IsNullOrEmpty($messageQueue.content))
        {
            $messages += $messageQueue.content;
        }       
        else
        {
            $getMessage = $false;
        }
    }

    # Return all messages retrieved.
    # We expect the message body to contain the name of the server being deployed
    return $messages;
}

<#
.SYNOPSIS
Generates the SAS token with Service bus rest api url.

.DESCRIPTION
Generates the SAS token with Service bus rest api url.

.PARAMETER Saskey
Service bus authorization primary key

.PARAMETER SharedAccessPolicyName
Name of the Azure Service bus authorization rule

.PARAMETER ServicebusPeekLockRequestUrl
Service bus rest api url to receive messages from the queue.

.OUTPUTS
System.String. Get-SasToken returns SAS token generated for Service bus rest api recieve message url.
#>
function Get-SasToken
{
    param(
            [Parameter(Mandatory=$true)][string]$Saskey,
            [Parameter(Mandatory=$true)][string]$ServicebusPeekLockRequestUrl,
            [Parameter(Mandatory=$false)][string]$SharedAccessPolicyName="RootManageSharedAccessKey"
        )

    #checking SASKey Value    
    $sasToken = $null;

    #Encoding Service Bus Name space Rest api messaging url
    $encodedResourceUri = [uri]::EscapeUriString($servicebusPeekLockRequestUrl)
    
    # Setting expiry (12 hours)
    $sinceEpoch = (Get-Date).ToUniversalTime() - ([datetime]'1/1/1970')
    $durationSeconds = 12 * 60 * 60
    $expiry = [System.Convert]::ToString([int]($sinceEpoch.TotalSeconds) + $durationSeconds)
    $stringToSign = $encodedResourceUri + "`n" + $expiry
    $stringToSignBytes = [System.Text.Encoding]::UTF8.GetBytes($stringToSign)

    #Encoding Service bus SharedAccess Primary key pulled from ARM template
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Saskey)

    #Encoding Signature by HMACSHA256
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
    $hashOfStringToSign = $hmac.ComputeHash($stringToSignBytes)

    $signature = [System.Convert]::ToBase64String($hashOfStringToSign)
    $encodedSignature = [System.Web.HttpUtility]::UrlEncode($signature)   

    #Generating SAS token
    $sasToken = "SharedAccessSignature sr=$encodedResourceUri&sig=$encodedSignature&se=$expiry&skn=$($SharedAccessPolicyName)";
    
    return $sasToken;
}

## Function: New-AzureRMLoginCertificate
##
## Purpose: 
##    Create a certificate associated with a Service Principal 
##    for logging in to Powershell AzureRM and accessing specified KeyVault
##
## Input: 
##   AzureSubscriptionName  Subscription to provide access to
##   ResourceGroupName      ResourceGroup to provide access to
##   ApplicationId          AAD application to create Service Principle for
##   KeyVaultName           Name of KeyVault instance to provide access to
##   CertSubject            Subject to search for in cert store
##   Cloud                  Cloud deploying to, used for setting defaults
##
## Output:
##   Nothing
##
function New-AzureRMLoginCertificate
{
    Param(
            [Parameter(Mandatory=$true)][String] $AzureSubscriptionName,
            [Parameter(Mandatory=$true)][String] $ResourceGroupName,
            [Parameter(Mandatory=$true)][String] $ApplicationId,
            [Parameter(Mandatory=$false)][String] $KeyVaultName="",
            [Parameter(Mandatory=$false)][String] $CertSubject="",
            [Parameter(Mandatory=$false)][ValidateSet("prod", "int", "bvt")][string]$Cloud="bvt"              
         )

    $SubscriptionId = Get-AzureRmSubscription -SubscriptionName $AzureSubscriptionName
    $Scope = "/subscriptions/" + $SubscriptionId
    Select-AzureRMSubscription -SubscriptionId $SubscriptionId
    (Get-AzureRmContext).Subscription
    
    $KeyVaultName = Set-ScriptDefault -ScriptParamName "KeyVaultName" `
                    -ScriptParamVal $KeyVaultName `
                    -DefaultValue "$($ResourceGroupName)-kv"
    
    $CertSubject = Set-ScriptDefault -ScriptParamName "CertSubject" `
                    -ScriptParamVal $CertSubject `
                    -DefaultValue "CN=$($cloud)-cert"
    
    # Get or create Self-Signed Certificate
    try 
    {
        $cert = (Get-ChildItem cert:\CurrentUser\my\ | Where-Object {$_.Subject -match $CertSubject })
        if (!$cert)
        {
            Log-Message "Creating new Self-Signed Certificate..."
            $cert = New-SelfSignedCertificate -CertStoreLocation "cert:\CurrentUser\My" -Subject $CertSubject -KeySpec KeyExchange
        }
        $certValue = [System.Convert]::ToBase64String($cert.GetRawCertData())    
    }
    catch
    {
        Capture-ErrorStack;
        throw "Error obtaining certificate: $($_.Message)";
        exit;
    }
    
    # Replace Service Principal with a new account using the Certificate obtained above
    try
    {
        $sp = Get-AzureRmADServicePrincipal -ServicePrincipalName $ApplicationId
        
        if ($sp -and $sp.Id)
        {
            Log-Message "Removing old Service Principal..."
            Remove-AzureRmADServicePrincipal -ObjectId $sp.Id
        }    
        
        Log-Message "Creating new Service Principal for Key Vault Access to: $($KeyVaultName)"
        $ServicePrincipal = New-AzureRMADServicePrincipal -ApplicationId $ApplicationId -CertValue $certValue -EndDate $cert.NotAfter -StartDate $cert.NotBefore
        Get-AzureRmADServicePrincipal -ObjectId $ServicePrincipal.Id
        
        # Sleep here for a few seconds to allow the service principal application to become active 
        # (should only take a couple of seconds normally)
        Sleep 15
        New-AzureRMRoleAssignment -RoleDefinitionName Contributor -ServicePrincipalName $ServicePrincipal.ApplicationId -Scope $Scope | Write-Verbose -ErrorAction Stop
    }
    catch
    {
        Capture-ErrorStack;
        throw "Error in removing old service principal, creating new Service Principal and assigning role in provided subscription: $($_.Message)";
        exit;
    }
    
    # Allow new Service Principal KeyVault access
    try
    {
        Log-Message "Setting Key Vault Access policy for Key Vault: $($KeyVaultName) and Service Principal: $($sp.Id)"
        Set-AzureRmKeyVaultAccessPolicy -VaultName $KeyVaultName `
                                        -ServicePrincipalName $ApplicationId -PermissionsToSecrets get,set,list `
                                        -ResourceGroupName $ResourceGroupName    
    }
    catch
    {
        Capture-ErrorStack;
        throw "Error adding access policy to allow new Service Principal to use Key Vault - $($KeyVaultName): $($_.Message)";
        exit;
    }
}

## Function: Set-KeyVaultSecretsFromFile
##
## Purpose: 
##    Set KeyVault secrets from a .json file. See /config/stamp/default/keyvault-params.json
##    file for example file. Need to be logged in with access to specified KeyVault
##
## Input: 
##   ResourceGroupName      ResourceGroupName where KeyVault is
##   KeyVaultName           Name of KeyVault instance to provide access to
##   CertSubject            Subject to search for in cert store
##   TargetPath             Path to .json file
##   Cloud                  Cloud deploying to, used for setting defaults
##
## Output:
##   Nothing
##
function Set-KeyVaultSecretsFromFile
{
    Param(
            [Parameter(Mandatory=$false)][String] $ResourceGroupName="",
            [Parameter(Mandatory=$false)][String] $KeyVaultName="",
            [Parameter(Mandatory=$false)][String] $CertSubject="",
            [Parameter(Mandatory=$false)][String] $TargetPath="",            
            [Parameter(Mandatory=$false)][ValidateSet("prod", "int", "bvt")][string] $Cloud="bvt"              
         )

    $KeyVaultName = Set-ScriptDefault -ScriptParamName "KeyVaultName" `
        -ScriptParamVal $KeyVaultName `
        -DefaultValue "$($ResourceGroupName)-kv"
     
    $CertSubject = Set-ScriptDefault -ScriptParamName "CertSubject" `
        -ScriptParamVal $CertSubject `
        -DefaultValue "CN=$($Cloud)-cert"
    
    $TargetPath = Set-ScriptDefault -ScriptParamName "TargetPath" `
        -ScriptParamVal $TargetPath `
        -DefaultValue "$($rootPath)/config/stamp/default/keyvault-params.json"
    
    $json = Get-Content -Raw $TargetPath | Out-String | ConvertFrom-Json
    Write-Host $json
    $json.psobject.properties | ForEach-Object { 

        Log-Message "Syncing $($_.Name) to KeyVault: $($KeyVaultName)"        

        if ($_.Value)
        {
            # Create a new secret
            $secretvalue = ConvertTo-SecureString $_.Value -AsPlainText -Force
                
            try
            {
                # Store the secret in Azure Key Vault
                Set-AzureKeyVaultSecret -VaultName $KeyVaultName -Name $_.Name -SecretValue $secretvalue
            }
            catch
            {
                Log-Message "Error Syncing Key: $($_.Name)"
                Capture-ErrorStack;
                throw $($_.Message)
            }
        }
        else
        {
            Log-Message "No value was set for key $($_.Name) in $($TargetPath)"
        }
    }
}
