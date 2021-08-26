# Copyright(c) Microsoft and contributors. All rights reserved
#
# This source code is licensed under the MIT license found in the LICENSE file in the root directory of the source tree

<#
.SYNOPSIS
    This script creates Azure Netapp files Cross-Region Replication 
.DESCRIPTION
    Authenticates with Azure then creates primary/secondary Azure NetApp Files Resources and replication.
.PARAMETER PrimaryResourceGroupName
    Name of the primary Azure Resource Group where the ANF will be created
.PARAMETER PrimaryLocation
    Azure primary Location (e.g 'WestUS', 'EastUS')
.PARAMETER PrimaryNetAppAccountName
    Name of the Azure NetApp Files primary Account
.PARAMETER PrimaryNetAppPoolName
    Name of the Azure NetApp Files primary Capacity Pool
.PARAMETER PrimaryNetAppVolumeName\
    Name of the Azure NetApp Files primary Volume
.PARAMETER PrimaryServiceLevel
    primary Service Level - Ultra, Premium or Standard
.PARAMETER PrimarySubnetId
    The primary Delegated subnet Id within the VNET
.PARAMETER SecondaryResourceGroupName
    Name of the secondary Azure Resource Group where the ANF will be created
.PARAMETER SecondaryLocation
    Azure secondary Location (e.g 'WestUS', 'EastUS')
.PARAMETER SecondaryNetAppAccountName
    Name of the Azure NetApp Files Secondary Account
.PARAMETER SecondaryNetAppPoolName
    Name of the Azure NetApp Files secondary Capacity Pool
.PARAMETER SecondaryNetAppVolumeName\
    Name of the Azure NetApp Files secondary Volume
.PARAMETER SecondaryServiceLevel
    Secondary Service Level - Ultra, Premium or Standard
.PARAMETER SecondarySubnetId
    The secondary Delegated subnet Id within the VNET
.PARAMETER NetAppPoolSize
    Size of the Azure NetApp Files Capacity Pool in Bytes. Range between 4398046511104 and 549755813888000
.PARAMETER NetAppVolumeSize
    Size of the Azure NetApp Files volume in Bytes. Range between 107374182400 and 109951162777600
.PARAMETER AllowedClientsIp 
    Client IP to access Azure NetApp files volume
.PARAMETER CleanupResources
    If the script should clean up the resources, $false by default
.EXAMPLE
    PS C:\\> CreateANFVolume.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroupName 'My-RG' -Location 'WestUS' -NetAppAccountName 'testaccount' -NetAppPoolName 'pool1' -ServiceLevel Standard -NetAppVolumeName 'vol1' -ProtocolType NFSv4.1 -SubnetId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/My-RG/providers/Microsoft.Network/virtualNetworks/vnet1/subnets/subnet1'
#>
param
(
    #Name of the Azure Primary Resource Group
    [string]$PrimaryResourceGroupName = 'PrimaryResources-rg',

    #Azure Primary location 
    [string]$PrimaryLocation ='WestUS',

    #Azure NetApp Files Primary account name
    [string]$PrimaryNetAppAccountName = 'anfaccount1',

    #Azure NetApp Files Primary capacity pool name
    [string]$PrimaryNetAppPoolName = 'pool1' ,

    #Azure NetApp Files Primary volume name
    [string]$PrimaryNetAppVolumeName = 'vol1',

    #Primary ANF Service Level can be {Ultra, Premium or Standard}
    [ValidateSet("Ultra","Premium","Standard")]
    [string]$PrimaryServiceLevel = 'Premium',

    #Primary Subnet Id 
    [string]$PrimarySubnetId = '[Subnet ID in Primary region]',

    #Name of the Azure Secondary Resource Group
    [string]$SecondaryResourceGroupName = 'SecondaryResources-rg',

    #Azure Secondary location 
    [string]$SecondaryLocation ='EastUS',

    #Azure NetApp Files Secondary account name
    [string]$SecondaryNetAppAccountName = 'anfaccount2',

    #Azure NetApp Files Secondary capacity pool name
    [string]$SecondaryNetAppPoolName = 'pool2' ,

    #Azure NetApp Files Secondary volume name
    [string]$SecondaryNetAppVolumeName = 'vol2',

    #Secondary ANF Service Level can be {Ultra, Premium or Standard}
    [ValidateSet("Ultra","Premium","Standard")]
    [string]$SecondaryServiceLevel = 'Standard',

    #Secondary Subnet Id 
    [string]$SecondarySubnetId = '[Subnet ID in Secondary region]',
    
    #Azure NetApp Files capacity pool size
    [ValidateRange(4398046511104,549755813888000)]
    [long]$NetAppPoolSize = 4398046511104,
    
    #Azure NetApp Files volume size
    [ValidateRange(107374182400,109951162777600)]
    [long]$NetAppVolumeSize = 107374182400,
         
    #Allowed Ip Addresses property
    [string]$AllowedClientsIp = "0.0.0.0/0",

    #Clean Up resources
    [bool]$CleanupResources = $False
)

