#!/bin/sh

func_tag_instances() {
  # This function tag nodes with key / value pairs that contain spaces. Docker-machine create cannot handle spaces.
  # Modify tags by editing tags.txt
  TAGS=$(cat tags.txt)
  nodes=$(docker-machine ls | awk 'NR > 1 {print $1}')
  for node in $nodes
  do
    instance_id=$(docker-machine inspect ${node} |grep InstanceId| cut -d'"' -f4)
    aws ec2 create-tags --resources ${instance_id} --tags="${TAGS}"
  done
}

func_mount_efs(){
  # Mount EFS locally
  efs_ip=172.18.31.7
  efs_mount_dir=$HOME/docker_efs_mount
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

  is_mounted=$(mount |grep $efs_ip)
  if [ -z ${is_mounted} ]; then
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

func_cleanup() {
  echo "I wasn't... I didn't... I was just usin' it for the.. for clean-up."
  func_mount_efs
  is_delete=$(ls ${efs_mount_dir}/*DELETEME |grep docker)
  if ! [ -z "${is_delete}" ]; then
    output="$(sudo rm -rf ${efs_mount_dir}/*DELETEME 2>&1 1>&3)"
    exitcode="${?}"
    if [ $exitcode -ne 0 ]; then
      echo "Error deleting docker zone directories in EFS volume: \nError output: $output"
      echo "Function: ${FUNCNAME[0]}"
      exit ${exitcode}
    fi
  else
    echo "There is nothing to clearnup"
  fi

  sleep 120
  ls -al ${efs_mount_dir}
  cd $HOME
  sudo umount ${efs_mount_dir}
}

func_config_zone(){
  func_mount_efs # Mount EFS as required by func_create_symlink
  # Steps of this function
  # 1. Check if the nodes in the zone have the docker application directory
  # 2. Check if the symbolic link to the docker application already exists
  # 3. Shut down the nodes in the zone
  # 4. Rename the application directory and create symbolic link to shared docker home
  # 5. Start up the nodes on the zone
  basename=lx-dkr

  for zone in a b c
  do
    nodes=$(docker-machine ls |grep ${basename}${zone}| awk '{print $1}')

    func_test_docker_root(){
      # Check if docker_home exists. Stop if it does not exist
      for node in $nodes
      do
        test=$(docker-machine ssh $node "if [ -d /vol1/docker ]; then echo "GO"; else echo "STOP"; fi")
        if [ $test == "STOP" ]; then
          echo "Docker directory /vol1/docker does not exist on $node.  Exiting Program"
          echo "Function: ${FUNCNAME[0]}"
          echo "TODO: retrieve from S3 bucket"
          exit 1
          break
        fi
      done
    }

    func_test_symlink(){
      # Check if sym link exists
      for node in $nodes
      do
        test=$(docker-machine ssh $node "if [ ! -L /vol1/docker_az${zone} ]; then echo "GO"; else echo "STOP"; fi")
        if [ $test == "STOP" ]; then
          echo "Docker directory symbolic link already exists on $node.  Exiting Program"
          echo "Function: ${FUNCNAME[0]}"
          exit 1
          break
        fi
      done
    }

    func_stop_nodes(){
      # check if the nodes are running and shut them down
      is_running=$(docker-machine ls |grep ${basename}${zone}|cut -d ' ' -f 15 |head -n 1)
      if [ ${is_running} == "Running" ]; then
        echo "Docker nodes in zone ${zone^^} are $is_running"
        echo "Shutting down zone ${zone^^} nodes."
      else
        echo "Error: Zone nodes are not in ${is_running} state"
        echo "Function: ${FUNCNAME[0]}"
      fi

      # Shut them down
      for node in $nodes
      do
        docker-machine stop $node
      done
    }

    func_rename_zone_docker_dir() {
      # Back up Zone's application directory just in case
      # This step is not necessary but it's easier than deleting it, which should happen at the end with rm -rf *DELETEME
      exec 3>&1
      if [ -d ${efs_mount_dir}/docker_az${zone} ] ; then
        output="$(sudo mv ${efs_mount_dir}/docker_az${zone} ${efs_mount_dir}/docker_az${zone}-$RANDOM-DELETEME 2>&1 1>&3)"
        exitcode="${?}"
        if [ $exitcode -ne 0 ]; then
          echo "Error backing up zone ${zone^^} docker directory: \nError output: $output"
          echo "Function: ${FUNCNAME[0]}"
          exit ${exitcode}
        fi
      fi
    }

    func_create_symlink(){
      exec 3>&1
      if [ -d ${efs_mount_dir}/docker ] ; then
        cd ${efs_mount_dir}
        output="$(sudo ln -s /vol1/docker docker_az${zone} 2>&1 1>&3)"
        exitcode="${?}"
        if [ $exitcode -ne 0 ]; then
          echo "Error creating EFS dir: \nError output: $output"
          echo "Function: ${FUNCNAME[0]}"
          exit ${exitcode}
        fi
      else
        echo "${efs_mount_dir}/docker Does not exist! Could not create symbolic link.  Zone: ${zone^^}"
        echo "Function: ${FUNCNAME[0]}"
      fi
    }

    func_start_nodes(){
      # At this point in the parent function the nodes should be stopped.  Check if they are stopped and start them.
      is_stopped=$(docker-machine ls |grep ${basename}${zone}|cut -d ' ' -f 15 |head -n 1)
      if [ ${is_stopped} == "Stopped" ]; then
        echo "Docker nodes in zone ${zone^^} are $is_stopped"
        echo "Starting zone ${zone^^} nodes."
      else
        echo "Error: Zone nodes are not in ${is_stopped} state"
        echo "Function: ${FUNCNAME[0]}"
      fi

      # Start them down
      for node in $nodes
      do
        docker-machine start $node
      done
    }


    func_test_docker_root
    func_test_symlink
    func_stop_nodes
    sleep 60
    func_rename_zone_docker_dir
    func_create_symlink
    func_start_nodes
  done
}

func_tag_instances
func_config_zone
func_cleanup
