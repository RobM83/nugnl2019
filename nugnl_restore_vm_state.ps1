<#

.SYNOPSIS
Restore VM networking, powerstate and 'backup' tag after a planned or unplanned DR.

.DESCRIPTION
This script will restore the VM network, powerstate and 'backup' tag, as is described in the VMX file.
This script depends on the entries in the VMX files, set by the nlnug_save_vm_state.ps1 script.

.EXAMPLE
./restore-dvs.ps1 -vcenter vcenter01 –vcenterUser USER -securePasswordFilevCenter -clusterIP nutanix01 -nutanixUser ADMIN –securePasswordFileNutanix pwnutanix.txt -pd PD01

.PARAMETER vCenter
Mandatory parameter which contains the vCenter Hostname, FQDN or IP of the vCenter where to restore.

.PARAMETER vCenterUser
Optional parameter which contains the vCenter username. (default root)

.PARAMETER securePasswordFilevCenter
Optional parameter (when vCenterPass is used) pointing to a file which contains the secured password of the vCenter username. 
("Password!" | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString | Out-File password.txt)

.PARAMETER vCenterPass
Optional parameter (when secyrePasswordFile is used) which contains the password of the vCenter username

.PARAMETER clusterIP
Mandatory parameter which contains the Nutanix cluster Hostname, FQDN or IP of the restored enviroment.

.PARAMETER clusterPort
Optional parameter which contains the Nutanix cluster port (default 9440)

.PARAMETER securePasswordFileNutanix
Optional parameter (when nutanixPass is used) pointing to a file which contains the secured password of the Nutanix username. 

.PARAMETER nutanixPass
Optional parameter (when secyrePasswordFileNutanix is used) which contains the password of the Nutanix username

.PARAMETER $pd
Mandatory parameter containing the PD to restore.

.PARAMETER $restorePowerState
Optional parameter will restore the powerstate of the VM as it was before the migration (last run of set-protection.ps1) (default true)
#>

# Version 1.0 (2018-01-24)
# This version is modified for public publication.

#Read information from VMX and restore network
param ( [parameter(Mandatory = $true)][string]$vCenter,
                                      [string]$vCenterUser = "root",
                                      [string]$vCenterpass,
                                      [string]$securePasswordFilevCenter,
        [parameter(Mandatory = $true)][string]$clusterIP,
                                      [string]$clusterPort = "9440",
        [parameter(Mandatory = $true)][string]$nutanixUser = "admin",
                                      [string]$nutanixPass,
                                      [string]$securePasswordFileNutanix,
        [parameter(Mandatory = $true)][string]$pd,
                                      [string]$remoteSite,
									  [boolean]$restorePowerState = $true)                                     

if ((!$securePasswordFilevCenter) -and (!$vCenterPass)){
    write-host -ForegroundColor Yellow "Password required, use parameter securePasswordFilevCenter or vCenterPass"
    exit
}
if ((!$securePasswordFileNutanix) -and (!$nutanixPass)){
    write-host -ForegroundColor Yellow "Password required, use parameter securePasswordFileNutanix or nutanixPass"
    exit
}

if ($securePasswordFilevCenter){
    $securePasswordvCenter = Get-Content $securePasswordFilevCenter | ConvertTo-SecureString
} else {
    $securePasswordvCenter = $vCenterPass | ConvertTo-SecureString -AsPlainText -Force
}
$vCenterCredential = New-Object System.Management.Automation.PSCredential -ArgumentList $vCenterUser, $securePasswordvCenter

if ($securePasswordFileNutanix){
    $securePasswordNutanix = Get-Content $securePasswordFileNutanix | ConvertTo-SecureString
    $securePasswordNutanix = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePasswordNutanix)
    $securePasswordNutanix = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($securePasswordNutanix)
} else {
    $securePasswordNutanix = $nutanixPass 
}

# Load PowerCLI Modules
Get-Module -Name VMware* -ListAvailable | Import-Module

#Dirty work-around for self-signed (untrusted) certificates
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    
    public class IDontCarePolicy : ICertificatePolicy {
        public IDontCarePolicy() {}
        public bool CheckValidationResult(
            ServicePoint sPoint, X509Certificate cert,
            WebRequest wRequest, int certProb) {
            return true;
        }
    }
"@

#Create vCenter connection
function ConnectVcenter($vCenter){     
   if (connect-viserver -Server $vCenter -Credential $vCenterCredential -ErrorAction SilentlyContinue){
        write-host -ForegroundColor Yellow "Connected to vCenter: $vCenter"
        return $true
   } else {
        write-host -ForegroundColor Red "Unable to connect to vCenter: $vCenter"
        return $false
   }
}									  
									  
#Get VMs from PD (Protection Domain)
function getVMsFromPD($pd){
    $vms = @()
    $action = "protection_domains/"
    $uri = "https://$clusterIP`:$clusterPort/PrismGateway/services/rest/v1/$action"
    $header = @{"Authorization" = "Basic "+[System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($nutanixUser+":"+$securePasswordNutanix))}    
    $tmpResult = Invoke-RestMethod -Method get -Uri $uri -Headers $header
    foreach ($domain in $tmpResult){        
        if ($domain.name -eq $pd){     
            foreach($vm in $domain.vms){
                #check on (n)
                if ($vm -match '\(\d+\)'){                    
                    $vm = $vm -replace '\ \(\d+\)', ""       
                }
                #write-host -ForegroundColor Yellow $vm.vmName
                $vms += $vm.vmName
            }
        }
    }
    return $vms
}

$pdvms = getVMsFromPD -pd $pd

if (ConnectVcenter($vCenter)){
	foreach ($machine in $pdvms){
		$vms = get-vm $machine* | Where-Object {$_.Uid -like "*$vcenter*"}
		if ($vms.count -gt 1){
			write-host -ForegroundColor Yellow "Multiple VMs with name: $vm on $vcenter"
		}
		foreach ($vm in $vms){
			$nicCount = 0
			write-host -ForegroundColor Green "Fixing $vm on $vcenter"
			$adapters = Get-NetworkAdapter $vm
			foreach($adapter in $adapters){
				$pgName = $(Get-AdvancedSetting -Entity $vm -name "nugnl.pgName.nic$nicCount").Value
				write-host -ForegroundColor Green "Adding $pgName to network-card $nicCount on $vm"
				Set-NetworkAdapter -NetworkAdapter $adapter -Portgroup $pgName -Confirm:$false | Out-Null
				Set-NetworkAdapter -NetworkAdapter $adapter -StartConnected:$true -Confirm:$false | Out-Null
				$nicCount++
			}
			if ($restorePowerState){
				$lastKnownState = $(Get-AdvancedSetting -Entity $vm -name "nugnl.lastKnownState").Value
				if ($lastKnownState -eq "PoweredOn") {
					write-host -ForegroundColor Green "Powering on: $vm"
					Start-VM -VM $vm -Confirm:$false -RunAsync | Out-Null
				}
			}
		}
	}
    Disconnect-viServer $vcenter -Confirm:$false
}