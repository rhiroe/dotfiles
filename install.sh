#!/bin/bash

docker build --pull --secret id=aws_config,src=${LOCAL_HOME}/.aws/config --secret id=saml2aws,src=${LOCAL_HOME}/.saml2aws -f ~/dotfiles/saml2aws.dockerfile -t saml2aws .
docker build --pull -f ~/dotfiles/ecspresso.dockerfile -t ecspresso .
