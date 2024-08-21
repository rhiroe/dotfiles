alias saml2aws="docker run -it -v ${LOCAL_HOME}/.aws/credentials:/root/.aws/credentials saml2aws"
alias ecs-exec="docker run --rm -it -v ${LOCAL_WORKSPACE}/ecspresso:/ecspresso -v ${LOCAL_HOME}/.aws:/root/.aws --env ECS_COMMAND=\"\${@:-'rails console'}\" ecspresso '/ecspresso/apps/exec/stg/ecs-exec.sh'"
