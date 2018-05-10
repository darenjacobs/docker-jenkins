#!/bin/bash
for zone in a b c
do
  if ! [ -f aws-creds.sh ]; then
    echo "File not found: aws-creds.sh"
    echo "Exiting program"
  fi
  export zone=${zone}
  bash -x aws-creds.sh
  bash -x dm.sh aws
  sleep 10
done

sleep 60
if [ -f aws-post-install.sh ]; then
  bash -x aws-post-install.sh
else
  echo "Post install file not found"
fi
cat Docker-info.txt