$ErrorActionPreference="Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#Functions
Function WaitForANFResource
{
    Param 
    (
        [ValidateSet("NetAppAccount","CapacityPool","Volume","Snapshot","Replication")]
        [string]$ResourceType,
        [string]$ResourceId, 
        [int]$IntervalInSec = 10,
        [int]$retries = 60,
        #Set to 'true' to Check for replication Status when creting Data protection volume
        [bool]$CheckForReplication = $False
    )

    for($i = 0; $i -le $retries; $i++)
    {
        Write-Verbose -Message "$Checking provision state" -Verbose
        Start-Sleep -s $IntervalInSec
        try
        {
            if($ResourceType -eq "NetAppAccount")
            {
                $Account = Get-AzNetAppFilesAccount -ResourceId $ResourceId
                if($Account.ProvisioningState -eq "Succeeded")
                {
                    break
                }

            }
            elseif($ResourceType -eq "CapacityPool")
            {
                $Pool = Get-AzNetAppFilesPool -ResourceId $ResourceId
                if($Pool.ProvisioningState -eq "Succeeded")
                {
                    break
                }
            }
            elseif($ResourceType -eq "Volume")
            {
                $Volume = Get-AzNetAppFilesVolume -ResourceId $ResourceId
                if($Volume.ProvisioningState -eq "Succeeded")
                {
                    if($CheckforReplication -And !$Volume.DataProtection.Replication)
                    {
                        continue
                    }
                    else
                    {
                        break 
                    }
                }
            }
            elseif($ResourceType -eq "Snapshot")
            {            
                $Snapshot = Get-AzNetAppFilesSnapshot -ResourceId $ResourceId
                if($Snapshot.ProvisioningState -eq "Succeeded")
                {
                    break
                }
            }
        }
        catch
        {
            continue
        }
    }    
}

Function WaitForNoANFResource
{
Param 
    (
        [ValidateSet("NetAppAccount","CapacityPool","Volume","Snapshot")]
        [string]$ResourceType,
        [string]$ResourceId, 
        [int]$IntervalInSec = 10,
        [int]$retries = 60,
        [bool]$CheckForReplication = $False
    )

    for($i = 0; $i -le $retries; $i++)
    {
        Write-Verbose -Message "Checking if resource has been completly deleted" -Verbose
        Start-Sleep -s $IntervalInSec
        try
        {
            if($ResourceType -eq "Snapshot")
            {
                Get-AzNetAppFilesSnapshot -ResourceId $ResourceId                
            }
            elseif($ResourceType -eq "Volume")
            {
                if($CheckForReplication)
                {
                    Get-AzNetAppFilesReplicationStatus -ResourceGroupName $SecondaryResourceGroupName -AccountName $SecondaryNetAppAccountName -PoolName $SecondaryNetAppPoolName -Name $SecondaryNetAppVolumeName                    
                }
                else
                {                
                    Get-AzNetAppFilesVolume -ResourceId $ResourceId                               
                }                
            }
            elseif($ResourceType -eq "CapacityPool")
            {
                Get-AzNetAppFilesPool -ResourceId $ResourceId                
            }
            elseif($ResourceType -eq "NetAppAccount")
            {   
                Get-AzNetAppFilesAccount -ResourceId $ResourceId                              
            }
        }
        catch
        {
            break
        }
    }
}


#Authorizing and connecting to Azure
Write-Verbose -Message "Authorizing with Azure Account..." -Verbose
Add-AzAccount

#Create Azure NetApp Files Primary Account
Write-Verbose -Message "Creating Azure NetApp Files Primary Account" -Verbose
$NewPrimaryAccount = New-AzNetAppFilesAccount -ResourceGroupName $PrimaryResourceGroupName `
    -Location $PrimaryLocation `
    -Name $PrimaryNetAppAccountName

Write-Verbose -Message "Azure NetApp Files Primary Account has been created successfully: $($NewPrimaryAccount.Id)" -Verbose


