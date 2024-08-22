FROM debian:stable-slim AS build

WORKDIR /usr/src/build

ARG BUILDOS

RUN apt-get update && \
    apt-get install -y ca-certificates wget && \
    rm -rf /var/lib/apt/lists/*

RUN wget -O jq https://github.com/stedolan/jq/releases/latest/download/jq-${BUILDOS}64 && chmod +x jq

FROM debian:stable-slim

COPY --from=build /usr/src/build/jq /usr/local/bin/jq

ENTRYPOINT ["jq"]
