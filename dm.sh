#!/bin/bash

set -euo pipefail

start=$(date +%s)

cloud_provider=$1
JENKINS_PORT=8080
VIZ_PORT=80
SWARM_PORT=2377
swarm_manager=""
nodes=${num_nodes:-3}
AWS_AVAILABILITY_ZONE=${AWS_AVAILABILITY_ZONE:-} # this bothers me but set dirs func breaks Azure func
jpass=${jpass:-}
THIS_ZONE=${THIS_ZONE:-}


func_set_dirs() {
  export root_dir=/vol1
  if [ -z ${AWS_AVAILABILITY_ZONE} ]; then
    export docker_dir=${root_dir}/docker
  else
    export docker_dir=${root_dir}/docker_az${AWS_AVAILABILITY_ZONE}
  fi
  export workspace_dir=${docker_dir}/workspace
  export machines_dir=${docker_dir}/machines
  export jenkins_dir=${docker_dir}/jenkins
}

func_swarm_mgr() {

    # Set the first node to the swarm manager
    if [ -z $swarm_manager ];
    then
      echo "Setting swarm manager to ${basename}${i}"
      swarm_manager=${basename}${i}
    fi
}

func_config_dirs() {

  # Using one node (swarm manager) set up the docker directory which is shared by all docker machines
  echo "CONFIGURING DOCKER DIRECTORY USING SWARM MANAGER $swarm_manager"
  eval $(docker-machine env $swarm_manager)
  docker-machine ssh $swarm_manager "if [ -d ${docker_dir} ]; then sudo rm -rf ${docker_dir}; fi && \
    sudo mkdir -p ${jenkins_dir} ${workspace_dir} && \
    sudo chown -R ubuntu:ubuntu ${docker_dir} && \
    sudo chmod 777 ${workspace_dir} && \
    exit"
  docker-machine scp -r $HOME/.docker/machine/machines ${swarm_manager}:${docker_dir}
}


func_aws(){

  # Get AWS variables
  if [ -f aws-creds.sh ]; then
    source aws-creds.sh
  else
    echo "AWS credentials file not found!"
    echo "Exiting program"
    exit 1
  fi

  # Set root (EFS) and jenkins related directories
  func_set_dirs

  # Cannot use DNS name for EFS. Must get IP address
  if ! [ -z $AWS_EFS_IP ]; then
    efs_ip=$AWS_EFS_IP
    echo $efs_ip
  else
    echo "Unable to obtain IP for EFS volume!"
    echo "Exiting program"
    exit 1
  fi

  basename=lx-dkr${AWS_AVAILABILITY_ZONE}d

  # Create docker cluster, set first one as manager
  echo "Creating AWS docker machines"
  for (( i = 0; i < nodes; i++ ));
  do
    AWS_TAGS=$AWS_TAGS,Name,${basename}${i}
    docker-machine -D create --driver amazonec2 \
      --amazonec2-use-private-address \
      --amazonec2-access-key $AWS_SECRET_KEY_ID \
      --amazonec2-secret-key $AWS_SECRET_ACCESS_KEY \
      --amazonec2-region $AWS_DEFAULT_REGION \
      --amazonec2-zone $AWS_AVAILABILITY_ZONE \
      --amazonec2-vpc-id $AWS_VPC_ID \
      --amazonec2-subnet-id $AWS_SUBNET_ID \
      --amazonec2-security-group $AWS_SECURITY_GROUP \
      --amazonec2-tags $AWS_TAGS \
      --amazonec2-instance-type $AWS_INSTANCE_TYPE \
      ${basename}${i} ;

    func_swarm_mgr
  done

  # Mount EFS volume on all docker machines
  echo "MOUNTING EFS VOLUME ON ALL DOCKER MACHINES"
  for (( i = 0; i < nodes; i++ ));
  do
    eval $(docker-machine env ${basename}${i})
    docker-machine ssh ${basename}${i} "sudo apt-get install -y nfs-common && \
      sudo mkdir ${root_dir} && \
      sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${efs_ip}:/ ${root_dir} && \
      sudo chmod o+w /etc/fstab && \
      sudo echo '${efs_ip}:/ ${root_dir} nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 0 0' >> /etc/fstab && \
      sudo chmod o-w /etc/fstab && \
      exit"
  done

  func_config_dirs

  THIS_ZONE=$AWS_AVAILABILITY_ZONE
}

func_azure() {

  if [ -f azr-creds.sh ]; then
    source azr-creds.sh
  else
    echo "Azure credentials file not found!"
    echo "Exiting program"
    exit 1
  fi

  # Set root (EFS) and jenkins related directories
  func_set_dirs

  # Set basename for nodes in cluster
  basename=lx-azr-dkr

  # Create docker cluster, set first one as manager
  echo "Creating Azure docker machines"
  for (( i = 0; i < nodes; i++ ));
  do
    docker-machine -D create --driver azure \
      --azure-subscription-id $SUB_ID \
      --azure-size $AZURE_SIZE \
      --azure-location $AZURE_LOCATION \
      --azure-resource-group $AZURE_RESOURCE_GROUP \
      --azure-vnet $AZURE_VNET \
      --azure-ssh-user $AZURE_SSH_USER \
      ${basename}${i}

    func_swarm_mgr
  done

  # Mount EFS volume on all docker machines
  echo "MOUNTING CIFS VOLUME ON ALL DOCKER MACHINES"
  for (( i = 0; i < nodes; i++ ));
  do
    eval $(docker-machine env ${basename}${i})
    docker-machine ssh ${basename}${i} "sudo apt-get install -y cifs-utils nfs-common && \
      sudo mkdir ${root_dir} && \
      sudo mount -t cifs ${AZURE_CIFS} ${root_dir} -o vers=3.0,username=${AZURE_MOUNT_USER},password=${AZURE_MOUNT_PASS},dir_mode=0777,file_mode=0777,sec=ntlmssp
      sudo chmod o+w /etc/fstab && \
      sudo echo '${AZURE_CIFS} ${root_dir} cifs -o vers=3.0,username=${AZURE_MOUNT_USER},password=${AZURE_MOUNT_PASS},dir_mode=0777,file_mode=0777,sec=ntlmssp' >> /etc/fstab && \
      sudo chmod o-w /etc/fstab && \
      exit"
  done

  func_config_dirs
}

