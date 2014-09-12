#!/usr/bin/env bash


# Copyright (C) 2014 William Lu. No rights reserved.
#
# This script creates a virtual switch (br-merge) which connects PUBLIC_BRIDGE,
# OVS_PHYSICAL_BRIDGE, and FLAT_INTERFACE. Then it exchanges the ip configuration
# beween br-merge and FLAT_INTERFACE.
#
# neutron_fix.sh can be easily and safely installed and uninstalled. It backs up
# your original network scripts before any operations. So it will not mess up the
# network configurations of your computer.


# Configurations
# ==============

# neutron_fix
EXEC='neutron_fix.sh'
INFO='#Generated by '$EXEC
INTRO="A fixer of external network connectivity for OpenStack Neutron"
EXEC_DIR=$(cd $(dirname "$0") && pwd)

# DevStack
TOP_DIR=$(cd $EXEC_DIR/../../ && pwd)
source $TOP_DIR/functions
source $TOP_DIR/lib/neutron
source $TOP_DIR/openrc admin admin

# network-scripts
scripts_path=etc/sysconfig/network-scripts
SCRIPTS=/$scripts_path
SCRIPTS_BACKUP=$EXEC_DIR/$scripts_path
IF=$FLAT_INTERFACE
IF_SCRIPT=ifcfg-$IF
BR=br-merge
BR_SCRIPT=ifcfg-$BR
BR_EX=$PUBLIC_BRIDGE
BR_PHY=$OVS_PHYSICAL_BRIDGE


# Functions
# =========

# help
function help() {
    # display help information
    echo -e "NAME"
    echo -e "\t$EXEC - $INTRO\n"
    echo -e "SYNOPSIS"
    echo -e "\t$EXEC COMMAND"
    echo -e "\t$EXEC [OPTIONS]\n"
    echo -e "COMMANDS"
    echo -e "\tstatus\t\t check if $EXEC is installed"
    echo -e "\tinstall\t\t install $EXEC"
    echo -e "\tuninstall\t uninstall $EXEC"
    echo -e "OPTIONS"
    echo -e "\t--help\t\t display this help"

    return 0
}

# _status
function _status() {
    # check $INFO
    if [ "$(cat $SCRIPTS/$IF_SCRIPT | sed -n '1p')" != "$INFO" ] ||
        [ "$(cat $SCRIPTS/$BR_SCRIPT | sed -n '1p')" != "$INFO" ]; then
        return 1
    fi

    # check $BR
    if ! sudo ovs-vsctl br-exists $BR; then
        return 2
    fi

    # check veth pairs
    if ! sudo ip link show phy1-$BR &> /dev/null ||
        ! sudo ip link show phy2-$BR &> /dev/null; then
        return 3
    fi

    # check bridge connections
    if [ "$(sudo ovs-vsctl list-ports $BR | grep phy1-$BR)" != "phy1-$BR" ]; then
        return 4
    fi
    if [ "$(sudo ovs-vsctl list-ports $BR | grep phy2-$BR)" != "phy2-$BR" ]; then
        return 4
    fi
    if is_service_enabled q-l3; then
        if [ "$(sudo ovs-vsctl list-ports $BR_EX | grep ex-$BR)" != "ex-$BR" ]; then
            return 4
        fi
    fi
    if [ "$(sudo ovs-vsctl list-ports $BR_PHY | grep eth1-$BR)" != "eth1-$BR" ]; then
        return 4
    fi

    return 0
}

# status
function status() {
    if _status; then
        echo "$EXEC is currently installed."
	    return 0
    else
        echo "$EXEC is not currently installed."
		return 1
    fi
}

