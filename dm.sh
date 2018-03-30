#!/bin/bash
# # # NOTES # # #
# The keypair is created by docker-machine and put in ~/.docker/machine/machines/$MACHINE_NAME/id_rsa
# Delete this keypair when done
# the security group ID (sg-*) does not work.  Must use the name

set -euo pipefail

start=$(date +%s)

JENKINS_PORT=8080
VIZ_PORT=80
SWARM_PORT=2377
swarm_manager=""
nodes=3

func_aws(){

  if [ -f aws-creds.sh ]; then
    source aws-creds.sh
  else
    echo "AWS credentials file not found"
    exit 1
  fi

  basename=aws-

  # Create docker cluster, set first one as manager
      #--amazonec2-use-private-address \
  for (( i = 0; i < nodes; i++ ));
  do
    docker-machine -D create --driver amazonec2 \
      --amazonec2-access-key $AWS_SECRET_KEY_ID \
      --amazonec2-secret-key $AWS_SECRET_ACCESS_KEY \
      --amazonec2-region $AWS_DEFAULT_REGION \
      --amazonec2-zone $AWS_AVAILABILITY_ZONE \
      --amazonec2-vpc-id $AWS_VPC_ID \
      --amazonec2-subnet-id $AWS_SUBNET_ID \
      --amazonec2-security-group $AWS_SECURITY_GROUP \
      ${basename}${i} ;

    func_swarm_mgr
  done

  # Mount EFS volume - TODO: edit /etc/fstab
  for (( i = 0; i < nodes; i++ ));
  do
    eval $(docker-machine env ${basename}${i})
    docker-machine ssh ${basename}${i} "sudo apt-get install -y nfs-common && \
      sudo mkdir /docker && \
      sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${AWS_EFS_ID}.efs.${AWS_DEFAULT_REGION}.amazonaws.com:/ /docker && \
      sudo echo \"${AWS_EFS_ID}.efs.${AWS_DEFAULT_REGION}.amazonaws.com:/ /docker  nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 0 0\" >> /etc/fstab && \
      exit"
  done
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
}

func_swarm_mgr() {

    # Set the first node to the swarm manager
    if [ -z $swarm_manager ];
    then
      swarm_manager=${basename}${i}
    fi
}

if [ $1 == "aws" ]; then
  func_aws
elif [ $1 == "azure" ] ; then
  func_azure
else
  echo "Invalid argument."
  echo "Usage: $0 [aws | azure]"
  exit 1
fi

# Create Docker directories on nodes, src is not my local machine, but the docker-machine
for (( i = 0; i < nodes; i++ ));
do
  eval $(docker-machine env ${basename}${i})
  docker-machine ssh ${basename}${i} "sudo usermod -aG docker ubuntu"
  docker-machine ssh ${basename}${i} "sudo mkdir -p /docker/jenkins /docker/workspace /docker/machines \
    && sudo chown -R ubuntu /docker \
    && exit"
  docker-machine scp -r $HOME/.docker/machine/machines ${basename}${i}:/docker/machines/

  # Install maven and Git
  docker-machine ssh ${basename}${i} "apt-cache search maven && sudo apt-get install -y \
    maven \
    git \
    default-jre \
    default-jdk \
    && exit"

done

# Initialize the swarm
docker-machine env $swarm_manager
eval $(docker-machine env $swarm_manager)
docker swarm init --advertise-addr $(docker-machine ip $swarm_manager)
docker-machine ls
docker node ls


# Join the nodes to the swarm
TOKEN=$(docker swarm join-token -q manager)

for (( i = 1; i < nodes; i++ ));
do
  eval $(docker-machine env ${basename}${i})
  docker-machine ls

  docker swarm join --token $TOKEN \
    --advertise-addr $(docker-machine ip ${basename}${i}) \
    $(docker-machine ip $swarm_manager):$SWARM_PORT || true # For Azure because it's so bloody slow
  sleep 10
done

# Install Docker visualizer on Swarm manager
eval $(docker-machine env $swarm_manager)
docker service create \
  --name=viz \
  --publish=${VIZ_PORT}:8080/tcp \
  --constraint=node.role==manager \
  --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  dockersamples/visualizer

docker service ps viz

eval $(docker-machine env $swarm_manager)
docker service create \
  --name registry \
  -p 5000:5000 \
  --mount "type=bind,src=/docker,dst=/var/lib/registry" \
  --reserve-memory 100m registry

docker service ps registry


# Jenkins Service
eval $(docker-machine env $swarm_manager)
export swarm_manager_ip=$(docker-machine ip $swarm_manager)
docker-compose up -d

echo "DOCKER COMPOSE PS"
docker-compose ps

docker-compose push || true # expected http error

docker stack deploy -c docker-compose.yml jenkins

echo "DOCKER SERVICE PS"
docker service ps jenkins_jenkins

# Get Docker admin password && make Docker fault tolerant
eval $(docker-machine env $swarm_manager)
sleep 60
NODE=$(docker service ps -f desired-state=running jenkins_jenkins | tail -1 | awk '{print $4}')
eval $(docker-machine env $NODE)
file=$(docker-machine ssh $NODE "sudo find /docker/jenkins -name 'initialAdminPassword'")
secret=$(docker-machine ssh $NODE "sudo cat $file")

# Jenkins Agent
export USER=admin && export PASSWORD=$secret
docker service create \
  --name jenkins-agent \
  -e COMMAND_OPTIONS="-master http://$(docker-machine ip $swarm_manager):$JENKINS_PORT/jenkins \
  -username $USER -password $PASSWORD -labels 'docker' -executors 2" \
  --mount "type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock" \
  --mount "type=bind,src=/docker/workspace,dst=/workspace" \
  --mount "type=bind,src=/docker/machines,target=/machines" \
  --mode global vfarcic/jenkins-swarm-agent


clear
echo "Visualizer: http://$swarm_manager_ip"
echo "Jenkins: http://${swarm_manager_ip}:8080/jenkins"
echo "Jenkins password: $secret"
end=$(date +%s)
runtime=$(python -c "print '%u:%02u' % ((${end} - ${start})/60, (${end} - ${start})%60)")

echo "Runtime: $runtime"
