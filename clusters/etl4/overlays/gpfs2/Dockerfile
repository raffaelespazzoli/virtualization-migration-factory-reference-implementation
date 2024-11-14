FROM quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:c1ceb42f3e7f2d238fe59811776b24c14ffcef8ef792dc989ac62332fbbb8ccd

RUN rpm-ostree install pcs pacemaker fence-agents-all lvm2-lockd gfs2-utils dlm && \
  systemctl enable pcsd.service sanlock.service lvmlockd.service && \
  ostree container commit