# check if argument is aws or azure
if [ $cloud_provider == "aws" ]; then
  func_aws
elif [ $cloud_provider == "azure" ] ; then
  func_azure
else
  echo "Invalid argument."
  echo "Usage: $0 [aws | azure]"
  exit 1
fi

echo "Docker machine configuration : allow ubuntu user to run docker commands"
for (( i = 0; i < nodes; i++ ));
do
  eval $(docker-machine env ${basename}${i})

  # enable ubuntu user to run docker commands
  docker-machine ssh ${basename}${i} "sudo usermod -aG docker ubuntu"

done

# Initialize the swarm
echo "Initialize Swarm"
eval $(docker-machine env $swarm_manager)
docker swarm init --advertise-addr $(docker-machine ip $swarm_manager)
docker-machine ls
docker node ls


# Join the nodes to the swarm
TOKEN=$(docker swarm join-token -q manager)

echo "JOIN NODES TO SWARM"
for (( i = 1; i < nodes; i++ ));
do
  eval $(docker-machine env ${basename}${i})
  docker-machine ls


  if [ $cloud_provider == "azure" ]; then
    docker swarm join --token $TOKEN --advertise-addr $(docker-machine ip ${basename}${i}) $(docker-machine ip $swarm_manager):$SWARM_PORT || true
    sleep 10
  else
    docker swarm join --token $TOKEN --advertise-addr $(docker-machine ip ${basename}${i}) $(docker-machine ip $swarm_manager):$SWARM_PORT
  fi
done

# Install Docker visualizer on Swarm manager
echo "create Visualizer service"
eval $(docker-machine env $swarm_manager)
docker service create \
  --name=viz \
  --publish=${VIZ_PORT}:8080/tcp \
  --constraint=node.role==manager \
  --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  dockersamples/visualizer

viz_node=$(docker service ps viz | tail -1 | awk '{print $4}')
viz_node=$(docker-machine ip $viz_node)

echo "create registry service"
eval $(docker-machine env $swarm_manager)
docker service create \
  --name registry \
  -p 5000:5000 \
  --mount "type=bind,src=${docker_dir},dst=/var/lib/registry" \
  --reserve-memory 100m registry

# Jenkins Service
echo "Create Jenkins Service"
eval $(docker-machine env $swarm_manager)
export swarm_manager_ip=$(docker-machine ip $swarm_manager)
docker-compose up -d

echo "docker compose ps"
docker-compose ps

docker-compose push || true # expected http error

docker stack deploy -c docker-compose.yml jenkins


# Set docker root owner to ubuntu/jenkins:
eval $(docker-machine env $swarm_manager)
docker-machine ssh $swarm_manager sudo chown -R ubuntu:ubuntu ${docker_dir}

# Make Docker fault tolerant
eval $(docker-machine env $swarm_manager)
NODE=$(docker service ps -f desired-state=running jenkins_jenkins | tail -1 | awk '{print $4}')

# Get Admin Password if jpass is not set
if [ -z $jpass ]; then
  # Give it time to install plugins, amount of time is iffy.
  sleep 240

  echo "Getting admin password"
  eval $(docker-machine env $NODE)
  file=$(docker-machine ssh $NODE "sudo find ${jenkins_dir} -name 'initialAdminPassword'")
  while [ -z $file ]
  do
    sleep 20
    file=$(docker-machine ssh $NODE "sudo find ${jenkins_dir} -name 'initialAdminPassword'")
  done
  secret=$(docker-machine ssh $NODE "sudo cat $file")
fi

nodes=${num_nodes:-3}
# Jenkins Agent
echo "Create Jenkins Agent Service"
export USER=admin && export PASSWORD=${jpass:-$secret}
docker service create \
  --name jenkins-agent \
  -e COMMAND_OPTIONS="-master http://$(docker-machine ip $swarm_manager):$JENKINS_PORT/jenkins \
  -username $USER -password $PASSWORD -labels 'docker' -executors 20 -fsroot /workspace" \
  -e JAVA_HOME="/usr/lib/jvm/default-jvm/jre" \
  --mount "type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock" \
  --mount "type=bind,src=${workspace_dir},dst=/workspace" \
  --mount "type=bind,src=${machines_dir},target=/machines" \
  --mode global darenjacobs/jenkins-swarm-agent:0.04


# Display / Log access info
if ! [ -f Docker-info.txt ]; then
  touch Docker-info.txt
fi
end=$(date +%s)
runtime=$(python -c "print '%u:%02u' % ((${end} - ${start})/60, (${end} - ${start})%60)")

clear
echo "######################################################" >> Docker-info.txt
if ! [ -z $THIS_ZONE ]; then echo "# Availbility Zone: $THIS_ZONE                                #" >> Docker-info.txt; fi
echo "# Visualizer: http://$viz_node                    #" >> Docker-info.txt
echo "# Jenkins: http://${swarm_manager_ip}:8080/jenkins          #" >> Docker-info.txt
echo "# Jenkins password: $PASSWORD #" >> Docker-info.txt
echo "# Runtime: $runtime                                     #" >> Docker-info.txt
echo "######################################################" >> Docker-info.txt
