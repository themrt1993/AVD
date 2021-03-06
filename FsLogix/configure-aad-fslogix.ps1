function GetAuthToken($resource) {
    $context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
    $Token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, $resource).AccessToken
    $authHeader = @{
        'Content-Type' = 'application/json'
        Authorization  = 'Bearer ' + $Token
    }
    return $authHeader
}

$script:AzureUrl = "https://management.azure.com/"
$script:AzureToken = GetAuthToken -resource $script:AzureUrl

$script:graphWindowsUrl = "https://graph.windows.net"
$script:graphWindowsToken = GetAuthToken -resource $script:graphWindowsUrl

$Script:GraphApiUrl = "https://graph.microsoft.com"
$script:graphApiToken = GetAuthToken -resource $Script:GraphApiUrl 

$resourceGroupName = "RG-ROZ-STOR-01"
$location = "WestEurope"

$rgParameters = @{
    resourceGroupName = $resourceGroupName
    location          = $location 
}
$resourceGroup = New-AzResourceGroup @rgParameters

$storageAccountParameters = @{
    Name    = "fslogix$(Get-Random -max 10000)"
    SkuName = "Premium_LRS"
    Kind    = "FileStorage"
}
$storageAccount = $resourceGroup | New-AzStorageAccount @storageAccountParameters
$storageAccount 

$saShareParameters = @{
    Name       = "office"
    AccessTier = "Premium"
    QuotaGiB   = 1024
}
$saShare = $storageAccount | New-AzRmStorageShare @saShareParameters
$saShare

$guid = (new-guid).guid
$smbShareContributorRoleId = "0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb"
$roleDefinitionId = "/subscriptions/" + $(get-azcontext).Subscription.id + "/providers/Microsoft.Authorization/roleDefinitions/" + $smbShareContributorRoleId
$roleUrl = $script:AzureUrl + $storageAccount.id + "/providers/Microsoft.Authorization/roleAssignments/$($guid)?api-version=2018-07-01"
$roleBody = @{
    properties = @{
        roleDefinitionId = $roleDefinitionId
        principalId      = "f119eef3-fee6-44c6-a692-4d761eccaf7e" # AD Group ID
        scope            = $storageAccount.id
    }
}
$jsonRoleBody = $roleBody | ConvertTo-Json -Depth 6
Invoke-RestMethod -Uri $roleUrl -Method PUT -Body $jsonRoleBody -headers $script:AzureToken


# Kerberos enable
$Uri = $script:AzureUrl + $storageAccount.id + "?api-version=2021-04-01"
$kerbBody = 
@{
    properties = @{
        azureFilesIdentityBasedAuthentication = @{
            directoryServiceOptions = "AADKERB"
        }
    }
}
$kerbJsonBody = $kerbBody | ConvertTo-Json -Depth 99
try {
    Invoke-RestMethod -Uri $Uri -ContentType 'application/json' -Method PATCH -Headers $script:AzureToken -Body $kerbJsonBody;
}
catch {
    Write-Host $_.Exception.ToString()
    Write-Error -Message "Caught exception setting Storage Account directoryServiceOptions=AADKERB: $_" -ErrorAction Stop
} 



# Create app registration
$identifierURIs = [System.Collections.Arraylist]::New()
$identifierURIs.Add('HTTP/{0}.file.core.windows.net' -f $storageAccount.StorageAccountName) | Out-Null
$identifierURIs.Add('CIFS/{0}.file.core.windows.net' -f $storageAccount.StorageAccountName) | Out-Null
$identifierURIs.Add('HOST/{0}.file.core.windows.net' -f $storageAccount.StorageAccountName) | Out-Null
$url = $script:graphWindowsUrl + "/" + $(get-azcontext).Tenant.Id + "/applications?api-version=1.6"
# assign permissions
$permissions = @{
    resourceAppId  = "00000003-0000-0000-c000-000000000000"
    resourceAccess = @(
        @{
            id   = "37f7f235-527c-4136-accd-4a02d197296e" #open.id
            type = "Scope"
        },
        @{
            id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" #user.read
            type = "Scope"
        },
        @{
            id   = "14dad69e-099b-42c9-810b-d002981feec1" #profile
            type = "Scope"
        }
    )
}

$body = @{
    displayName            = $storageAccount.StorageAccountName
    GroupMembershipClaims  = "All"
    identifierUris         = $identifierURIs
    requiredResourceAccess = @(
        $permissions
    ) 
}
$postBody = $body | ConvertTo-Json -Depth 4
$application = Invoke-RestMethod -Uri $url -Method POST -Body $postBody -Headers $script:graphWindowsToken -UseBasicParsing

$url = $Script:GraphApiUrl + "/Beta/servicePrincipals"
$body = @{
    appId                = $application.appId
    ServicePrincipalType = "Application"
}
$postBody = $body | ConvertTo-Json
$newSp = Invoke-RestMethod -Uri $url -Method POST -Body $postBody -Headers $script:graphApiToken


