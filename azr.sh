#!/bin/bash
if ! [ -f azr-creds.sh ]; then
  echo "File not found: aws-creds.sh"
  echo "Exiting program"
fi

bash -x azr-creds.sh
bash -x dm.sh azure
sleep 10

#if [ -f post-install.sh ]; then
#  . post-install.sh
#  func_tag_instances
#  func_mount_efs
#  func_config_zone
#else
#  echo "Post install file not found"
#fi
