#!/bin/bash

docker build --pull --secret id=aws_config,src=${LOCAL_HOME}/.aws/config --secret id=saml2aws,src=${LOCAL_HOME}/.saml2aws -f ~/dotfiles/saml2aws.dockerfile -t saml2aws .
docker build --pull -f ~/dotfiles/ecspresso.dockerfile -t ecspresso .

cat <<EOF >> ~/.zshrc
alias saml2aws="docker run -it -v ${LOCAL_HOME}/.aws/credentials:/root/.aws/credentials saml2aws"
alias ecs-exec="docker run --rm -it -v ${LOCAL_WORKSPACE}/ecspresso:/ecspresso -v ${LOCAL_HOME}/.aws:/root/.aws --env ECS_COMMAND=\"\${@:-'rails console'}\" ecspresso '/ecspresso/apps/exec/stg/ecs-exec.sh'"
EOF


