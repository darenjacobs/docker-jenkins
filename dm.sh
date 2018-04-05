#!/bin/bash
# # # NOTES # # #
# The keypair is created by docker-machine and put in ~/.docker/machine/machines/$MACHINE_NAME/id_rsa
# Delete this keypair when done
# the security group ID (sg-*) does not work.  Must use the name

set -euo pipefail

start=$(date +%s)

cloud_provider=$1
JENKINS_PORT=8080
VIZ_PORT=80
SWARM_PORT=2377
swarm_manager=""
nodes=3
export root_dir=/vol1
export docker_dir=${root_dir}/docker
export workspace_dir=${docker_dir}/workspace
export machines_dir=${docker_dir}/machines
export jenkins_dir=${docker_dir}/jenkins

func_aws(){

  if [ -f aws-creds.sh ]; then
    source aws-creds.sh
  else
    echo "AWS credentials file not found"
    exit 1
  fi

  # Cannot use DNS name for EFS.
  if [ $AWS_AVAILABILITY_ZONE == "a" ]; then
    efs_ip=172.18.7.217
  elif [ $AWS_AVAILABILITY_ZONE == "b" ]; then
    efs_ip=172.18.67.235
  else
    echo "Unrecognized Availability Zone for EFS volume"
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
  echo "Mounting up EFS Volume on all docker machines"
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

  # Using one node (swarm manager) set up the docker directory which is shared by all docker machines
  echo "Configuring docker directory using swarm manager $swarm_manager"
  eval $(docker-machine env $swarm_manager)
  docker-machine ssh $swarm_manager "if [ -d ${docker_dir} ]; then sudo rm -rf ${docker_dir}; fi && \
    sudo mkdir -p ${jenkins_dir} ${workspace_dir} && \
    sudo chown -R ubuntu:ubuntu ${docker_dir} && \
    sudo chmod 777 ${workspace_dir} && \
    exit"
  docker-machine scp -r $HOME/.docker/machine/machines ${swarm_manager}:${docker_dir}

}

func_azure() {

  if [ -f azr-creds.sh ]; then
    source azr-creds.sh
  else
    echo "Azure credentials file not found"
    exit 1
  fi

  basename=azr-

  # Create docker cluster, set first one as manager
  echo "Creating Azure docker machines"
  for (( i = 0; i < nodes; i++ ));
  do
    docker-machine -D create --driver azure \
      --azure-subscription-id $SUB_ID \
      --azure-size $AZURE_SIZE \
      --azure-location $AZURE_LOCATION \
      --azure-ssh-user $AZURE_SSH_USER \
      ${basename}${i}

    func_swarm_mgr
  done

  echo "Creating Docker directory on all nodes"
  for (( i = 0; i < nodes; i++ ));
  do
    eval $(docker-machine env ${basename}${i})
    docker-machine ssh ${basename}${i} "sudo mkdir -p ${jenkins_dir} ${workspace_dir} && \
      sudo chown -R ubuntu ${docker_dir} && \
      exit"
    docker-machine scp -r $HOME/.docker/machine/machines ${basename}${i}:${docker_dir}
  done

}

func_swarm_mgr() {

    # Set the first node to the swarm manager
    if [ -z $swarm_manager ];
    then
      echo "Setting swarm manager to ${basename}${i}"
      swarm_manager=${basename}${i}
    fi
}

if [ $cloud_provider == "aws" ]; then
  func_aws
elif [ $cloud_provider == "azure" ] ; then
  func_azure
else
  echo "Invalid argument."
  echo "Usage: $0 [aws | azure]"
  exit 1
fi

echo "Docker machine configuration : Set ubuntu user install apps"
for (( i = 0; i < nodes; i++ ));
do
  eval $(docker-machine env ${basename}${i})

  # enable ubuntu user to run docker commands
  docker-machine ssh ${basename}${i} "sudo usermod -aG docker ubuntu"

  # Install maven and Git
  docker-machine ssh ${basename}${i} "apt-cache search maven && sudo apt-get install -y \
    maven \
    git \
    ansible \
    default-jre \
    default-jdk \
    && exit"

done

# Initialize the swarm
echo "Initial Swarm"
eval $(docker-machine env $swarm_manager)
docker swarm init --advertise-addr $(docker-machine ip $swarm_manager)
docker-machine ls
docker node ls


# Join the nodes to the swarm
TOKEN=$(docker swarm join-token -q manager)

echo "Join nodes to swarm"
for (( i = 1; i < nodes; i++ ));
do
  eval $(docker-machine env ${basename}${i})
  docker-machine ls

  if [ $cloud_provider == "azure" ]; then
    docker swarm join --token $TOKEN -- advertise-addr $(docker-machine ip ${basename}${i}) $(docker-machine ip $swarm_manager):$SWARM_PORT || true
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

docker service ps registry


# Jenkins Service
echo "Create Jenkins Service"
eval $(docker-machine env $swarm_manager)
export swarm_manager_ip=$(docker-machine ip $swarm_manager)
docker-compose up -d

echo "docker compose ps"
docker-compose ps

docker-compose push || true # expected http error

docker stack deploy -c docker-compose.yml jenkins

echo "docker service ps jenkins"
docker service ps jenkins_jenkins

# Get Docker admin password && make Docker fault tolerant
echo "get Admin password"
eval $(docker-machine env $swarm_manager)
sleep 240
NODE=$(docker service ps -f desired-state=running jenkins_jenkins | tail -1 | awk '{print $4}')
eval $(docker-machine env $NODE)
file=$(docker-machine ssh $NODE "sudo find ${jenkins_dir} -name 'initialAdminPassword'")
while [ -z $file ]
do
  sleep 20
  file=$(docker-machine ssh $NODE "sudo find ${jenkins_dir} -name 'initialAdminPassword'")
done
secret=$(docker-machine ssh $NODE "sudo cat $file")

# Jenkins Agent
echo "Create Jenkins Agent Service"
export USER=admin && export PASSWORD=$secret
docker service create \
  --name jenkins-agent \
  -e COMMAND_OPTIONS="-master http://$(docker-machine ip $swarm_manager):$JENKINS_PORT/jenkins \
  -username $USER -password $PASSWORD -labels 'docker' -executors 2 -fsroot /workspace" \
  --mount "type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock" \
  --mount "type=bind,src=${workspace_dir},dst=/workspace" \
  --mount "type=bind,src=${machines_dir},target=/machines" \
  --mode global vfarcic/jenkins-swarm-agent


clear
echo "Visualizer: http://$viz_node"
echo "Jenkins: http://${swarm_manager_ip}:8080/jenkins"
echo "Jenkins password: $secret"
end=$(date +%s)
runtime=$(python -c "print '%u:%02u' % ((${end} - ${start})/60, (${end} - ${start})%60)")

echo "Runtime: $runtime"
