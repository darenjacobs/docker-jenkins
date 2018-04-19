#!/bin/bash
for zone in a b c
do
  if ! [ -f aws-creds.sh ]; then
    echo "File not found: aws-creds.sh"
    echo "Exiting program"
  fi
  export zone=${zone}
  bash -x aws-creds.sh
  bash -x dm.sh aws |& tee docker-install.log
  sleep 10
done

if [ -f post-install.sh ]; then
  . post-install.sh
  func_tag_instances
  func_mount_efs
  func_config_zone
else
  echo "Post install file not found"
fi
