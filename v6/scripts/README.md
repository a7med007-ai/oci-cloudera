# scripts
All scripts in this location are referenced for deployment automation 

* boot.sh is invoked by cloudinit on each instance creation via Terraform.  It contains steps which perform inital bootstrapping of the instance prior to provisioning.
* cm_boot.sh is invoked by cloudinit on the Utility node to stand up Cloudera Manager and Pre-requisitres.
* deploy_on_oci.py is the primary Python script invoked to deploy Cloudera EDH v6 using cm_client python libraries


## CAUTION WHEN MODIFYING BOOT SCRIPTS
Because boot.sh and cm_boot.sh are invoked as part of user_data in Terraform, if you modify these files and re-run a deployment, existing instances will be destroyed and re-deployed because of this change.   
