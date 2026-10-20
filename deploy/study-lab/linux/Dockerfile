# study-lab:linux — the runner image for Linux labs (LPI, LFCS...). Debian 12
# (what every v1 lab.yaml asks for: os: debian-12) with systemd as PID 1, so
# labs that break and fix services (systemctl, journald, units) behave as on a
# real VM. Runs without --privileged: cgroup v2, a private cgroup namespace
# made writable with --security-opt writable-cgroups=true, and tmpfs on /run.
FROM debian:bookworm-20261005@sha256:2c037a04925515fdd6ea85ea14a682d0e79931f5e9f5d07b6dbfc6ba12f9e858

ENV container=docker DEBIAN_FRONTEND=noninteractive STUDY_LAB_FAMILY=linux

RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus sudo procps \
        iproute2 iputils-ping curl ca-certificates less vim-tiny nano cron openssh-client \
        man-db file psmisc lsof acl \
 && rm -rf /var/lib/apt/lists/* \
 # units that make no sense in a container and slow or break boot
 && systemctl mask systemd-udevd.service systemd-udev-trigger.service getty.target \
        systemd-logind.service console-getty.service systemd-firstboot.service \
 && useradd -m -s /bin/bash student \
 && echo 'student ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/student

COPY study-lab-init.sh /usr/local/bin/study-lab-init
RUN chmod +x /usr/local/bin/study-lab-init

LABEL org.opencontainers.image.title="study-lab:linux" \
      org.opencontainers.image.source="https://github.com/villadalmine/study-cybercirujas"

STOPSIGNAL SIGRTMIN+3
WORKDIR /lab
CMD ["/sbin/init"]
