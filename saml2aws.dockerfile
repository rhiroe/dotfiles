FROM debian:stable-slim AS build

WORKDIR /usr/src/build

ARG BUILDOS
ARG BUILDARCH
ARG SAML2AWS_VERSION=2.36.17
ARG SAML2AWS_DOWNLOAD_URL=https://github.com/Versent/saml2aws/releases/download/v${SAML2AWS_VERSION}/saml2aws_${SAML2AWS_VERSION}_${BUILDOS}_${BUILDARCH}.tar.gz
ARG SAML2AWS_BUILD_REPO=https://github.com/aaronthebaron/saml2aws.git
ARG SAML2AWS_BUILD_BRANCH=challenge-selection-fix

RUN apt-get update && \
    apt-get install -y ca-certificates wget && \
    rm -rf /var/lib/apt/lists/*

RUN if [ "${SAML2AWS_VER}" = "build" ]; then \
        git clone "$SAML2AWS_BUILD_REPO" saml2aws_repo; \
        cd saml2aws_repo; \
        git checkout "$SAML2AWS_BUILD_BRANCH"; \
        GOOS=linux GOARCH=amd64 go build -o /usr/src/build/saml2aws cmd/saml2aws/main.go; \
    else \
        wget -O saml2aws.tar.gz "$SAML2AWS_DOWNLOAD_URL"; \
        tar zxvf saml2aws.tar.gz; \
    fi

FROM python:3-slim-bullseye

WORKDIR /saml2aws

RUN mkdir -p /root/.aws
RUN --mount=type=secret,id=aws_config,required=true cp -p /run/secrets/aws_config /root/.aws/config
RUN --mount=type=secret,id=saml2aws,required=true cp -p /run/secrets/saml2aws /root/.saml2aws

COPY --from=build /usr/src/build/saml2aws /usr/local/bin/saml2aws

ENTRYPOINT ["/usr/local/bin/saml2aws"]
