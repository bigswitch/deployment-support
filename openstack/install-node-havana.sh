#!/usr/bin/env bash
#
# vim: tabstop=4 shiftwidth=4 softtabstop=4
#
# Copyright 2013, Big Switch Networks, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#
#

# USAGE
#   ./install-node.sh <comma-separated-list-of-controllers>
#
# e.g.
#   ./install-node.sh 192.168.1.1,192.168.1.2
USAGE="$0 <comma-separated-list-of-controllers>"

DATE=$(date +"%Y%m%d%H%M")
exec >  >(tee -a install-node-havana-log-$DATE.log | grep -v '^+') 
exec 2> >(tee -a install-node-havana-log-$DATE.log | grep -v '^+' >&2) 
trap "sleep 1" exit
set -x
set -e

umask 022

# Globals
set -e
NETWORK_CONTROLERS=
OVS_BRIDGE=br-int


# Process args
NETWORK_CONTROLERS=$1
echo -n "Configuring OVS managed by the openflow controllers:"
echo ${NETWORK_CONTROLERS}
if [ "${NETWORK_CONTROLERS}"x = ""x ] ; then
    echo "USAGE: $USAGE" 2>&1
    echo "  >  No Network Controller specified." 1>&2
    exit 1
fi

# OVS
(
  # remove existing version of openvswitch
  sudo apt-get purge -y .*openvswitch.*
  # install openvswitch
  kernel_version=`cat /proc/version | cut -d " " -f3`
  sudo apt-get -fy install libtool \
       pkg-config m4 autoconf autotools-dev bridge-utils
  sudo apt-get -fy install make fakeroot dkms \
       openvswitch-datapath-lts-raring-dkms \
       openvswitch-datapath-lts-raring-source \
       openvswitch-common=1.4* \
       openvswitch-switch=1.4* \
       linux-headers-$kernel_version
)
# Create local OVS bridge and configure it
sudo /etc/init.d/openvswitch-switch stop
sudo /etc/init.d/openvswitch-switch start
sudo ovs-vsctl --no-wait -- --if-exists del-br ${OVS_BRIDGE}
sudo ovs-vsctl --no-wait add-br ${OVS_BRIDGE}
sudo ovs-vsctl --no-wait br-set-external-id ${OVS_BRIDGE} bridge-id br-int

ctrls=
for ctrl in `echo ${NETWORK_CONTROLERS} | tr ',' ' '`
do
    ctrls="${ctrls} tcp:${ctrl}:6633"
done
echo "Adding Network controlers: " ${ctrls}
sudo ovs-vsctl --no-wait set-controller ${OVS_BRIDGE} ${ctrls}

# Add init scripts
cat <<'EOF' | sudo tee /etc/init/bsn-nova.conf 1>/dev/null
#
# BSN script for nova functions to execute on reboot
#

start on started rc
task
script
  exec 1>/tmp/bsn-nova.log 2>&1
  echo `date` bsn-nova-init "Started ..."

  i=100
  echo `date` bsn-nova-init "Waiting for OVS to be ready ${i} ..."
  while ! /usr/bin/ovs-vsctl show </dev/null 1>/dev/null 2>&1 ; do
        sleep 1
        i=$(($i - 1))
        test $i -gt 0 || { initctl stop --no-wait; exit 1; }
  done
  echo `date` bsn-nova-init "Waiting for OVS to be ready ${i} ... Done"

  #determine if quantum or neutron
  if [ -d "/etc/quantum" ]; then
    QUANT_OR_NEUTRON=quantum
  else
    QUANT_OR_NEUTRON=neutron
  fi
  if [ -f /etc/$QUANT_OR_NEUTRON/plugins/bigswitch/metadata_interface ] ; then
    METADATA_IF=`head -1 /etc/$QUANT_OR_NEUTRON/plugins/bigswitch/metadata_interface`
    METADATA_PORT=`head -1 /etc/$QUANT_OR_NEUTRON/plugins/bigswitch/metadata_port`
    echo `date` bsn-nova-init "Setting up metadata server address/nat on ${METADATA_IF}, port ${METADATA_PORT} ..."
    /sbin/ip addr add 169.254.169.254/32 scope link dev "${METADATA_IF}" || :
    /sbin/iptables -t nat -A PREROUTING -d 169.254.169.254/32 -p tcp -m tcp --dport 80 -j DNAT --to-destination 169.254.169.254:"${METADATA_PORT}" || :
    echo `date` bsn-nova-init "Setting up metadata server address/nat on ${METADATA_IF}, port ${METADATA_PORT} ... Done"
  fi

  if [ -f /etc/init/$QUANT_OR_NEUTRON-dhcp-agent.conf -o -f /etc/init/nova-compute.conf ] ; then
    echo `date` bsn-nova-init "Cleaning up tuntap interfaces ..."
    if [ -f /etc/init/$QUANT_OR_NEUTRON-dhcp-agent.conf ] ; then
      /usr/sbin/service $QUANT_OR_NEUTRON-dhcp-agent stop || :
    fi
    if [ -f /etc/init/nova-compute.conf ] ; then
      /usr/sbin/service nova-compute stop || :
      echo "resume_guests_state_on_host_boot=true" >> /etc/nova/nova.conf
      for qvo in `ifconfig -a | grep qvo | cut -d' ' -f1`
      do
        `sudo ovs-vsctl del-port br-int $qvo` || true
      done
      echo `date` bsn-nova-init "Cleaning up OVS ports ... Done"
      for qvb in `ifconfig -a | grep qvb | cut -d' ' -f1`
      do
        `sudo ip link set $qvb down` || true
        `sudo ip link delete $qvb` || true
      done
      echo `date` bsn-nova-init "Cleaning up veth interfaces ... Done"
      for qbr in `ifconfig -a | grep qbr | cut -d' ' -f1`
      do
        `sudo ip link set $qbr down` || true
        `sudo ip link delete $qbr` || true
      done
      echo `date` bsn-nova-init "Cleaning up bridges ... Done"
    fi

    /usr/bin/$QUANT_OR_NEUTRON-ovs-cleanup || :

    if [ -f /etc/init/nova-compute.conf ] ; then
     /usr/sbin/service nova-compute start || :
     sleep 3
     sed -i '$d' /etc/nova/nova.conf
    fi

    if [ -f /etc/init/$QUANT_OR_NEUTRON-dhcp-agent.conf ] ; then
      /usr/sbin/service $QUANT_OR_NEUTRON-dhcp-agent start || :
    fi

    echo `date` bsn-nova-init "Cleaning up tuntap interfaces ... Done"
  fi

  echo `date` bsn-nova-init "Started ... Done"
end script
EOF

# Done
echo "$0 Done."
echo
