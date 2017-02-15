#!/usr/bin/env bash

## Shell Options ----------------------------------------------------------------
set -e -u -x
set -o pipefail

source config-vars.sh

### login
$maas_login_cmd &>/dev/null

#infra_hosts=$(maas $maas_profile tag nodes ${maas_tags_list[0]}|jq -r .[].hostname)
##############
function pool_limit() {
	local subnet=$(echo "$1"|awk -F'/' '{print $1}')
	IFS='.' read -r -a IP <<< $subnet
	suffix=$(echo "${IP[3]} + $2"|bc)
	echo "${IP[0]}.${IP[1]}.${IP[2]}.$suffix"
}

##############
function create_tags() {
	for tag in ${maas_tags_list[@]}; do
		maas $maas_profile tags create name=$tag
	done
}

##############
function lvm_volume_groups() {
  for node in $(maas $maas_profile tag nodes ${maas_tags_list[0]}|jq -r .[].hostname); do
  (volume_group_list=${maas_volume_groups_list["${maas_tags_list[0]}"]}
  system_id=$(maas $maas_profile nodes read|jq -r --arg hostname "$node" '.[] | if .hostname == $hostname then .system_id else empty end')
      for var in $volume_group_list; do
        vg=$(echo $var|cut -f1 -d':')
        device=$(echo $var|cut -f2 -d':')	
	block_devices_id=$(maas $maas_profile block-devices read $system_id|jq -r --arg name "$device" '.[] | if .name == $name then .id else empty end')
        echo "Node: $node, Device_id: $block_devices_id, system_id: $system_id"
	sleep 2
        maas $maas_profile volume-groups create $system_id name=$vg block_devices=$block_devices_id
      done)&
  done
}

##############
function lvm_logical_volumes() {
  for node in $(maas $maas_profile tag nodes ${maas_tags_list[0]}|jq -r .[].hostname); do
  (system_id=$(maas $maas_profile nodes read|jq -r --arg hostname "$node" '.[] | if .hostname == $hostname then .system_id else empty end')
  logical_volume_list=${maas_logical_volumes_list["${maas_tags_list[0]}"]}
      for var in $logical_volume_list; do
	IFS=':' read -r -a array <<< "$var"
        vg="${array[0]}"
        lv="${array[1]}"
        mount_point="${array[2]}"
	size="${array[3]}"
	echo "node: $node, vg: $vg,  lv: $lv, size: $size"
	sleep 2
 	volume_group_id=$(maas $maas_profile volume-groups read $system_id|jq -r --arg name "$vg" '.[] | if .name == $name then .id else empty end')
        maas $maas_profile volume-group create-logical-volume $system_id $volume_group_id name=$lv size=$size
        sleep 1
	block_devices_id=$(maas $maas_profile block-devices read $system_id|jq -r --arg name "$vg-$lv" '.[] | if .name == $name then .id else empty end')
	maas $maas_profile block-device format  $system_id $block_devices_id fstype=ext4
	maas $maas_profile block-device mount $system_id $block_devices_id mount_point=$mount_point
      done)&
  done
}

################
function fabric_space() {
	maas $maas_profile fabric update 0 name=maas-management
	maas $maas_profile fabric update 2 name=os-management
	maas $maas_profile space update 0 name=maas-admin
	for space in $maas_spaces_list; do
	   IFS='|' read -r -a array <<< "$space"
	   if [[ "${array[0]}" != "maas-admin" ]]; then
		names=$(maas $maas_profile spaces read | jq -r .[].name)
		(echo "$names" | grep -q "${array[0]}")||maas $maas_profile spaces create name=${array[0]}
	   fi
	done
	for space in $maas_spaces_list; do
	   IFS='|' read -r -a array <<< "$space"
	   space_id=$(maas $maas_profile spaces read|jq -r --arg name "${array[0]}" '.[] | if .name == $name then .id else empty end')
	   if [[ "${array[0]}" == "maas-admin" ]] || [[ "${array[0]}" == "external" ]]; then
	   	maas $maas_profile subnet update cidr:${array[1]} name=${array[0]} space=$space_id gateway_ip=$(pool_limit ${array[1]} 1)
	   else
		maas $maas_profile subnet update vlan:${array[2]} name=${array[0]} space=$space_id
	   fi
	done
}


################
function vlan_dhcp() {
	declare -g IPS_MGMT_POOL IPS_STRG_POOL
	maas_fabric_id=$(maas $maas_profile fabrics read|jq -r --arg name "maas-management" '.[] | if .name == $name then .id else empty end')
	os_fabric_id=$(maas $maas_profile fabrics read|jq -r --arg name "os-management" '.[] | if .name == $name then .id else empty end')
	for space in $maas_spaces_list; do
	   IFS='|' read -r -a array <<< "$space"
	   if [[ "${array[0]}" != "external" ]]; then
		sp=$(echo ${array[3]}|cut -d'-' -f1)
		ep=$(echo ${array[3]}|cut -d'-' -f2)
		maas $maas_profile ipranges create type=dynamic start_ip=$(pool_limit ${array[1]} $sp) end_ip=$(pool_limit ${array[1]} $ep)
		sp=$(echo "$ep + $ep + 1"|bc)
		first_ip=$(pool_limit ${array[1]} $ep)
		last_ip=$(pool_limit ${array[1]} $sp)
		if [[ "${array[0]}" == "management" ]]; then
		IPS_MGMT_POOL=($(prips $first_ip $last_ip))
		maas_fabric_id=$os_fabric_id
		fi
		if [[ "${array[0]}" == "storage" ]]; then
		IPS_STRG_POOL=($(prips $first_ip $last_ip))
		maas_fabric_id=$os_fabric_id
		fi
		ep=254
		maas $maas_profile ipranges create type=reserved start_ip=$(pool_limit ${array[1]} $sp) end_ip=$(pool_limit ${array[1]} $ep)
		maas $maas_profile vlan update $maas_fabric_id ${array[2]} name=${array[0]} dhcp_on=True primary_rack=$primary_rack_id
	   fi
	done
	echo "IPS_MGMT_POOL=\"${IPS_MGMT_POOL[@]}\"">/tmp/mgmt
	echo "IPS_STRG_POOL=\"${IPS_STRG_POOL[@]}\"">/tmp/strg
}


