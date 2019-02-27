<#

.SYNOPSIS
Add VMs to Nutanix protection domains according to the VMware 'Backup' Tag

.DESCRIPTION
This script will read the 'Backup' tag in VMware and will add the VM to the Nutanix protection domain.

.EXAMPLE
.\set-protection.ps1 -vCenter vcenter01 -vCenterUser root -securePasswordFilevCenter pwvcenter.txt -clusterIP nutanix01 -nutanixUser admin -securePasswordFileNutanix pwnutanix.txt

.PARAMETER vCenter
Mandatory parameter which contains the vCenter Hostname, FQDN or IP.

.PARAMETER vCenterUser
Optional parameter which contains the vCenter username. (default root)

.PARAMETER securePasswordFilevCenter
Optional parameter (when vCenterPass is used) pointing to a file which contains the secured password of the vCenter username. 
("Password!" | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString | Out-File password.txt)

.PARAMETER vCenterPass
Optional parameter (when secyrePasswordFile is used) which contains the password of the vCenter username

.PARAMETER clusterIP
Mandatory parameter which contains the Nutanix cluster Hostname, FQDN or IP.

.PARAMETER clusterPort
Optional parameter which contains the Nutanix cluster port (default 9440)

.PARAMETER securePasswordFileNutanix
Optional parameter (when nutanixPass is used) pointing to a file which contains the secured password of the Nutanix username. 

.PARAMETER nutanixPass
Optional parameter (when secyrePasswordFileNutanix is used) which contains the password of the Nutanix username

.PARAMETER emailaddress
Optional parameter containing the e-mail-address where the results will be send to. (default administrator@company.com)

.PARAMETER processPD
Optional parameter to turn on/off processing of the Nutanix Protection Domains (default true)

#>

# Version 1.0 (2018-01-24)
# This version is modified for public publication. 


param ( [parameter(Mandatory = $true)][string]$vCenter,
                                      [string]$vCenterUser = "root",
                                      [string]$securePasswordFilevCenter,
                                      [string]$vCenterpass,
        [parameter(Mandatory = $true)][string]$clusterIP,
                                      [string]$clusterPort = "9440",
        [parameter(Mandatory = $true)][string]$nutanixUser = "admin",
                                      [string]$securePasswordFileNutanix,
                                      [string]$nutanixPass,
                                      [string]$emailaddress = "administrator@company.com",
                                      [boolean]$processPD = $true)

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

$NoBackupTag = @("NOBACKUP")
$customBackupTag = "Custom"

if ($vcenter -eq "vcenter1.company.com"){
    $suffix = "DTC1-DTC2"
} elseif ($vcenter -eq "vcenter2.company.com"){
    $suffix = "DTC2-DTC1"
} else {
    write-host -ForegroundColor Red "Please use: vcenter1.company.com OR vcenter2.company.com as vcenter parameter"
    exit
}

$suffixPD = $suffix + "PD"

$backupTagsPD = @{"DTC1LocalOnly"="DTC1LocalOnly";
                  "DTC2LocalOnly"="DTC2LocalOnly";
                  "PRD-GOLD"="PRD-GOLD_$suffixPD"; 
                  "PRD-SILVER"="PRD-SILVER_$suffixPD";
                  "PRD-BRONZE"="PRD-BRONZE_$suffixPD"}

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

