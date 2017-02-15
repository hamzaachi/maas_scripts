#!/usr/bin/env bash
declare -A maas_volume_groups_list maas_logical_volumes_list


######################## Login Info #############################
maas_profile="maasadmin"
maas_api_server="http://172.16.1.1:5240/MAAS"
maas_api_key=$(maas-region apikey --username=$maas_profile)
maas_login_cmd="maas login $maas_profile $maas_api_server $maas_api_key"

####################### MAAS Global Settings ####################
primary_rack_id=$($maas_login_cmd &>/dev/null;maas $maas_profile rack-controllers read | jq -r '.[].system_id')
ssh_key=$(maas $maas_profile sshkeys read |jq -r '.[].key')

######################## MAAS Nodes List ########################
maas_nodes_list="infra01 infra02 infra03 compute01 compute02 compute03"
maas_tags_list=(infra hpc nohpc)
root_passwork="ubuntu"
######################## Disks and Partitions Settings ##########
maas_volume_groups_list["${maas_tags_list[0]}"]="containers:sdb backup:sdc"
maas_logical_volumes_list["${maas_tags_list[0]}"]="containers:openstack:/openstack:1000G  backup:backup:/openstack/backup:1000G"

######################## Network Settings #######################
maas_fabrics_list="os-management maas-management"
################# space-name|cidr|vlan_id|pool limit
maas_spaces_list="maas-admin|172.16.1.0/24|0|2-30 management|172.29.236.0/24|10|2-30 storage|172.29.244.0/24|20|2-30 external|10.1.0.0/16|0|2-30"
maas_bd_if=(eno2 eno3 eno4)
openstack_bridges_list="br-mgmt:10 br-storage:20"

####################### OpenStack Settings ######################
target_nodes_packages="python bridge-utils debootstrap ifenslave ifenslave-2.6 lsof lvm2 ntp ntpdate openssh-server sudo tcpdump vlan"
compute_net_conf="
auto p_prv
allow-br-prv p_prv
iface p_prv inet manual
	ovs_type OVSIntPort
	mtu 65000
	ovs_bridge br-prv

auto p_floating
allow-br-floating p_floating
iface p_floating inet manual
	ovs_type OVSIntPort
	mtu 65000
	ovs_bridge br-floating

source /etc/network/interfaces.d/*.cfg
"