################
function nodes_networks() {
	local i=1
	source /tmp/mgmt && source /tmp/strg
	ips_mgmt_pool=($IPS_MGMT_POOL)
	ips_strg_pool=($IPS_STRG_POOL)
	fabric_id=$(maas $maas_profile fabrics read|jq -r --arg name "os-management" '.[] | if .name == $name then .id else empty end')
	for node in $maas_nodes_list; do
	(system_id=$(maas $maas_profile nodes read|jq -r --arg hostname "$node" '.[] | if .hostname == $hostname then .system_id else empty end')
	parents=($(maas $maas_profile interfaces read $system_id| jq -r --arg if1 "${maas_bd_if[0]}" --arg if2 "${maas_bd_if[1]}" --arg if3 "${maas_bd_if[2]}" '.[]| if .name == $if1 or .name == $if2 or .name == $if3 then .id else empty end'))
	maas $maas_profile interfaces create-bond $system_id name=bond0  parents=${parents[0]} parents=${parents[1]} parents=${parents[2]}  bond_mode=802.3ad bond_lacp_rate=slow bond_xmit_hash_policy=layer3+4
	for var in $openstack_bridges_list; do
	    bridge=$(echo $var|cut -d':' -f1)
	    vlan=$(echo $var|cut -d':' -f2)
	    parent=$(maas $maas_profile interfaces read $system_id|jq -r --arg name "bond0" '.[] | if .name == $name then .id else empty end')
	    echo "node: $node, bridge: $bridge, vlan: $vlan, parent: $parent, IP: ${ips_mgmt_pool[$i]}"
	    vlan_id=$(maas $maas_profile vlans read $fabric_id|jq --argjson vid $vlan '.[] | if .vid == $vid then .id else empty end')
            cidr=$(maas $maas_profile subnets read|jq -r --argjson vid $vlan '.[] | if .vlan.vid == $vid then .cidr else empty end')
            maas $maas_profile interfaces create-vlan $system_id vlan=$vlan_id parent=$parent
            vlan_id=($(maas $maas_profile interfaces read $system_id|jq -r -c --arg name "bond0.$vlan" '.[] | if .name == $name then .id, .vlan.id else empty end'))
            maas $maas_profile interfaces create-bridge $system_id name=$bridge vlan=${vlan_id[1]} parent=${vlan_id[0]} mtu=65000
            if_id=$(maas $maas_profile interfaces read $system_id|jq -r --arg name "$bridge" '.[] | if .name == $name then .id else empty end')
	    case "$vlan" in
	    (10)
	    	maas $maas_profile interface link-subnet $system_id $if_id subnet=cidr:$cidr mode=static ip_address=${ips_mgmt_pool[$i]}
	    ;;
	    (20)
	    	(echo "$infra_hosts" | grep -q "$node")||maas $maas_profile interface link-subnet $system_id $if_id subnet=cidr:$cidr mode=static ip_address=${ips_strg_pool[$i]}
	    ;;
	    esac
	done)&
	i=$((i+1))
     done
}

###################
function connect_interfaces_to_fabric() {
	cidr="10.1.0.0/16"
	for node in $(maas $maas_profile tag nodes ${maas_tags_list[0]}|jq -r .[].hostname); do
        (system_id=$(maas $maas_profile nodes read|jq -r --arg hostname "$node" '.[] | if .hostname == $hostname then .system_id else empty end')
       		for interface in ${maas_bd_if[@]}; do
		if_id=$(maas $maas_profile interfaces read $system_id|jq -r --arg name "$interface" '.[] | if .name == $name then .id else empty end')
		maas $maas_profile interface link-subnet $system_id $if_id subnet=cidr:$cidr
      done)&
      done
}

###################
prepare_target_nodes() {
	for node in $maas_nodes_list ; do
	    (ssh -o StrictHostKeyChecking=no ubuntu@$node "
		sudo apt update && sudo apt upgrade -y
		sudo apt install -y $target_nodes_packages
		sudo sed -i  's/^\(#\)\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
		sudo systemctl restart sshd
                echo "root:$root_passwork"|sudo chpasswd
		sudo chmod 666 /etc/network/interfaces
		if echo "$infra_hosts" | grep -q "$node" ; then
			echo 'nothing to do for now'
		else
			echo 'nothing to do for now'
		fi
		sudo chmod 644 /etc/network/interfaces
		echo "$ssh_key"|sudo tee /root/.ssh/authorized_keys
                #sudo reboot
	   ")&
	done
}

#fabric_space
#vlan_dhcp
#create_tags
#connect_interfaces_to_fabric
#nodes_networks
#lvm_volume_groups
#lvm_logical_volumes
#prepare_target_nodes
