#!/bin/bash

#sudo apt-get install libs3-2
# ./build_fe.sh ubuntu-trusty-tahr
# os_version is "Ubuntu 16.04 server 64bit" ,"Ubuntu 14.04 server 64bit", "CentOS 7.3 64bit" ... juste the os_version was accepted by Flexible Engine

BASENAME="centos-6"
IMG_URL=http://cloud.centos.org/centos/6.6/images/CentOS-6-x86_64-GenericCloud.qcow2
#Fe variables
OS_VERSION="CentOS 6.8 64bit"
MINDISK=40
MINRAM=1024
BUCKET=factory
AZ_NAME=eu-west-0a
BUILDMARK="$(date +%Y-%m-%d-%H%M%S)"
TMP_IMG_NAME="$BASENAME-tmp-$BUILDMARK"
IMG_NAME="$BASENAME-$BUILDMARK"
IMG=$(echo "${IMG_URL##*/}")

source ../../lib/functions.sh

TMP_DIR=guest-centos-6

if [ -f "$IMG" ]; then
    rm $IMG
fi

wget -q $IMG_URL

if [ ! -d "$TMP_DIR" ]; then
    mkdir $TMP_DIR
fi

guestmount -a $IMG -i $TMP_DIR

if [ "$?" != "0" ]; then
  echo "Failed to guestmount image"
  exit 1
fi

echo "sed -i \"s/name: centos/name: cloud/\" $TMP_DIR/etc/cloud/cloud.cfg"
sed -i "s/name: centos/name: cloud/" $TMP_DIR/etc/cloud/cloud.cfg

echo "sed -i \"s/- resizefs/- resolv-conf/\" $TMP_DIR/etc/cloud/cloud.cfg"
sed -i "s/- resizefs/- resolv-conf/" $TMP_DIR/etc/cloud/cloud.cfg

echo "guestunmount $TMP_DIR"
guestunmount $TMP_DIR

unset OS_USERNAME
unset OS_PASSWORD
unset OS_DOMAIN_NAME
unset OS_TENANT_NAME
unset OS_AUTH_URL
unset OS_REGION_NAME
unset OS_TENANT_ID
unset OS_IDENTITY_API_VERSION
unset OS_ENDPOINT_TYPE
unset OS_INTERFACE
source ~/honey.sh


check_bucket $BUCKET
PRECHECK=$?
if [ $PRECHECK -ne 0 ] ; then
  echo "======create the bucket"
 s3 create $BUCKET
else
  echo "======= the bucket "
  echo $BUCKET
  echo "existed"
fi

#upload image to S3
s3 put $BUCKET/$TMP_IMG_NAME.qcow2 filename=$IMG >& /dev/null


TOKEN=$(get_token)

create_image_via_s3 $TOKEN

echo "===========Wait for image will be active================="

sleep 40

TMP_IMG_ID=$(openstack image list | grep $TMP_IMG_NAME | awk {'print $2'})>/dev/null 2>&1

wait_image_active $TMP_IMG_ID

#create keypair

create_keypair $BUILDMARK

#create vpc, net and subnet for test

VPC_ID=$(create_vpc $TOKEN $BUILDMARK)

NET_ID=$(create_net $TOKEN $VPC_ID $BUILDMARK)

#boot vm and bootstap
openstack server create --image $TMP_IMG_ID --flavor t2.micro --availability-zone $AZ_NAME --key-name mykey-${BUILDMARK} --nic net-id=$NET_ID ${IMG_NAME}-tmp  || exit 1

IP=$(openstack floating ip create admin_external_net | grep 'floating_ip_address' | awk {'print $4'})

openstack server add floating ip ${IMG_NAME}-tmp $IP

ansible_bootstrap $IP

## create image

IMG_ID=$(create_image_via_ecs $TOKEN ${IMG_NAME} ${IMG_NAME}-tmp)

#IMG_ID=$(openstack image list | grep "${IMG_NAME}" | awk {'print $2'}) >/dev/null 2>&1 || exit 1


######### Purge Resources ##################
delete_image $TOKEN $TMP_IMG_ID

openstack server delete ${IMG_NAME}-tmp>/dev/null 2>&1

rm -rf $IMG

sleep 60

release_floating_ip

delete_keypair $BUILDMARK


#tests image

if [ -z $IMG_ID ]
 then
 exit 1
fi

echo "========Test for image : " $IMG_ID "======================================"
export NOSE_IMAGE_ID=$IMG_ID

export NOSE_FLAVOR=t2.small

export NOSE_NET_ID=$NET_ID

export NOSE_AZ=$AZ_NAME

pushd ../../test-tools/pytesting_os_fe/

nosetests --nologcapture

popd

##delete vpc

delete_all_net $TOKEN $VPC_ID $NET_ID
echo "================END==================================================="
echo "IMG_ID for image '$IMG_NAME': $IMG_ID"



