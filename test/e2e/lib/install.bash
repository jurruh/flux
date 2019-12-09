#!/usr/bin/env bash

# shellcheck disable=SC1090
source "${E2E_DIR}/lib/defer.bash"
# shellcheck disable=SC1090
source "${E2E_DIR}/lib/template.bash"

function install_tiller() {
  if ! helm version > /dev/null 2>&1; then # only if helm isn't already installed
    kubectl --namespace kube-system create sa tiller
    kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
    helm init --service-account tiller --upgrade --wait
  fi
}

function uninstall_tiller() {
  helm reset --force
  kubectl delete clusterrolebinding tiller-cluster-rule
  kubectl --namespace kube-system delete sa tiller
}

function install_flux_with_helm() {
  local create_crds='true'
  if kubectl get crd fluxhelmreleases.helm.integrations.flux.weave.works helmreleases.flux.weave.works > /dev/null 2>&1; then
    # CRDs existed, don't try to create them
    echo 'CRDs existed, setting helmOperator.createCRD=false'
    create_crds='false'
  fi

  helm install --name flux --wait \
    --namespace "${FLUX_NAMESPACE}" \
    --set image.repository=docker.io/fluxcd/flux \
    --set image.tag=latest \
    --set git.url=ssh://git@gitsrv/git-server/repos/cluster.git \
    --set git.secretName=flux-git-deploy \
    --set git.pollInterval=10s \
    --set git.config.secretName=gitconfig \
    --set git.config.enabled=true \
    --set-string git.config.data="${GITCONFIG}" \
    --set helmOperator.create=true \
    --set helmOperator.git.secretName=flux-git-deploy \
    --set helmOperator.createCRD="${create_crds}" \
    --set registry.excludeImage=* \
    --set-string ssh.known_hosts="${KNOWN_HOSTS}" \
    "${FLUX_ROOT_DIR}/chart/flux"
}

function uninstall_flux_with_helm() {
  helm delete --purge flux > /dev/null 2>&1
  kubectl delete crd helmreleases.flux.weave.works > /dev/null 2>&1
}

fluxctl_install_cmd="fluxctl install --git-url=ssh://git@gitsrv/git-server/repos/cluster.git --git-email=foo"

function install_flux_with_fluxctl() {
  kustomization_dir=${1}
  key_values_varname=${2}
  shift 2

  kubectl -n "${FLUX_NAMESPACE}" create configmap flux-known-hosts --from-file="${E2E_DIR}/fixtures/known_hosts"
  local kustomtmp
  kustomtmp="$(mktemp -d)"
  defer rm -rf "'${kustomtmp}'"

  # Everything goes into one directory, but not everything is
  # necessarily used by the kustomization
  mkdir -p "${kustomtmp}/${kustomization_dir}/base"
  cp -R "${E2E_DIR}/fixtures/kustom/${kustomization_dir}"/* "${kustomtmp}/${kustomization_dir}/"
  cp -R "${E2E_DIR}/fixtures/kustom/base/flux"/* "${kustomtmp}/${kustomization_dir}/base/"

  # This generates the base manifests, which we'll then patch with a kustomization
  echo ">>> writing base configuration to ${kustomtmp}/${kustomization_dir}/base/" >&3
  $fluxctl_install_cmd --namespace "${FLUX_NAMESPACE}" -o "${kustomtmp}/${kustomization_dir}/base/" "$@"

  if [ -n "$key_values_varname" ]; then
    fill_in_place_recursively "$key_values_varname" "${kustomtmp}"
  fi

  kubectl apply -k "${kustomtmp}/${kustomization_dir}/" >&3
  kubectl -n "${FLUX_NAMESPACE}" rollout status -w --timeout=30s deployment/flux ||
    (
      kubectl -n "${FLUX_NAMESPACE}" describe deployment/flux
      kubectl -n "${FLUX_NAMESPACE}" log deployment/flux
    )
}

function uninstall_flux_with_fluxctl() {
  kubectl delete -n "${FLUX_NAMESPACE}" configmap flux-known-hosts
  $fluxctl_install_cmd --namespace "${FLUX_NAMESPACE}" | kubectl delete -f -
}

function install_git_srv() {
  local external_access_result_var=${1}
  local kustomization_dir=${2:-base/gitsrv}
  local gen_dir
  gen_dir=$(mktemp -d)

  ssh-keygen -t rsa -N "" -f "$gen_dir/id_rsa"
  defer rm -rf "'$gen_dir'"
  kubectl create secret generic flux-git-deploy \
    --namespace="${FLUX_NAMESPACE}" \
    --from-file="${FIXTURES_DIR}/known_hosts" \
    --from-file="$gen_dir/id_rsa" \
    --from-file=identity="$gen_dir/id_rsa" \
    --from-file="$gen_dir/id_rsa.pub"

  kubectl apply -n "${FLUX_NAMESPACE}" -k "${E2E_DIR}/fixtures/kustom/${kustomization_dir}" >&3

  # Wait for the git server to be ready
  kubectl -n "${FLUX_NAMESPACE}" rollout status deployment/gitsrv

  if [ -n "$external_access_result_var" ]; then
    local git_srv_podname
    git_srv_podname=$(kubectl get pod -n "${FLUX_NAMESPACE}" -l name=gitsrv -o jsonpath="{['items'][0].metadata.name}")
    coproc kubectl port-forward -n "${FLUX_NAMESPACE}" "$git_srv_podname" :22
    local local_port
    read -r local_port <&"${COPROC[0]}"-
    # shellcheck disable=SC2001
    local_port=$(echo "$local_port" | sed 's%.*:\([0-9]*\).*%\1%')
    local ssh_cmd="ssh -o UserKnownHostsFile=/dev/null  -o StrictHostKeyChecking=no -i $gen_dir/id_rsa -p $local_port"
    # return the ssh command needed for git, and the PID of the port-forwarding PID into a variable of choice
    eval "${external_access_result_var}=('$ssh_cmd' '$COPROC_PID')"
  fi
}

function uninstall_git_srv() {
  local secret_name=${1:-flux-git-deploy}
  # Silence secret deletion errors since the secret can be missing (deleted by uninstalling Flux)
  kubectl delete -n "${FLUX_NAMESPACE}" secret "$secret_name" &> /dev/null
  kubectl delete -n "${FLUX_NAMESPACE}" -f "${E2E_DIR}/fixtures/gitsrv.yaml"
}
