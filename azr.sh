#!/bin/bash
if ! [ -f azr-creds.sh ]; then
  echo "File not found: aws-creds.sh"
  echo "Exiting program"
fi

bash -x dm.sh azure |& tee docker-install.log
