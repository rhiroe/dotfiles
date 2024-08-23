#!/bin/bash

docker build --pull -f ~/dotfiles/ecspresso.dockerfile -t ecspresso .
docker build --pull -f ~/dotfiles/jq.dockerfile -t jq .
docker build --pull --secret id=aws_config,src=${LOCAL_HOME:?}/.aws/config --secret id=saml2aws,src=${LOCAL_HOME:?}/.saml2aws -f ~/dotfiles/saml2aws.dockerfile -t saml2aws .
docker build --pull -f ~/dotfiles/yq.dockerfile -t yq .

cat <<EOF >> ~/.zshrc
export ECS_EXEC_FILES=$(find ${WORKDIR:?} -name 'ecs-exec.sh' -type f)
export PATH=$PATH:$HOME/dotfiles/bin
EOF