# Add the VM to the appropriate Nutanix Protection Domain
function addVMtoPD($vm, $tag){
    #Make sure the VM isn't already part of another PD or the same PD             
    $goalPD = $($backupTagsPD.$tag)

    if ($goalPD -eq $null){
        write-host -ForegroundColor red "No PD found for tag $tag and VM $vm"
    } else {
        write-host -ForegroundColor Green "Adding/Checking $vm for PD $goalPD"
        #Check if already in 'right' PD
        #Get the right PD
        foreach($pd in $allPD){
            if ($pd.Name -eq $goalPD){
                $pdVMs = $pd.vms.vmName
            }
        }

        #Check if VM is in there
        if ($pdVMs -contains $vm.Name){
            write-host -ForegroundColor Green "No action: VM $vm already part of PD $goalPD"
        } else {
            $remove = $false
            foreach($pd in $allPD){
                if ($pd.vms.vmName -contains $vm.Name){                    
                    write-host -ForegroundColor Red "VM $vm currently member of PD $($pd.Name)"
                    $pdName = $pd.Name
                    $remove = $true
                }
            }
            
            if ($remove) {
                #REMOVE FROM PD
                write-host -ForegroundColor Yellow "Action remove: VM $vm part of (other) PD $pdName"

                #Remove VM
                $action = "protection_domains/$pdName/unprotect_vms"
                $body = "[ ""$vm"" ]"
                $result = nutanixAPICall -method "post" -action $action -body $body  
            }                      
            
            #ADD VM TO PD
            write-host -ForegroundColor Yellow "Action add: VM $vm to PD $goalPD"
            $action = "protection_domains/$goalPD/protect_vms"
            $body = "{""ignore_dup_or_missing_vms"": true, ""names"": [ ""$vm"" ]}"
            $result = nutanixAPICall -method "post" -action $action -body $body            
        }
    }
}


#Execute API Call
function nutanixAPICall($method, $action, $body){
    $uri = "https://$clusterip`:$clusterport/PrismGateway/services/rest/v1/$action"
    $header= @{ "Content-Type" = "application/json";
                "Accept" = "application/json";
                "Authorization" = "Basic "+[System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($nutanixUser+":"+$securePasswordNutanix))}
    $result = Invoke-RestMethod -Method $method -Uri $uri -Headers $header -Body $body    

    return $result
}

# Get VMs from PD if PD empty all PDs
function getVMsfromPD($pd){
    $action = "protection_domains/$pd"  
    $result = nutanixAPICall -method "get" -action $action
    return $result
}


#Make sure there is a connection with the vCenter
if (ConnectVcenter($vCenter)){
    $notagVMs = ""  
    $vms = get-vm -Name RM* | Where-Object {$_.Uid -Like "*$vcenter*"}
    $allPD = getVMsfromPD -pd "" #Pre-Cache all PDs

    foreach ($vm in $vms){
        $backupTag = $(Get-TagAssignment -Entity $vm -Category Backup).Tag.Name
        
        if (($backupTag -eq $null) -or ($NoBackupTag -contains $backupTag) -or ($backupTag -eq $customBackupTag)){
            write-host -ForegroundColor Yellow "VM skipped for backup: $vm"
            if ($backupTag -eq $null){
                $notagVMs += $vm.Name + "`n"
            } elseif ($NoBackupTag -contains $backupTag) {                
                #Remove BACKUP PD
                write-host -ForegroundColor Red "VM $vm removed from all PD"
                foreach($pd in $allPD){
                    if ($pd.vms.vmName -contains $vm.Name){                    
                        $pdName = $pd.Name
                        
                        $action = "protection_domains/$pdName/unprotect_vms"
                        $body = "[ ""$vm"" ]"
                        $result = nutanixAPICall -method "post" -action $action -body $body 
                    }
                }
            }
        } else {
            
            write-host -ForegroundColor Green "VM add or checked for backup $backupTag : $vm"
            
            if ($processPD){
                addVMtoPD -vm $vm -tag $backupTag  
            }
        }
    }

    $body = "The following VMs have no tag set for backup, please fix`n"
    $body += "vcenter: " + $vcenter + "`n`n"
    $body += $notagVMs

    if ($emailaddress -ne $null) {
        $smtp = New-Object Net.Mail.SmtpClient("mail.aai.nl")
        $smtp.Send("backupscript@company.com", $emailaddress, "VMs not in backup", $body)
    }

    write-host -ForegroundColor Red "The following VM's have no tag attached, please fix."
    write-host $notagVMs

}


