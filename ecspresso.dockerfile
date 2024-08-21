FROM debian:stable-slim AS build

WORKDIR /usr/src/build

ARG BUILDOS
ARG BUILDARCH
ARG ECSPRESSO_VERSION=2.3.6

RUN apt-get update && \
    apt-get install -y ca-certificates wget && \
    rm -rf /var/lib/apt/lists/*

RUN wget -O ecspresso.tar.gz https://github.com/kayac/ecspresso/releases/download/v${ECSPRESSO_VERSION}/ecspresso_${ECSPRESSO_VERSION}_${BUILDOS}_${BUILDARCH}.tar.gz && \
    tar zxvf ecspresso.tar.gz

RUN wget -O jq https://github.com/stedolan/jq/releases/latest/download/jq-${BUILDOS}64 && chmod +x jq
RUN wget -O yq https://github.com/mikefarah/yq/releases/latest/download/yq_${BUILDOS}_${BUILDARCH} && chmod +x yq

RUN if [ "${BUILDARCH}" = "arm64" ]; then SM_ARCH=ubuntu_arm64; else SM_ARCH=ubuntu_64bit; fi && \
    wget -O "session-manager-plugin.deb" "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${SM_ARCH}/session-manager-plugin.deb" && \
    dpkg -i session-manager-plugin.deb

FROM amazon/aws-cli

COPY --from=build /usr/src/build/ecspresso /usr/local/bin/ecspresso
COPY --from=build /usr/src/build/jq /usr/local/bin/jq
COPY --from=build /usr/src/build/yq /usr/local/bin/yq
COPY --from=build /usr/local/bin/session-manager-plugin /usr/local/bin/session-manager-plugin

ENTRYPOINT []
