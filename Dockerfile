# syntax=docker/dockerfile:1

ARG BASE_IMAGE_NAME
ARG BASE_IMAGE_TAG
FROM ${BASE_IMAGE_NAME}:${BASE_IMAGE_TAG} AS with-scripts

COPY scripts/start-unifi-controller.sh /scripts/

ARG BASE_IMAGE_NAME
ARG BASE_IMAGE_TAG
FROM ${BASE_IMAGE_NAME}:${BASE_IMAGE_TAG}

ARG PACKAGES_TO_INSTALL
ARG UNIFI_CONTROLLER_VERSION
ARG USER_NAME
ARG GROUP_NAME
ARG USER_ID
ARG GROUP_ID

# hadolint ignore=SC3040,SC3009
RUN --mount=type=bind,target=/scripts,from=with-scripts,source=/scripts \
    set -E -e -o pipefail \
    && export HOMELAB_VERBOSE=y \
    # Install dependencies. \
    # Workaround for avoiding https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1070136 \
    && mkdir -p /usr/share/man/man1 \
    && homelab install gnupg2 apt-utils ${PACKAGES_TO_INSTALL:?} \
    && homelab download-file-as \
        https://www.mongodb.org/static/pgp/server-8.0.asc \
        /tmp/mongodb-server-8.0.asc \
    && gpg \
        --dearmor \
        --output /usr/share/keyrings/mongodb-server-8.0.gpg \
        /tmp/mongodb-server-8.0.asc \
    && echo "deb [signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" > /etc/apt/sources.list.d/mongodb.list \
    && homelab download-file-as \
        https://dl.ui.com/unifi/unifi-repo.gpg \
        /usr/share/keyrings/unifi.gpg \
    && echo 'deb [signed-by=/usr/share/keyrings/unifi.gpg] https://www.ui.com/downloads/unifi/debian stable ubiquiti' > /etc/apt/sources.list.d/unifi.list \
    && homelab install unifi=${UNIFI_CONTROLLER_VERSION:?} \
    && mkdir -p /data/unifi-controller/{data,logs,run} /opt/unifi-controller \
    # Copy the start-unifi-controller.sh script. \
    && cp /scripts/start-unifi-controller.sh /opt/unifi-controller/ \
    && ln -sf /opt/unifi-controller/start-unifi-controller.sh /opt/bin/start-unifi-controller \
    && userdel --force --remove ${USER_NAME:?} \
    # Create the user and the group. \
    && homelab add-user \
        ${USER_NAME:?} \
        ${USER_ID:?} \
        ${GROUP_NAME:?} \
        ${GROUP_ID:?} \
        --no-create-home-dir \
    # Configure the directories used by unifi. \
    && rm -rf /var/{lib,log,run}/unifi /usr/lib/unifi/{data,logs,run} \
    && ln -sf /data/unifi-controller/data /usr/lib/unifi/data \
    && ln -sf /data/unifi-controller/logs /usr/lib/unifi/logs \
    && ln -sf /data/unifi-controller/run /usr/lib/unifi/run \
    && chown -R ${USER_NAME:?}:${GROUP_NAME:?} \
        /opt/unifi-controller \
        /opt/bin/start-unifi-controller \
        /data/unifi-controller \
        /usr/lib/unifi \
    # Clean up. \
    && homelab remove gnupg2 apt-utils \
    && homelab cleanup

# List of ports used by the UniFi network controller.
# https://help.ui.com/hc/en-us/articles/218506997-Required-Ports-Reference

# Device and application communication.
EXPOSE 8080
# Application GUI/API.
EXPOSE 8443
# STUN.
EXPOSE 3478/udp
# UniFi mobile speed test.
EXPOSE 6789
# Device discovery during adoption.
EXPOSE 10001/udp

HEALTHCHECK \
    --start-period=15s --interval=30s --timeout=3s \
    CMD homelab healthcheck-service https://127.0.0.1:8443/

ENV USER=${USER_NAME}
USER ${USER_NAME}:${GROUP_NAME}
WORKDIR /

CMD ["start-unifi-controller"]
STOPSIGNAL SIGTERM
