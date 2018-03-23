#!/bin/bash
# # # NOTES # # #
# The keypair is created by docker-machine and put in ~/.docker/machine/machines/$MACHINE_NAME/id_rsa
# Delete this keypair when done
# the security group ID does not work.  Have to use the name

set -euf -o pipefail

if [ -f aws-creds.sh ]; then
  source aws-creds.sh
else
  echo "AWS credentials file not found"
  exit 0
fi

JENKINS_PORT=8082
VIZ_PORT=8083
SWARM_PORT=2377
basename=aws-
swarm_manager=""
nodes=3

# Create docker cluster, set first one as manager
for (( i = 0; i < nodes; i++ ));
do
  docker-machine -D create --driver amazonec2 \
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
done

# Initialize the swarm
docker-machine env $swarm_manager
eval $(docker-machine env $swarm_manager)
docker swarm init --advertise-addr $(docker-machine ip $swarm_manager)
docker-machine ls


# Join the nodes to the swarm
TOKEN=$(docker swarm join-token -q worker)

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

# Registry
eval $(docker-machine env $swarm_manager)
docker service create \
  --name registry \
  -p 5000:5000 \
  --mount "type=bind,src=/docker,dst=/var/lib/registry" \
  --reserve-memory 100m registry

docker service ps registry


# Create services
docker network create --driver overlay proxy
docker network create --driver overlay go-demo
docker network ls
docker service create --name go-demo-db --network go-demo mongo
docker service ls

docker service create --name go-demo -e DB=go-demo-db \
  --network go-demo --network proxy vfarcic/go-demo
docker service ps go-demo

docker service create --name proxy \
  -p 80:80 -p 443:443 -p 8080:8080 --network proxy \
  -e MODE=swarm vfarcic/docker-flow-proxy

docker service ps proxy

curl "$(docker-machine ip $swarm_manager):8080/v1/docker-flow-proxy/reconfigure?serviceName=go-demo&servicePath=/demo&port=8080"
curl -i $(docker-machine ip $swarm_manager)/demo/hello

# Jenkins Service
eval $(docker-machine env $swarm_manager)
docker service create \
  --name jenkins \
  -p ${JENKINS_PORT}:8080 -p 50000:50000 -e JENKINS_OPTS="--prefix=/jenkins" \
  --mount "type=bind,src=/docker/jenkins,dst=/var/jenkins_home" \
  jenkins:alpine

docker service ps jenkins

sleep 10

# Get Docker admin password && make Docker fault tolerant
eval $(docker-machine env $swarm_manager)
sleep 20
NODE=$(docker service ps -f desired-state=running jenkins | tail -1 | awk '{print $4}')
eval $(docker-machine env $NODE)
file=$(docker-machine ssh $NODE "sudo find /docker/jenkins -name 'initialAdminPassword'")
secret=$(docker-machine ssh $NODE "sudo cat $file")
docker-machine ls

docker service ps jenkins

echo $secret
# Pause to install plugins - need to automae plugin installaion
echo "LOG IN TO JENKINS and install Plugins"
read -p "Press Enter to continue"

# Agent swarm
docker-machine -D create --driver amazonec2 \
  --amazonec2-region $AWS_DEFAULT_REGION \
  --amazonec2-zone $AWS_AVAILABILITY_ZONE \
  --amazonec2-vpc-id $AWS_VPC_ID \
  --amazonec2-subnet-id $AWS_SUBNET_ID \
  --amazonec2-security-group $AWS_SECURITY_GROUP \
  aws-test-0 ;

docker-machine ssh aws-test-0 "sudo mkdir -p /docker/workspace && sudo chown -R 777 /docker && exit"

eval $(docker-machine env aws-test-0)

docker swarm init --advertise-addr $(docker-machine ip aws-test-0)

docker run --name visualizer -d \
  -p ${VIZ_PORT}:8080 \
  -e HOST=$(docker-machine ip aws-test-0) \
  -e PORT=${VIZ_PORT} \
  -v /var/run/docker.sock:/var/run/docker.sock \
  dockersamples/visualizer


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

#export JENKINS_IP=$(docker-machine ip $swarm_manager)
#MASTER_USER=$USER MASTER_PASS=$secret docker stack deploy -c jenkins-swarm-agent.yml jenkins-agent

