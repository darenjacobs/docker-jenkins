#!/usr/bin/env bash
export jpass=
export num_nodes=
export AWS_SECRET_KEY_ID=
export AWS_SECRET_ACCESS_KEY=
export AWS_DEFAULT_REGION=
export AWS_VPC_ID=
export AWS_SECURITY_GROUP=
export AWS_TAGS=
export AWS_INSTANCE_TYPE=

case $zone in
  a)
    export AWS_AVAILABILITY_ZONE=
    export AWS_SUBNET_ID=
    export AWS_EFS_IP=
    ;;
  b)
    export AWS_AVAILABILITY_ZONE=
    export AWS_SUBNET_ID=
    export AWS_EFS_IP=
    ;;
  c)
    export AWS_AVAILABILITY_ZONE=
    export AWS_SUBNET_ID=
    export AWS_EFS_IP=
    ;;
  *)
    echo "NO Availability Zone specified!"
    echo "exiting program"
    exit 1
esac
