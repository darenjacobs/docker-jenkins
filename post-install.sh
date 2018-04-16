#!/bin/sh

# tag nodes in which key / value pairs contain spaces
func_tag_instances() {
  TAGS=""
  nodes=$(docker-machine ls | awk 'NR > 1 {print $1}')
  for node in $nodes
  do
    instance_id=$(docker-machine inspect ${node} |grep InstanceId| cut -d'"' -f4)
    aws ec2 create-tags --resources ${instance_id} --tags $TAGS
  done
}

# Mount EFS locally
func_mount_efs(){
  efs_ip=172.18.31.7
  efs_mount_dir=/home/ec2-user/docker_efs_mount
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

  output="$( sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${efs_ip}:/ ${efs_mount_dir} 2>&1 1>&3)"
  exitcode="${?}"
  if [ $exitcode -ne 0 ]; then
    echo "Mount operation failed: $output"
    echo "Function: ${FUNCNAME[0]}"
    exit ${exitcode}
  fi
}

func_config_zone(){
  basename=lx-dkr

  for zone in a
  do
    nodes=$(docker-machine ls |grep ${basename}${zone}| awk '{print $1}')

    # Check if docker_home exists
    func_test_docker_root(){
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

    # Check if sym link exists
    func_test_symlink(){
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

    # Stop the nodes
    func_stop_nodes(){
      # check if it's running
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

    func_create_symlink(){
      exec 3>&1
      func_test_symlink
      if [ -d ${efs_mount_dir}/docker ] ; then
        output="$(sudo ln -s ${efs_mount_dir}/docker ${efs_mount_dir}/docker_az${zone} 2>&1 1>&3)"
        exitcode="${?}"
        if [ $exitcode -ne 0 ]; then
          echo "Error creating EFS dir: $output"
          echo "Function: ${FUNCNAME[0]}"
          exit ${exitcode}
        fi
      else
        echo "${efs_mount_dir}/docker Does not exist! Could not create symbolic link.  Zone: ${zone^^}"
        echo "Function: ${FUNCNAME[0]}"
      fi
    }

    # Start the nodes
    func_start_nodes(){
      # check if it's stopped
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
    func_create_symlink
    func_start_nodes
  done
}
