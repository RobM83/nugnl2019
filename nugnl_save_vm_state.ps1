<#

.SYNOPSIS
Update VMX files of the VM with: Powerstate, Network, Backup-Tag

.DESCRIPTION
When a VM is moved to another vCenter on a storage level (not using cross-vCenter functionality),
some information about the VM is lost, the network in case of a distributed switch, the powerstate and the tags related to the VM.
By storing this information within the VMX file, this information can be restored in a new or unknowning vCenter.
This is especially usefull for DR scenarios initiated by Nutanix.

.EXAMPLE
.\update-vmx.ps1 -vCenter vcenter01 -vCenterUser root -securePasswordFile mySecurePW.txt
.\update-vmx.ps1 -vCenter vcenter01 -vCenterUser root -vCenterPass vmware

.PARAMETER vCenter
Mandatory parameter which contains the vCenter Hostname, FQDN or IP.

.PARAMETER vCenterUser
Optional parameter which contains the vCenter username. (default root)

.PARAMETER securePasswordFile
Optional parameter (when vCenterPass is used) pointing to a file which contains the secured password of the vCenter username. 
("Password!" | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString | Out-File password.txt)

.PARAMETER vCenterPass
Optional parameter (when secyrePasswordFile is used) which contains the password of the vCenter username
#>

# Version 1.0 (2018-01-24)
# This version is modified for public publication.

# Copy network port-group name to VMX file
param ([parameter(Mandatory = $true)][string]$vCenter,
                                     [string]$securePasswordFile,
                                     [string]$vCenterUser = "root",
                                     [string]$vCenterPass)

if ((!$securePasswordFile) -and (!$vCenterPass)){
    write-host -ForegroundColor Yellow "Password required, use parameter securePasswordFile or vCenterPass"
    exit
}

if ($securePasswordFile){
    $securePassword = Get-Content $securePasswordFile | ConvertTo-SecureString
} else {
    $securePassword = $vCenterPass | ConvertTo-SecureString -AsPlainText -Force
}

$vCenterCredential = New-Object System.Management.Automation.PSCredential -ArgumentList $vCenterUser, $securePassword

# Load PowerCLI Modules
Get-Module -Name VMware* -ListAvailable | Import-Module
  
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
   
#Get all VMs and remove Orphaned VMs
if (ConnectVcenter($vCenter)){
	write-host -ForegroundColor Green "Getting al VMs and remove Orphaned VMs"
	$vms = get-vm -Name * 
	foreach ($vm in $vms){
		$nicCount = 0
		$pgName = $null
		if ($vm.ExtensionData.Runtime.ConnectionState -eq "orphaned"){
			write-host -ForegroundColor Red "Orphaned VM deleted: $vm"
			$vm | Remove-VM -Confirm:$false
		} else {
			#Find the port-group name
			$adapters = Get-NetworkAdapter $vm 
			foreach($adapter in $adapters){
				$vmNetworkName = $adapter.NetworkName
				$pgName = Get-VDPortGroup -Name $vmNetworkName -ErrorAction SilentlyContinue
				if ($pgName -eq ""){
					write-host -ForegroundColor Red "Network $vmNetworkName not found on vm: $vm"
				} else {
					#Add Network port-group name to VMX
					write-host -ForegroundColor Green "Add nugnl.pgName.nic$nicCount=$vmNetworkName to: $vm"
					New-AdvancedSetting -Name "nugnl.pgName.nic$nicCount" -Value "$vmNetworkName" -Entity "$vm" -Force -Confirm:$false | out-null
					$nicCount++
				}
		
			}
			#PowerState
			$lastState = $vm.PowerState
			write-host -ForegroundColor Green "Add nugnl.lastKnownState=$lastState to: $vm"
			New-AdvancedSetting -Name "nugnl.lastKnownState" -Value "$lastState" -Entity "$vm" -Force -Confirm:$false | out-null
            #Backup Tags

            $backupTag = $(Get-TagAssignment -Category Backup -Entity $vm).Tag.Name
            write-host -ForegroundColor Green "Add nugnl.backupTag=$backupTag to: $vm"
            New-AdvancedSetting -Name "nugnl.backupTag" -Value "$backupTag" -Entity "$vm" -Force -Confirm:$false | out-null

		}
	}
    Disconnect-viServer $vcenter -Confirm:$false
}
