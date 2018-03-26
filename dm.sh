#!/bin/bash
# # # NOTES # # #
# The keypair is created by docker-machine and put in ~/.docker/machine/machines/$MACHINE_NAME/id_rsa
# Delete this keypair when done
# the security group ID (sg-*) does not work.  Must use the name

set -euf -o pipefail

if [ -f aws-creds.sh ]; then
  source aws-creds.sh
else
  echo "AWS credentials file not found"
  exit 0
fi

JENKINS_PORT=8080
VIZ_PORT=80
SWARM_PORT=2377
basename=aws-
swarm_manager=""
nodes=3

# Create docker cluster, set first one as manager
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

  # Set the first node to the swarm manager
  if [ -z $swarm_manager ];
  then
    swarm_manager=${basename}${i}
  fi
done

# Create Docker directories on nodes, src is not my local machine, but the docker-machine
for (( i = 0; i < nodes; i++ ));
do
  eval $(docker-machine env ${basename}${i})
  docker-machine ssh ${basename}${i} "sudo mkdir -p /docker/jenkins /docker/workspace /docker/machines \
    && sudo chmod -R 777 /docker && exit"
  docker-machine scp -r $HOME/.docker/machine/machines ${basename}${i}:/docker/machines/

  # Install maven and Git
  docker-machine ssh ${basename}${i} "apt-cache search maven && sudo apt-get install maven git -y && exit"

done

# Initialize the swarm
docker-machine env $swarm_manager
eval $(docker-machine env $swarm_manager)
docker swarm init --advertise-addr $(docker-machine ip $swarm_manager)
docker-machine ls


# Join the nodes to the swarm
TOKEN=$(docker swarm join-token -q manager)

for (( i = 1; i < nodes; i++ ));
do
  eval $(docker-machine env ${basename}${i})
  docker-machine ls

  docker swarm join --token $TOKEN \
    --advertise-addr $(docker-machine ip ${basename}${i}) \
    $(docker-machine ip $swarm_manager):$SWARM_PORT
done

sleep 10

# Install Docker visualizer on Swarm manager
eval $(docker-machine env $swarm_manager)
docker service create \
  --name=viz \
  --publish=${VIZ_PORT}:8080/tcp \
  --constraint=node.role==manager \
  --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  dockersamples/visualizer

docker node ls

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

docker-compose push || true

docker stack deploy -c docker-compose.yml jenkins

echo "DOCKER SERVICE PS"
docker service ps jenkins_jenkins
sleep 20

# Get Docker admin password && make Docker fault tolerant
eval $(docker-machine env $swarm_manager)
sleep 20
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
echo $secret
echo "Visualizer: http://$swarm_manager"
echo "Jenkins: http://${swarm_manager}:8080/jenkins"
