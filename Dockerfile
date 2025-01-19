FROM registry.access.redhat.com/ubi7/ubi:7.8
RUN yum install https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/e/epel-release-7-14.noarch.rpm -y && \
    yum install collectl-4.3.0-5.el7 pciutils hostname sysvinit-tools iostat iotop -y && \
    yum clean all
COPY ./entrypoint /root/
RUN chmod 741 /root/entrypoint.sh
CMD ["/root/entrypoint.sh"]