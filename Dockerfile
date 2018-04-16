FROM jenkins/jenkins:lts
USER root
RUN echo "${bitbucket_ip} bitbucket.fhlbny.net bitbucket" >> /etc/hosts
RUN apt-get update && apt-get install -y maven git vim
RUN ln -s /usr/lib/jvm/java-8-openjdk-amd64 /usr/lib/jvm/default-jvm
ENV JAVA_HOME /usr/lib/jvm/default-jvm/jre
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN /usr/local/bin/install-plugins.sh < /usr/share/jenkins/ref/plugins.txt
