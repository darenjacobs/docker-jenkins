# docker-jenkins

This will spin up a Docker swarm of 3 servers and Install
* 1 Jenkins master on the swarm manager
* 3 Jenkings agents (worker nodes) on per server
* 1 Docker registry
* 1 Visualizer - a visual representation of services in the Docker swarm

Upon successful completion it should show:
The Visualizer URL
The Jenkins URL
and the Jenkins admin user secret

Log in and install suggested plugins.  Do not change the password.  If changed you'll need to stop the jenkins agent, "docker service rm jenkins-agent", and create it again.
See "Create Jenkins Agent Service" section of dm.sh.

aws-creds.sh has holds the settings for creating the Docker machines.

Required Ports:
ssh 22
Jenkins 8080
EFS volume (NFS) 2049
Docker:
2376
2377
3376
5000
50000
7946
