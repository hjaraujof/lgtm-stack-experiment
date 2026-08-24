# Toolchain image for the two init workloads and for `helm test`.
#
# WHY IT IS NOT scripts/Dockerfile.grafana-init. That image is built FROM amazon/aws-cli,
# because in Compose the init container falls back to reading AWS Secrets Manager directly.
# In the cluster the passwords arrive as environment variables from a Kubernetes Secret, so
# no AWS client is needed and a 400 MB base image would be carried for nothing.
#
# THE SCRIPTS ARE NOT COPIED IN. They are mounted from a ConfigMap, the same separation the
# bind mount gives in Compose: this image supplies the tools, scripts/ supplies the code. So
# a script edit ships with `helm upgrade` and needs no rebuild.
#
# Build and load it into kind:
#   make -C k8s image
FROM alpine:3.21

# bash    - the scripts use bash arrays and [[ ]]
# curl    - every script talks HTTP
# jq      - response parsing in init-grafana.sh and the helm test
# bc      - send-test-metrics.sh computes float values with it
# coreutils - the scripts use `seq` and GNU `date`
RUN apk add --no-cache bash curl jq bc coreutils

WORKDIR /scripts
ENTRYPOINT ["/bin/bash"]
