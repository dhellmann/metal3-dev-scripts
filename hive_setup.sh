#!/usr/bin/env bash
set -xe

bindir=$(dirname $0)

source logging.sh
source common.sh
source utils.sh
source rhcos.sh
source ocp_install_env.sh
source hive_common.sh

function generate_hive_manifest() {
    cat > "ocp/${CLUSTER_NAME}/manifests.yaml" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${CLUSTER_NAME}-pull-secret
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |-
    $(echo $PULL_SECRET | jq -c .)

---
apiVersion: v1
kind: Secret
metadata:
  name: ${CLUSTER_NAME}-ssh-private-key
stringData:
  ssh-privatekey: |-
$(cat ~/.ssh/id_rsa | sed 's/^/    /g')

---
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: ${CLUSTER_NAME}
  annotations:
    # do not retry if first deploy fails
    hive.openshift.io/try-install-once: "true"
spec:
  baseDomain: ${BASE_DOMAIN}
  clusterName: ${CLUSTER_NAME}
  controlPlaneConfig:
    servingCertificates: {}
  platform:
    bareMetal:
      libvirtSSHPrivateKeySecretRef:
        name: ${CLUSTER_NAME}-ssh-private-key
  provisioning:
    installConfigSecretRef:
      name: ${CLUSTER_NAME}-install-config
    sshPrivateKeySecretRef:
      name: ${CLUSTER_NAME}-ssh-private-key
#    manifestsConfigMapRef:
#      name: ${CLUSTER_NAME}-install-manifests
    releaseImage: "${OPENSHIFT_RELEASE_IMAGE}"
    sshKnownHosts:
$(ssh-keyscan -H ${PROVISIONING_HOST_IP} 2>/dev/null | sed -e 's/^/      - "/g' -e 's/$/"/g')
  pullSecretRef:
    name: ${CLUSTER_NAME}-pull-secret

EOF

    cat > "ocp/${CLUSTER_NAME}/create.sh" <<EOF
#!/usr/bin/env bash

set -xe

bindir=\$(dirname \$0)

export KUBECONFIG="${SCRIPTDIR}/ocp/auth/kubeconfig"

if ! (oc projects | grep -q ${CLUSTER_NAME}); then
   oc new-project ${CLUSTER_NAME}
fi

oc delete secret ${CLUSTER_NAME}-pull-secret || true
oc delete secret ${CLUSTER_NAME}-install-config || true

oc create secret generic -n ${CLUSTER_NAME} ${CLUSTER_NAME}-install-config --from-file=install-config.yaml=\${bindir}/install-config.yaml

oc apply -n ${CLUSTER_NAME} -f \${bindir}/manifests.yaml

EOF

    chmod +x "ocp/${CLUSTER_NAME}/create.sh"
}

# Force network management for our networks
export MANAGE_BR_BRIDGE="y"

# Create the hive1 cluster resources.

override_vars_for_hive 1

export VBMC_BASE_PORT=$((6230 + ${NUM_MASTERS} + ${NUM_WORKERS}))
export VBMC_MAX_PORT=$((${VBMC_BASE_PORT} + ${HIVE1_NUM_MASTERS} + ${HIVE1_NUM_WORKERS} - 1))

${bindir}/02_configure_host.sh
${bindir}/04_setup_ironic.sh

generate_ocp_install_config ocp/hive1
generate_hive_manifest

# Create the hive2 cluster resources.

# override_vars_for_hive 2

# VBMC_BASE_PORT=$((${VBMC_BASE_PORT} + ${HIVE1_NUM_MASTERS} + ${HIVE1_NUM_WORKERS}))

# ANSIBLE_FORCE_COLOR=true ansible-playbook \
#     -e @vm_setup_vars.yml \
#     -e @hive_vars.yml \
#     -e "provisioning_network_name=${PROVISIONING_NETWORK_NAME}" \
#     -e "baremetal_network_name=${BAREMETAL_NETWORK_NAME}" \
#     -e "working_dir=$WORKING_DIR" \
#     -e "num_masters=$HIVE2_NUM_MASTERS" \
#     -e "num_workers=$HIVE2_NUM_WORKERS" \
#     -e "extradisks=$VM_EXTRADISKS" \
#     -e "virthost=$HOSTNAME" \
#     -e "vm_platform=$NODES_PLATFORM" \
#     -e "manage_baremetal=y" \
#     -e "provisioning_url_host=$PROVISIONING_URL_HOST" \
#     -e "ironic_prefix=hive2_" \
#     -e "nodes_file=$HIVE2_NODES_FILE" \
#     -e "virtualbmc_base_port=$VBMC_BASE_PORT" \
#     -i ${VM_SETUP_PATH}/inventory.ini \
#     -b -vvv ${VM_SETUP_PATH}/setup-playbook.yml


# if [ "${RHEL8}" = "True" ] ; then
#     ZONE="\nZONE=libvirt"
# fi

