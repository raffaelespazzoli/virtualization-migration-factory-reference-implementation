FROM rust:1.74.0 as builder
WORKDIR /usr/src
RUN cargo install envsub --root /usr/src
RUN curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
RUN curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash
FROM redhat/ubi9
RUN yum install -y git && \
    yum clean all
COPY --from=builder /usr/src/bin/envsub /usr/src/kustomize /usr/local/bin/helm /usr/local/bin/
CMD ["envsub"]