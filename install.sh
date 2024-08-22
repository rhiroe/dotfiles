#!/bin/bash

docker build --pull -f ~/dotfiles/aws-cli.dockerfile -t aws .
docker build --pull -f ~/dotfiles/ecspresso.dockerfile -t ecspresso .
docker build --pull -f ~/dotfiles/jq.dockerfile -t jq .
docker build --pull --secret id=aws_config,src=${LOCAL_HOME}/.aws/config --secret id=saml2aws,src=${LOCAL_HOME}/.saml2aws -f ~/dotfiles/saml2aws.dockerfile -t saml2aws .
docker build --pull -f ~/dotfiles/yq.dockerfile -t yq .

export PATH=$PATH:$HOME/dotfiles/bin/ecspresso:$HOME/dotfiles/bin/jq:$HOME/dotfiles/bin/saml2aws:$HOME/dotfiles/bin/yq
