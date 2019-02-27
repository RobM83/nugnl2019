# Automate VMware & Nutanix back-up and (disaster) recovery

This repository contains 'pseudo' code for the following tasks;

* Add VMs automatically to the appropriate Protection Domain by setting a vSphere tag.
* Do a (un)planned failover and restore network and powerstate.

The code probably needs some minor editing before using in your own environment.

**This code is 'pseudo' code, since it is altered from it is original to exclude potential sensitive information and settings, therefore this code is not tested in its current form.**

## Add VMs automatically to the appropriate Protection Domain

* File: *nugnl_set_protection.ps1*
  
1. Create a custom category in vSphere with 'one tag per object' and associable with 'virtual machines'.
2. Create the tags you want to use for your protection domains, i.e. gold, silver, bronze and nobackup.
3. Adjust the script with your tags and protection domains.
4. Schedule the script to run regularly (i.e. daily)

The script is based on a twin / dual datacenter setup, meaning that there are two datacenters with each their own vCenter and Nutanix cluster.
These protection domains are replicated to the other datacenter (remote side), therefore the following code needs to be adjuster or eventually removed.

```powershell
if ($vcenter -eq "vcenter1.company.com"){
    $suffix = "DTC1-DTC2"
} elseif ($vcenter -eq "vcenter2.company.com"){
    $suffix = "DTC2-DTC1"
} else {
    write-host -ForegroundColor Red "Please use: vcenter1.company.com OR vcenter2.company.com as vcenter parameter"
    exit
}
```

## Failover and restore

### Store VM state

* File: *nugnl_save_vm_State.ps1*

Since this script is based on the scenario of two datacenters and two vCenters which each their own distributed switch, but with the same port-group names, we need to store the network information with the VM (Normally only an unique ID of the network is stored).

The script will store the portgroups belonging to each vnic and the current power-state of the VM in the VMX file.

1. Adjust the script if needed.
2. Run the script regularly i.e. daily (normally servers don't change that often)

### Restore settings

* File: *nugnl_restore_vm_state.ps1*

After a unplanned (activate) or planned (migrate) failover the VMs can easily be restored, meaning the network settings will be change to the appropriate port-group and the last known power-state is restored.

1. Adjust the script if needed.
2. Run the script after a failover (migrate or activate) per protection-domain that needs to be restored.