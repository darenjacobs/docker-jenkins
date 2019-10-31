# docker-jenkins
```
Deploy instructions:
./aws.sh |& tee docker-install.log
or
./azr.sh |& tee docker-install.log

This will spin up a Docker swarm of 3 servers and Install
* 1 Jenkins leader on the swarm manager
* 3 Jenkings agents (worker nodes), one per server
* 1 Docker registry
* 1 Visualizer - a visual representation of services in the Docker swarm
IN ZONES A, B and C

Upon successful completion STDOUT should show:
The Visualizer URL
The Jenkins URL
and the Jenkins admin user secret
**see: Docker-info.txt**
```

## Jenkins Configuration:
**NOTA BENE:** The one manual step:  After installation completes JENKINS_HOME should be pointed to /vol1/docker/jenkins by way of symbolic link.  I.e., e.g. with AWS zone A, /vol1/docker_aza should be a sym link to /vol1/docker
> To do this:
 1. In the AWS console stop the nodes in the zone(For Zone A): stop lx-dkrad0 lx-dkrad1, lxdkrad2
 2. SSH to one of the nodes in any other zone; docker-machine ssh lx-dkrbd0
 3. sudo rm -rf /vol1/docker_aza ; sudo ln -s /vol1/docker /vol1/docker_aza
 4. Start the nodes from the AWS console
 5. Repeat this for Zones B and C
For new environments with a new EFS/NFS volume:
Log in using the admin password from Docker-info.txt and install suggested plugins.  Do not change the password. If the password changed you'll need to stop the jenkins agent, "docker service rm jenkins-agent", and create it again.

See "Create Jenkins Agent Service" section of dm.sh.

## Environment variables:
```
aws-creds.sh has holds the environment variables settings for creating the Docker machines.
see aws-creds-template.sh.
In regard to variable AWS_SECURITY_GROUP, the ID (sg-*) does not work.  The name must be used.
```

## Required Open Ports:
```
* ssh 22
* Jenkins 8080
* EFS volume (NFS) 2049
* Docker:
* 2376
* 2377
* 3376
* 5000
* 50000
* 7946
```

## Requirements for Docker controller Node (currently lx-dkrctrld)
```
* The Docker Control server should be running:
* Docker
* Docker Machine
* Docker Compose
* NFS Utils
* AWS cli
* Python 2.7 or higher

Note: because this controler lx-dkrctrld.fhlbny.net is in Availability Zone A: it's IP address is 172.18.31.7.  If it were in a different AZ, it's IP would be different.  This is until we can use DNS for EFS internally.
```

## Misc:
```
The keypair is created by docker-machine and put in ~/.docker/machine/machines/$MACHINE_NAME/id_rsa
Use docker-machine rm DOCKER_MACHINE_NAME which will remove keypair from AWS
```

TODO:
* ~~Install aws-cli~~
* ~~Automate the manual steps to sym link docker root directory~~
* ~~[Tagging:](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-tags.html) aws ec2 create-tags --resources ami-78a54011 --tags Key=Stack,Value=production~~
* Cron job to test if Jenkins is running on primary zone nodes, if not spin up nodes on backup zone.
* Replicate lx-dkrctrld so it's not a single point of failure