#Create Azure NetApp Files Primary Capacity Pool
Write-Verbose -Message "Creating Azure NetApp Files Primary Capacity Pool" -Verbose
$NewPrimaryPool = New-AzNetAppFilesPool -ResourceGroupName $PrimaryResourceGroupName `
    -Location $PrimaryLocation `
    -AccountName $PrimaryNetAppAccountName `
    -Name $PrimaryNetAppPoolName `
    -PoolSize $NetAppPoolSize `
    -ServiceLevel $PrimaryServiceLevel

Write-Verbose -Message "Azure NetApp Files Primary Capacity Pool has been created successfully: $($NewPrimaryPool.Id)" -Verbose


#Create Azure NetApp Files NFS Volume
Write-Verbose -Message "Creating Azure NetApp Files Primary Volume" -Verbose


$ExportPolicyRule = New-Object -TypeName Microsoft.Azure.Commands.NetAppFiles.Models.PSNetAppFilesExportPolicyRule
$ExportPolicyRule.RuleIndex =1
$ExportPolicyRule.UnixReadOnly =$False
$ExportPolicyRule.UnixReadWrite =$True
$ExportPolicyRule.Cifs = $False
$ExportPolicyRule.Nfsv3 = $False
$ExportPolicyRule.Nfsv41 = $True
$ExportPolicyRule.AllowedClients =$AllowedClientsIp

$ExportPolicy = New-Object -TypeName Microsoft.Azure.Commands.NetAppFiles.Models.PSNetAppFilesVolumeExportPolicy -Property @{Rules = $ExportPolicyRule}

$NewPrimaryVolume = New-AzNetAppFilesVolume -ResourceGroupName $PrimaryResourceGroupName `
    -Location $PrimaryLocation `
    -AccountName $PrimaryNetAppAccountName `
    -PoolName $PrimaryNetAppPoolName `
    -Name $PrimaryNetAppVolumeName `
    -UsageThreshold $NetAppVolumeSize `
    -ProtocolType "NFSv4.1" `
    -ServiceLevel $PrimaryServiceLevel `
    -SubnetId $PrimarySubnetId `
    -CreationToken $PrimaryNetAppVolumeName `
    -ExportPolicy $ExportPolicy

Write-Verbose -Message "Azure NetApp Files Primary Volume has been created successfully: $($NewPrimaryVolume.Id)" -Verbose

#Create Azure NetApp Files Secondary Account
Write-Verbose -Message "Creating Azure NetApp Files Secondary Account" -Verbose
$NewSecondaryAccount = New-AzNetAppFilesAccount -ResourceGroupName $SecondaryResourceGroupName `
    -Location $SecondaryLocation `
    -Name $SecondaryNetAppAccountName 

Write-Verbose -Message "Azure NetApp Files Secondary Account has been created successfully: $($NewSecondaryAccount.Id)" -Verbose

#Create Azure NetApp Files Secondary Capacity Pool
Write-Verbose -Message "Creating Azure NetApp Files Secondary Capacity Pool" -Verbose
$NewSecondaryPool = New-AzNetAppFilesPool -ResourceGroupName $SecondaryResourceGroupName `
    -Location $SecondaryLocation `
    -AccountName $SecondaryNetAppAccountName `
    -Name $SecondaryNetAppPoolName `
    -PoolSize $NetAppPoolSize `
    -ServiceLevel $SecondaryServiceLevel

Write-Verbose -Message "Azure NetApp Files Secondary Capacity Pool has been created successfully: $($NewSecondaryPool.Id)" -Verbose

#Create Azure NetApp Files NFS Volume
Write-Verbose -Message "Creating Azure NetApp Files Data Replication Volume at the Secondary account" -Verbose

$DataReplication = New-Object -TypeName Microsoft.Azure.Commands.NetAppFiles.Models.PSNetAppFilesReplicationObject -Property @{EndpointType = "dst";RemoteVolumeRegion = $PrimaryLocation;RemoteVolumeResourceId = $NewPrimaryVolume.Id;ReplicationSchedule = "hourly"}

$NewSecondaryVolume = New-AzNetAppFilesVolume -ResourceGroupName $SecondaryResourceGroupName `
    -Location $SecondaryLocation `
    -AccountName $SecondaryNetAppAccountName `
    -PoolName $SecondaryNetAppPoolName `
    -Name $SecondaryNetAppVolumeName `
    -UsageThreshold $NetAppVolumeSize `
    -ProtocolType "NFSv4.1" `
    -ServiceLevel $SecondaryServiceLevel `
    -SubnetId $SecondarySubnetId `
    -CreationToken $SecondaryNetAppVolumeName `
    -ExportPolicy $ExportPolicy `
    -ReplicationObject $DataReplication `
    -VolumeType "DataProtection"