$url = $Script:GraphApiUrl + "/Beta/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'"
$graphAggregatorServiceObjectId = (Invoke-RestMethod -Uri $url -Headers $script:graphApiToken).Value.id
$date = Get-Date
$url = $($Script:GraphApiUrl) + "/Beta/oauth2PermissionGrants"
$body = @{
    clientId    = $newSp.id
    consentType = "AllPrincipals"
    principalId = $null
    resourceId  = $graphAggregatorServiceObjectId
    scope       = "openid User.Read profile"
    startTime   = $date
    expiryTime  = $date
}
$postBody = $body | ConvertTo-Json
Invoke-RestMethod -Uri $url -Method POST -Body $postBody -Headers $script:graphApiToken


$keyName = "kerb1"
$storageAccount | New-AzStorageAccountKey -KeyName $keyName -ErrorAction Stop 
# Assign password to service principal
$kerbKey1 = $storageAccount | Get-AzStorageAccountKey -ListKerbKey | Where-Object { $_.KeyName -eq $keyName }
$aadPasswordBuffer = [System.Linq.Enumerable]::Take([System.Convert]::FromBase64String($kerbKey1.Value), 32);
$password = "kk:" + [System.Convert]::ToBase64String($aadPasswordBuffer);

$url = "https://graph.windows.net/" + $(get-azcontext).Tenant.id + "/servicePrincipals/" + $newSp.id + "?api-version=1.6"
$body = @{
    passwordCredentials = @(
        @{
            customKeyIdentifier = $null
            startDate           = [DateTime]::UtcNow.ToString("s")
            endDate             = [DateTime]::UtcNow.AddDays(365).ToString("s")
            value               = $password
        }
    )
}
$postBody = $body | ConvertTo-Json -Depth 6
Invoke-RestMethod -Uri $url -Method PATCH -Body $postBody -Headers $script:graphWindowsToken

$vm = Get-AzVM -name "vm-rz-dc001" -ResourceGroupName "rg-roz-avd-01"
$output = $vm | invoke-azvmruncommand -CommandId 'RunPowerShellScript' -ScriptPath 'local-domaininfo.ps1'
$domainGuid = ($output.Value[0].Message -replace '(?<!:.*):', '=' | ConvertFrom-StringData).domainGuid
$domainName = ($output.Value[0].Message -replace '(?<!:.*):', '=' | ConvertFrom-StringData).domainName
$domainSid = ($output.Value[0].Message -replace '(?<!:.*):', '=' | ConvertFrom-StringData).domainSid
$forestName = ($output.Value[0].Message -replace '(?<!:.*):', '=' | ConvertFrom-StringData).forestName
$netBiosDomainName = ($output.Value[0].Message -replace '(?<!:.*):', '=' | ConvertFrom-StringData).netBiosDomainName
$azureStorageSid = $domainSid + "-123454321"

$body = @{
    properties = @{
        azureFilesIdentityBasedAuthentication = @{
            directoryServiceOptions   = "AADKERB";
            activeDirectoryProperties = @{
                domainName        = $domainName
                netBiosDomainName = $netBiosDomainName
                forestName        = $forestName
                domainGuid        = $domainGuid
                domainSid         = $domainSid
                azureStorageSid   = $azureStorageSid
            }
        }
    }
}
$Uri = $script:AzureUrl + $storageAccount.Id + "?api-version=2021-04-01"
$script:token = GetAuthToken -resource $script:AzureUrl
$jsonBody = $body | ConvertTo-Json -Depth 99
Invoke-RestMethod -Uri $Uri -ContentType 'application/json' -Method PATCH -Headers $script:AzureToken -Body $jsonBody



# Configuring FSLogix
$profileLocation = "\\$($storageaccount.StorageAccountName).file.core.windows.net\profiles"
$officeLocation = "\\$($storageaccount.StorageAccountName).file.core.windows.net\office"
$generalParameters = @{
    ResourceGroupName = "RG-roz-avd-01"
    vmName            = "AAD-avd-2"
    Name              = "deploy.fslogix"
}
$extensionParameters = @{
    Location       = 'westeurope'
    FileUri        = "https://raw.githubusercontent.com/srozemuller/AVD/main/FsLogix/deploy-fslogix-config.ps1"
    Run            = 'deploy-fslogix-config.ps1'
    Argument       = "-profileLocation $profileLocation -officeLocation $officeLocation"
    ForceReRun     = $true
}
$fslogix = Set-AzVMCustomScriptExtension @generalParameters @extensionParameters

$vm = Get-azvm -name "AAD-avd-2" -ResourceGroupName 'RG-roz-avd-01'
$testParameters = @{
    aadUserName = "AzureAD\userPrincipalName"
    azureADUserPwd = "secretPassword"
    psexecDownloadLocation = "https://download.sysinternals.com/files/PSTools.zip"
}
$testOutput = $vm | Invoke-AzVMRunCommand -CommandId 'RunPowerShellScript' -ScriptPath .\test-kbrt.ps1 -Parameter $testParameters
$testOutput.Value[0].Message

$testOutput2 = $vm | Invoke-AzVMRunCommand -CommandId 'RunPowerShellScript' -ScriptPath .\test-kbrt.ps1 -Parameter $testParameters
if ($testOutput2.Value[0].Message | Select-String -Pattern "Server: krbtgt/KERBEROS.MICROSOFTONLINE.COM @ KERBEROS.MICROSOFTONLINE.COM" -CaseSensitive -SimpleMatch){
    Write-Output "Its OK!"
}
else {
    Write-Warning "NOT OK!"
}