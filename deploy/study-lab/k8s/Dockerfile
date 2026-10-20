# study-lab:k8s — the runner image for kind/k3s labs (CKA, CKAD, CKS, KCNA...).
#
# Docker-in-Docker: the lab's kind cluster lives INSIDE this container's own
# dockerd, never in the host's. That is why it needs --privileged (kind nodes
# are containers running systemd + containerd), and why `study-lab down`
# (docker rm -f -v) leaves nothing behind on the host. Mounting the host's
# docker socket instead would be lighter but hands every break_fix.sh root on
# the host's daemon — the opposite of "everything runs inside the container".
#
# Versions are pinned and checksummed; bump them together (docs/LABS-RUNNER.md).
FROM docker:29.9.0-dind@sha256:0b6d18a4a222e71c88be6034926b4f6cde2fc33c2218643d03ccfddc65995470

ARG TARGETARCH=amd64
ARG KIND_VERSION=v0.33.0
ARG KIND_SHA256_amd64=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
ARG KUBECTL_VERSION=v1.35.8
ARG KUBECTL_SHA256_amd64=874d5e72dbb819f43cff16bcd1e4f8bac5b7f2361fe1e55049b0a6c676fb0cbf
ARG HELM_VERSION=v4.3.0
ARG HELM_SHA256_amd64=86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb
# Node image matching the CKA v1.35 curriculum, from the kind v0.33.0 release notes.
ARG KIND_NODE_IMAGE=kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0

RUN apk add --no-cache bash coreutils curl jq git grep sed gawk findutils util-linux \
        procps ncurses openssl gettext vim nano less bash-completion tini \
 && curl -fsSLo /usr/local/bin/kind "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${TARGETARCH}" \
 && echo "${KIND_SHA256_amd64}  /usr/local/bin/kind" | sha256sum -c - \
 && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && echo "${KUBECTL_SHA256_amd64}  /usr/local/bin/kubectl" | sha256sum -c - \
 && curl -fsSLo /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
 && echo "${HELM_SHA256_amd64}  /tmp/helm.tgz" | sha256sum -c - \
 && tar -xzf /tmp/helm.tgz -C /tmp && mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm && rm -rf /tmp/helm.tgz /tmp/linux-* \
 && chmod +x /usr/local/bin/kind /usr/local/bin/kubectl \
 && adduser -D -s /bin/bash student \
 && kubectl completion bash > /etc/bash/kubectl.sh

COPY study-lab-init.sh /usr/local/bin/study-lab-init
COPY bashrc /etc/bash/study-lab.sh
RUN chmod +x /usr/local/bin/study-lab-init

ENV STUDY_LAB_FAMILY=k8s \
    KIND_NODE_IMAGE=${KIND_NODE_IMAGE} \
    KUBECONFIG=/root/.kube/config \
    DOCKER_TLS_CERTDIR=""

LABEL org.opencontainers.image.title="study-lab:k8s" \
      org.opencontainers.image.source="https://github.com/villadalmine/study-cybercirujas" \
      org.opencontainers.image.description="study break/fix lab runner: kind ${KIND_VERSION}, kubectl ${KUBECTL_VERSION}, helm ${HELM_VERSION}"

# dockerd-entrypoint.sh (from docker:dind) stays PID 1's child: dockerd runs,
# the runner execs study-lab-init and the lab script next to it.
#
# The inner dockerd listens on its unix socket ONLY. With no CMD the entrypoint
# adds --host=tcp://0.0.0.0:2375 without TLS when DOCKER_TLS_CERTDIR is empty:
# an unauthenticated, root-equivalent Docker API inside a --privileged
# container, reachable from every other container on the same bridge. Passing
# `dockerd --host=unix://...` makes the entrypoint skip its default listeners.
# tests/lab/test_images.py pins this; the kind e2e checks nothing listens on :2375/:2376.
WORKDIR /lab
CMD ["dockerd", "--host=unix:///var/run/docker.sock"]