WaitForANFResource -ResourceType Volume -ResourceId $NewSecondaryVolume.Id -CheckForReplication $True

Write-Verbose -Message "Azure NetApp Files Secondary Volume has been created successfully: $($NewSecondaryVolume.Id)" -Verbose

#Authorize the Primary volume
Write-Verbose -Message "Authorizing replication in source region ..." -Verbose
Approve-AzNetAppFilesReplication -ResourceGroupName $PrimaryResourceGroupName `
    -AccountName $PrimaryNetAppAccountName `
    -PoolName $PrimaryNetAppPoolName `
    -Name $PrimaryNetAppVolumeName `
    -DataProtectionVolumeId $($NewSecondaryVolume.Id)
Write-Verbose -Message "Sucessfully authorized replication in source region ..." -Verbose

if($CleanupResources)
{
    
    Write-Verbose -Message "Cleaning up Azure NetApp Files resources..." -Verbose
    
    #-------------------------------------
    #Cleaning up secondary resources
    #-------------------------------------

    Write-Verbose -Message "Deleting Replication in Secondary volume" -Verbose
    Remove-AzNetAppFilesReplication -ResourceGroupName $SecondaryResourceGroupName -AccountName $SecondaryNetAppAccountName -PoolName $SecondaryNetAppPoolName -Name $SecondaryNetAppVolumeName

    WaitForNoANFResource -ResourceType Volume -ResourceId $($NewSecondaryVolume.Id) -CheckForReplication $True

    #Deleting NetApp Files Volume 
    Write-Verbose -Message "Deleting Azure NetApp Files Volume: $SecondaryNetAppVolumeName" -Verbose
    Remove-AzNetAppFilesVolume -ResourceGroupName $SecondaryResourceGroupName `
            -AccountName $SecondaryNetAppAccountName `
            -PoolName $SecondaryNetAppPoolName `
            -Name $SecondaryNetAppVolumeName

    WaitForNoANFResource -ResourceType Volume -ResourceId $($NewSecondaryVolume.Id)

    #Deleting NetApp Files Pool
    Write-Verbose -Message "Deleting Azure NetApp Files pool: $SecondaryNetAppPoolName" -Verbose
    Remove-AzNetAppFilesPool -ResourceGroupName $SecondaryResourceGroupName `
        -AccountName $SecondaryNetAppAccountName `
        -PoolName $SecondaryNetAppPoolName

    WaitForNoANFResource -ResourceType CapacityPool -ResourceId $($NewSecondaryPool.Id)

    #Deleting NetApp Files account
    Write-Verbose -Message "Deleting Azure NetApp Files Account: $SecondaryNetAppAccountName" -Verbose
    Remove-AzNetAppFilesAccount -ResourceGroupName $SecondaryResourceGroupName -Name $SecondaryNetAppAccountName


    #-------------------------------------
    #Cleaning up secondary resources
    #-------------------------------------

    #Deleting NetApp Files Volume 
    Write-Verbose -Message "Deleting Azure NetApp Files Volume: $PrimaryNetAppVolumeName" -Verbose
    Remove-AzNetAppFilesVolume -ResourceGroupName $PrimaryResourceGroupName `
            -AccountName $PrimaryNetAppAccountName `
            -PoolName $PrimaryNetAppPoolName `
            -Name $PrimaryNetAppVolumeName

    WaitForNoANFResource -ResourceType Volume -ResourceId $($NewPrimaryVolume.Id)

    #Deleting NetApp Files Pool
    Write-Verbose -Message "Deleting Azure NetApp Files pool: $PrimaryNetAppPoolName" -Verbose
    Remove-AzNetAppFilesPool -ResourceGroupName $PrimaryResourceGroupName `
        -AccountName $PrimaryNetAppAccountName `
        -PoolName $PrimaryNetAppPoolName

    WaitForNoANFResource -ResourceType CapacityPool -ResourceId $($NewPrimaryPool.Id)

    #Deleting NetApp Files account
    Write-Verbose -Message "Deleting Azure NetApp Files Account: $PrimaryNetAppAccountName" -Verbose
    Remove-AzNetAppFilesAccount -ResourceGroupName $PrimaryResourceGroupName -Name $PrimaryNetAppAccountName

    Write-Verbose -Message "All Azure NetApp Files resources have been deleted successfully." -Verbose    
}