#!/bin/bash -e

# do not source common.sh - it sources stack profile and breaks variables are set after the first call
scriptdir=$(realpath $(dirname "$0"))
source ${scriptdir}/functions.sh

### basic functions

function is_registry_insecure() {
    echo "DEBUG: is_registry_insecure: $@"
    local registry=`echo $1 | sed 's|^.*://||' | cut -d '/' -f 1`
    if  curl -s -I --connect-timeout 60 http://$registry/v2/ ; then
        echo "DEBUG: is_registry_insecure: $registry is insecure"
        return 0
    fi
    echo "DEBUG: is_registry_insecure: $registry is secure"
    return 1
}

### install_docker_DISTRO functions

# this is the last project in queue tf-dev-env -> tf-devstack -> tf-dev-test
# and if docker is not present on this machine then we are free to install any
# version of docker which is availablel for current os-release

function install_docker_ubuntu() {
    export DEBIAN_FRONTEND=noninteractive
    retry apt-get update
    retry apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository -y -u "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    retry apt-get install -y "docker-ce"
}

function install_docker_centos() {
    yum install -y yum-utils device-mapper-persistent-data lvm2
    if ! yum info docker-ce &> /dev/null ; then
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    retry yum install -y docker-ce
}

function install_docker_rhel() {
    if [ "$RHEL_VERSION" == "rhel7" ]; then
        yum install -y docker device-mapper-libs device-mapper-event-libs
    else
        yum install -y podman device-mapper-libs device-mapper-event-libs
        # NOTE: HACK! make symlink 'docker' while tf-test uses it
        ln -s "$(which podman)" /usr/bin/docker
    fi
}

### configure_insecure_registries_[/etc directory]

function configure_insecure_registries_containers() {
    local insecure_registries="$(sed -n '/registries.insecure/{n; s/registries = //p}' "$DOCKER_CONFIG" | tr -d '[]')"
    echo "INFO: old registries are $insecure_registries"
    insecure_registries="registries =[$insecure_registries, '$1']"
    echo "INFO: new registries are $insecure_registries"
    sed -i "/registries.insecure/{n; s/registries = .*$/${insecure_registries}/g}" ${DOCKER_CONFIG}
}

function configure_insecure_registries_sysconfig() {
    echo "INFO: add REGISTRY=$1 to insecure list"
    local insecure_registries=$(cat /etc/sysconfig/docker | awk -F '=' '/^INSECURE_REGISTRY=/{print($2)}' | tr -d '"')
    insecure_registries+=" --insecure-registry $1"
    sed -i '/^INSECURE_REGISTRY/d' "$DOCKER_CONFIG"
    echo "INSECURE_REGISTRY=\"$insecure_registries\"" >> "$DOCKER_CONFIG"
    cat "$DOCKER_CONFIG"
}

function configure_insecure_registries_docker() {
    python3 <<EOF
import json
data=dict()
try:
  with open("${DOCKER_CONFIG}") as f:
    data = json.load(f)
except Exception:
  pass

data.setdefault('insecure-registries', list()).append("${1}")

data['live-restore'] = True
with open("${DOCKER_CONFIG}", 'w') as f:
  data = json.dump(data, f, sort_keys=True, indent=4)
EOF
}

### end of function declaration

# check user id
if [ "$(whoami)" != 'root' ] ; then
    echo "ERROR: this script requires root:"
    echo "       sudo -E $0"
    exit 1
fi

echo ""
echo 'INFO: [docker install]'
echo "INFO: distro=$DISTRO detected"

if which docker >/dev/null 2>&1 ; then
    echo "INFO: docker installed: $(docker --version)"
elif which ctr >/dev/null 2>&1 ; then
    echo "INFO: containerd installed: $(ctr --version)"
    exit 0
else
    [ "$DISTRO" == "ubuntu" ] || systemctl stop firewalld || true
    install_docker_$DISTRO
    [ "$DISTRO" == "ubuntu" ] || [[ "$RHEL_VERSION" =~ "rhel8" ]] || systemctl start docker
fi

echo
echo '[docker config]'

# TODO: config insecure registry for containerd
# CONTAINER_REGISTRY's checks for definition and secureness
if [ -z "${CONTAINER_REGISTRY}" ]; then
    echo "${CONTAINER_REGISTRY} is not defined."
    exit
fi

if ! is_registry_insecure "$CONTAINER_REGISTRY"; then
    echo "$CONTAINER_REGISTRY registry is secure"
    exit
fi

# finding out DOCKER_CONFIG file for insecure registries
if [[ "$RHEL_VERSION" =~ "rhel8" ]]; then
    DOCKER_CONFIG="/etc/containers/registries.conf"
else
    if [ -e "/etc/sysconfig/docker" ]; then
        insecure_registries=$(cat "/etc/sysconfig/docker" | awk -F '=' '/^INSECURE_REGISTRY=/{print($2)}' | tr -d '"')
        echo "INFO: current /etc/sysconfig/docker insecure_registries=$insecure_registries"
    fi
    DOCKER_CONFIG=$([[ -n $insecure_registries ]] && echo "/etc/sysconfig/docker" || echo "/etc/docker/daemon.json" )
fi

# if DOCKER_CONFIG already contains CONTAINER_REGISTRY --> exit
if [ -e $DOCKER_CONFIG ] && grep -q $CONTAINER_REGISTRY $DOCKER_CONFIG; then
    echo "Registry $CONTAINER_REGISTRY is configured in $DOCKER_CONFIG. Skip."
    exit 0
fi

[ -e $DOCKER_CONFIG ] || touch $DOCKER_CONFIG

# add CONTAINER_REGISTRY into DOCKER_CONFIG
configure_insecure_registries_$(echo "$DOCKER_CONFIG" | cut -d "/" -f3 ) "$CONTAINER_REGISTRY"

echo ""
echo "INFO: [restart docker]"

if [ x"$DISTRO" == x"centos" -o x"$DISTRO" == x"rhel" ] ; then
    [[ "$RHEL_VERSION" =~ "rhel8" ]] || systemctl restart docker
elif [ x"$DISTRO" == x"ubuntu" ]; then
    service docker reload
else
    echo "ERROR: unknown distro $DISTRO"
    exit 1
fi