# install
function install() {
    # check status
    if _status; then
		echo "Error 100: $EXEC is currently installed."
		return 100
	fi

	_status
	if [ "$?" == "1" ]; then
		# backup $IF_SCRIPT
		echo "Backing up $IF_SCRIPT..."
		mkdir -p $SCRIPTS_BACKUP
		cp $SCRIPTS/$IF_SCRIPT $SCRIPTS_BACKUP/$IF_SCRIPT.backup

		# prepare $IF_SCRIPT
		echo "Preparing $IF_SCRIPT..."
		rm -f $SCRIPTS_BACKUP/$IF_SCRIPT
		touch $SCRIPTS_BACKUP/$IF_SCRIPT
		echo $INFO >> $SCRIPTS_BACKUP/$IF_SCRIPT
		grep -G -e '^DEVICE=' -e '^HWADDR=' $SCRIPTS_BACKUP/$IF_SCRIPT.backup \
		>> $SCRIPTS_BACKUP/$IF_SCRIPT
		echo 'TYPE=OVSPort' >> $SCRIPTS_BACKUP/$IF_SCRIPT
		echo 'DEVICETYPE=ovs' >> $SCRIPTS_BACKUP/$IF_SCRIPT
		echo 'OVS_BRIDGE='$BR >> $SCRIPTS_BACKUP/$IF_SCRIPT
		echo 'ONBOOT=yes' >> $SCRIPTS_BACKUP/$IF_SCRIPT

		# prepare $BR_SCRIPT
		echo "Preparing $BR_SCRIPT..."
		rm -f $SCRIPTS_BACKUP/$BR_SCRIPT
		touch $SCRIPTS_BACKUP/$BR_SCRIPT
		echo $INFO >> $SCRIPTS_BACKUP/$BR_SCRIPT
		echo 'DEVICE='$BR >> $SCRIPTS_BACKUP/$BR_SCRIPT
		echo 'TYPE=OVSBridge' >> $SCRIPTS_BACKUP/$BR_SCRIPT
		echo 'DEVICETYPE=ovs' >> $SCRIPTS_BACKUP/$BR_SCRIPT
		grep -G -e '^BOOTPROTO=' -e '^IPADDR=' -e '^NETMASK=' -e '^PREFIX=' \
		-e '^GATEWAY=' -e '^DNS1=' -e '^DNS2=' $SCRIPTS_BACKUP/$IF_SCRIPT.backup \
		>> $SCRIPTS_BACKUP/$BR_SCRIPT
		echo 'ONBOOT=yes' >> $SCRIPTS_BACKUP/$BR_SCRIPT

		# copy $IF_SCRIPT and $BR_SCRIPT
		echo "Copying $IF_SCRIPT and $BR_SCRIPT..."
		sudo cp $SCRIPTS_BACKUP/$IF_SCRIPT $SCRIPTS/$IF_SCRIPT
		sudo cp $SCRIPTS_BACKUP/$BR_SCRIPT $SCRIPTS/$BR_SCRIPT
	fi
	_status
	if [ "$?" == "1" ]; then
		echo "Error 101: $IF_SCRIPTS and $BR_SCRIPT installation failed."
		return 101
	fi

    # restart network service
    echo "restarting network service..."
    sudo service network restart
    _status
    if [ "$?" == "2" ]; then
        echo "Error 102: $BR installation failed."
        return 102
    fi

	# create veth pairs
	echo "Creating veth pairs..."
	sudo ip link add phy1-$BR type veth peer name ex-$BR
	sudo ip link set dev phy1-$BR up
	sudo ip link set dev ex-$BR up
	sudo ip link add phy2-$BR type veth peer name eth1-$BR
	sudo ip link set dev phy2-$BR up
	sudo ip link set dev eth1-$BR up
	_status
	if [ "$?" == "3" ]; then
		echo "Error 103: veth pairs installation failed."
		retun 103
	fi

	# connect bridges
	echo "Connectiong bridges..."
	sudo ovs-vsctl add-port $BR phy1-$BR
	sudo ovs-vsctl add-port $BR phy2-$BR
	if is_service_enabled q-l3; then
		if ! sudo ovs-vsctl br-exists $BR_EX; then
			echo "Error 110: $BR_EX does not exist."
			return 110
		fi
		sudo ovs-vsctl add-port $BR_EX ex-$BR
	fi
	if ! sudo ovs-vsctl br-exists $BR_PHY; then
		echo "Error 111: $BR_PHY does not exist."
		return 111
	fi
	sudo ovs-vsctl add-port $BR_PHY eth1-$BR
	_status
	if [ "$?" == "4" ]; then
		echo "Error 104: Connecting bridges failed."
		return 104
	fi

	# return
	echo "$EXEC is successfully installed."
	return 0
}

# uninstall
function uninstall() {
    # check status
    _status
    if [ "$?" == "1" ]; then
		echo "Error 201: $EXEC is not currently installed."
		return 201
    fi

    # remove connections
    echo "Removing connections..."
	if is_service_enabled q-l3; then
		sudo ovs-vsctl del-port $BR_EX ex-$BR
	fi
    sudo ovs-vsctl del-port $BR_PHY eth1-$BR
    sudo ovs-vsctl del-port $BR phy1-$BR
	sudo ovs-vsctl del-port $BR phy2-$BR
	_status
	if [ "$?" == "0" ]; then
		echo "Error 200: Removing connections failed."
		return 200
	fi

	# remove veth pairs
	echo "Removing veth pairs..."
	sudo ip link del phy1-$BR
	sudo ip link del phy2-$BR
	_status
	if [ "$?" == "4" ]; then
		echo "Error 204: Removing veth pairs failed."
		return 204
	fi

    # remove $BR
    echo "Removing $BR..."
    sudo ovs-vsctl del-port $BR $IF
    sudo ip link set dev $BR down
    sudo ovs-vsctl del-br $BR
    _status
    if [ "$?" == "3" ]; then
        echo "Error 203: Removing $BR failed."
        return 203
    fi

	# remove $BR_SCRIPT
	echo "Removing $BR_SCRIPT..."
	sudo rm -f $SCRIPTS/$BR_SCRIPT

	# restore $IF_SCRIPT
	echo "Restoring $IF_SCRIPT..."
	sudo cp $SCRIPTS_BACKUP/$IF_SCRIPT.backup $SCRIPTS/$IF_SCRIPT
	_status
	if [ "$?" == "2" ]; then
		echo "Error 202: Restoring $IF_SCRIPT failed."
		return 202
	fi

    # restart network service
    echo "restarting network service..."
    sudo service network restart

	# return
	echo "$EXEC is successfully uninstalled."
	return 0
}


# Main
# ====

# execute functions
if [ "$1" == 'status' ]; then
    status
    exit $?
elif [ "$1" == 'install' ]; then
    install
    exit $?
elif [ "$1" == 'uninstall' ]; then
    uninstall
    exit $?
elif [ "$1" == '--help' ]; then
    help
    exit $?
else
    echo -e "Usage:\t$EXEC COMMAND"
    echo -e "\t$EXEC [OPTIONS]"
    echo -e "Try '$EXEC --help' for more information."
    exit 0
fi