# # Adding an IP address in the libvirt definition for this network results in
# # dnsmasq being run, we don't want that as we have our own dnsmasq, so set
# # the IP address here
# if [ ! -e /etc/sysconfig/network-scripts/ifcfg-${HIVE2_PROVISIONING_NETWORK_NAME} ] ; then
#     echo -e "DEVICE=${HIVE2_PROVISIONING_NETWORK_NAME}\nTYPE=Bridge\nONBOOT=yes\nNM_CONTROLLED=no\nBOOTPROTO=static\nIPADDR=$HIVE2_PROVISIONING_HOST_IP\nNETMASK=$HIVE2_PROVISIONING_NETMASK${ZONE}" | sudo dd of=/etc/sysconfig/network-scripts/ifcfg-${HIVE2_PROVISIONING_NETWORK_NAME}
# fi
# sudo ifdown ${HIVE2_PROVISIONING_NETWORK_NAME} || true
# sudo ifup ${HIVE2_PROVISIONING_NETWORK_NAME}

# # Create the bridge for the baremetal network
# if [ ! -e /etc/sysconfig/network-scripts/ifcfg-${HIVE2_BAREMETAL_NETWORK_NAME} ] ; then
#     echo -e "DEVICE=${HIVE2_BAREMETAL_NETWORK_NAME}\nTYPE=Bridge\nONBOOT=yes\nNM_CONTROLLED=no${ZONE}" | sudo dd of=/etc/sysconfig/network-scripts/ifcfg-${HIVE2_BAREMETAL_NETWORK_NAME}
# fi
# sudo ifdown ${HIVE2_BAREMETAL_NETWORK_NAME} || true
# sudo ifup ${HIVE2_BAREMETAL_NETWORK_NAME}

# # If there were modifications to the /etc/sysconfig/network-scripts/ifcfg-*
# # files, it is required to enable the network service
# sudo systemctl enable network

# # restart the libvirt network so it applies an ip to the bridge
# sudo virsh net-destroy ${HIVE2_BAREMETAL_NETWORK_NAME}
# sudo virsh net-start ${HIVE2_BAREMETAL_NETWORK_NAME}

# # Add firewall rules to ensure the image caches can be reached on the host
# for PORT in 80 ${LOCAL_REGISTRY_PORT} ; do
#     if [ "${RHEL8}" = "True" ] ; then
#         sudo firewall-cmd --zone=libvirt --add-port=$PORT/tcp
#         sudo firewall-cmd --zone=libvirt --add-port=$PORT/tcp --permanent
#     else
#         if ! sudo iptables -C INPUT -i ${HIVE2_PROVISIONING_NETWORK_NAME} -p tcp -m tcp --dport $PORT -j ACCEPT > /dev/null 2>&1; then
#             sudo iptables -I INPUT -i ${HIVE2_PROVISIONING_NETWORK_NAME} -p tcp -m tcp --dport $PORT -j ACCEPT
#         fi
#         if ! sudo iptables -C INPUT -i ${HIVE2_BAREMETAL_NETWORK_NAME} -p tcp -m tcp --dport $PORT -j ACCEPT > /dev/null 2>&1; then
#             sudo iptables -I INPUT -i ${HIVE2_BAREMETAL_NETWORK_NAME} -p tcp -m tcp --dport $PORT -j ACCEPT
#         fi
#     fi
# done

# # Allow ipmi to the virtual bmc processes that we just started
# VBMC_MAX_PORT=$((6230 + ${NUM_MASTERS} + ${NUM_WORKERS} + ${HIVE2_NUM_MASTERS} + ${HIVE2_NUM_WORKERS} - 1))
# if [ "${RHEL8}" = "True" ] ; then
#     sudo firewall-cmd --zone=libvirt --add-port=6230-${VBMC_MAX_PORT}/udp
#     sudo firewall-cmd --zone=libvirt --add-port=6230-${VBMC_MAX_PORT}/udp --permanent
# else
#     if ! sudo iptables -C INPUT -i ${HIVE2_BAREMETAL_NETWORK_NAME} -p udp -m udp --dport 6230:${VBMC_MAX_PORT} -j ACCEPT 2>/dev/null ; then
#         sudo iptables -I INPUT -i ${HIVE2_BAREMETAL_NETWORK_NAME} -p udp -m udp --dport 6230:${VBMC_MAX_PORT} -j ACCEPT
#     fi
# fi

# # Configure DNS for hive2

# if [[ $EXTERNAL_SUBNET =~ .*:.* ]]; then
#     API_VIP=$(dig -t AAAA +noall +answer "api.${CLUSTER_DOMAIN}" @$(network_ip ${HIVE2_BAREMETAL_NETWORK_NAME}) | awk '{print $NF}')
# else
#     API_VIP=$(dig +noall +answer "api.${CLUSTER_DOMAIN}" @$(network_ip ${HIVE2_BAREMETAL_NETWORK_NAME}) | awk '{print $NF}')
# fi
# INGRESS_VIP=$(python -c "from ansible.plugins.filter import ipaddr; print(ipaddr.nthhost('"$EXTERNAL_SUBNET"', 4))")
# echo "address=/api.${CLUSTER_DOMAIN}/${API_VIP}" | sudo tee -a /etc/NetworkManager/dnsmasq.d/${CLUSTER_NAME}.conf
# echo "address=/.apps.${CLUSTER_DOMAIN}/${INGRESS_VIP}" | sudo tee -a /etc/NetworkManager/dnsmasq.d/${CLUSTER_NAME}.conf
# sudo systemctl reload NetworkManager

# generate_ocp_install_config ocp/hive2
# generate_hive_manifest

# echo 'Done!' $'\a'