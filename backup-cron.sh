#!/bin/sh

set -euo pipefail

BACKUP_LOG=/var/log/fhlbny/docker_backup.log
running_nodes=$(docker-machine ls |grep Running |cut -d ' ' -f 1) || running_nodes="no nodes"

func_mount_efs(){
  # Mount EFS locally
  efs_ip=
  efs_mount_dir=${HOME}/docker_efs_mount
  exec 3>&1

  if ! [ -d $efs_mount_dir ]; then
    output="$(mkdir $efs_mount_dir 2>&1 1>&3)"
    exitcode="${?}"
    if [ $exitcode -ne 0 ]; then
      echo "Error creating EFS dir: $output"
      echo "Function: ${FUNCNAME[0]}"
      exit ${exitcode}
    fi
  fi

  is_mounted=$(mount |grep $efs_ip) || is_mounted="not mounted"
  if [ "${is_mounted}" == "not mounted" ]; then
    output="$( sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${efs_ip}:/ ${efs_mount_dir} 2>&1 1>&3)"
    exitcode="${?}"
    if [ $exitcode -ne 0 ]; then
      echo "Mount operation failed: \nError output: $output"
      echo "Function: ${FUNCNAME[0]}"
      exit ${exitcode}
    fi
    echo "EFS volume mounted successfully"
  else
    echo "EFS volume is probably already mounted"
  fi
}

func_tar_docker(){
  exec 3>&1
  if [ -d ${efs_mount_dir}/docker ] && [ -d ${efs_mount_dir}/backups ]; then
    cd ${efs_mount_dir}
    output="$(sudo tar -zcvf backups/docker-$(date +%Y%m%d).tgz docker --exclude='builds' 2>&1 1>&3)"
    exitcode="${?}"
    if [ $exitcode -ne 0 ]; then
      echo "Error backing up docker directory: \nError output: $output"
      echo "Function: ${FUNCNAME[0]}"
      exit ${exitcode}
    fi
    sudo ls -al ${efs_mount_dir}/backups
    cd $HOME
    sudo umount ${efs_mount_dir}
  else
    echo "Required directories ${efs_mount_dir}/docker and ${efs_mount_dir}/backups do not exist! Could not back it up"
    echo "Function: ${FUNCNAME[0]}"
  fi
}

func_stop_nodes(){
  # Stop the running nodes
  for node in $running_nodes
  do
    docker-machine stop $node
  done
  sleep 60
}

func_start_nodes(){
  # Stop the running nodes
  sleep 120
  for node in $running_nodes
  do
    docker-machine start $node
  done
}

# Steps
# 1. Get a list of running nodes
# 2. Mount EFS
# 3. Shut them down
# 4. tar up Jenkins directory
# 5. Start up the nodes that were running


echo "#################" &>> $BACKUP_LOG
echo "Backup Log Date: $(date +%Y-%m-%d)" &>> $BACKUP_LOG
func_mount_efs &>> $BACKUP_LOG
if [ "${running_nodes}" != "no nodes" ]; then
  func_stop_nodes  | tee -a $BACKUP_LOG
fi
func_tar_docker | tee -a $BACKUP_LOG
if [ "${running_nodes}" != "no nodes" ]; then
  func_start_nodes  | tee -a $BACKUP_LOG
fi
echo "#################" &>> $BACKUP_LOG
echo " " &>> $BACKUP_LOG
echo " " &>> $BACKUP_LOG
