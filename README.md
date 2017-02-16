# maas_script

This is a set of shell functions to automate the configuration of MAAS nodes (spaces, disk partions, network bridges, bonding…. ). To use this script you need to do the following:

* the installation of bc, jq and prips commands.
* adjust the settings in `config-vars.sh` file to meet the requirements of your environment.
* uncomment the line  `#infra_hosts=$……` in maas-pre-deployment.sh script after creating the tags with `create_tags` function.

It is also recommended to run the functions one at a time.
