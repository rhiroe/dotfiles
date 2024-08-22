FROM debian:stable-slim AS build

WORKDIR /usr/src/build

ARG BUILDOS
ARG BUILDARCH

RUN apt-get update && \
    apt-get install -y ca-certificates wget && \
    rm -rf /var/lib/apt/lists/*

RUN wget -O yq https://github.com/mikefarah/yq/releases/latest/download/yq_${BUILDOS}_${BUILDARCH} && chmod +x yq

FROM debian:stable-slim

COPY --from=build /usr/src/build/yq /usr/local/bin/yq

ENTRYPOINT ["yq"]
