#!/usr/bin/env bash

set -xeuo pipefail

# https://github.com/NixOS/nixops/issues/693
export BOTO_CONFIG=/dev/null

# shellcheck disable=SC1091
CLEANUP_CONFIGS=true
WITH_STAGING=true
WITH_PRODUCTION=true
WITH_TESTNET=true
WITH_DEVELOPMENT=true
WITH_EXPLORER=true
WITH_MONITORING=true
WITH_INFRA_PRODUCTION=true
WITH_INFRA_STAGING=true
WITH_BENCHMARK=true

while getopts o:c:s:p:t:d:e:r:m:i:j:b: option
do
  case "${option}" in
    o) IOHK_OPS=${OPTARG};;
    c) CLEANUP_CONFIGS=${OPTARG};;
    s) WITH_STAGING=${OPTARG};;
    p) WITH_PRODUCTION=${OPTARG};;
    t) WITH_TESTNET=${OPTARG};;
    d) WITH_DEVELOPMENT=${OPTARG};;
    e) WITH_EXPLORER=${OPTARG};;
    m) WITH_MONITORING=${OPTARG};;
    i) WITH_INFRA_PRODUCTION=${OPTARG};;
    j) WITH_INFRA_STAGING=${OPTARG};;
    b) WITH_BENCHMARK=${OPTARG};;
    *) echo "Invalid flag passed, exiting" || exit 1
  esac
done

# Set NIX_PATH to the pinned version in nixpkgs-src.json
nixpkgs_source=$(nix eval --raw -f lib.nix 'nixpkgs')
export NIX_PATH="nixpkgs=$nixpkgs_source"

if [[ ! -v IOHK_OPS ]]
then
  IOHK_OPS=$(nix-build -A iohk-ops)/bin/iohk-ops
fi



homestate="$(mktemp -d -t iohk-ops.XXXXXXXXXXXX)"
export HOME="${homestate}"

# PREPARE
mkdir -p cardano-sl/explorer/frontend/dist

touch static/buildkite_token
touch static/github_token{,_mantis_hydra}
touch static/id_buildfarm{,2} static/id_buildfarm{,2}.pub
echo "127.0.0.1" > static/deployer-ip.txt

test -f static/graylog-creds.nix ||
        { echo "{
  user = \"changeme\";
  password = \"changeme\";
  passwordHash = \"1234567890123456789012345678901234567890123456789012345678901234\";
  clusterSecret = \"1234567890123456789012345678901234567890123456789012345678901234\";
}" > static/graylog-creds.nix; }

test -f static/tarsnap-cardano-deployer.secret ||
        { echo "secret" > static/tarsnap-cardano-deployer.secret; }

test -f static/oauth.nix ||
        { echo "{
  clientID = \"test.apps.googleusercontent.com\";
  clientSecret = \"test\";
  cookie.secret = \"test\";
}" > static/oauth.nix; }

test -f static/pager-duty.nix ||
        { echo "{
  serviceKey = \"test\";
  exchangeKey = \"test2\";
}" > static/pager-duty.nix; }

test -f static/dead-mans-snitch.nix ||
        { echo "{
  pingUrl = \"http://example.com/test\";
}" > static/dead-mans-snitch.nix; }

mkdir -p keys
for i in $(seq 0 9)
do touch "keys/key$i.sk"
done


# 0. Check all scripts compile
nix-shell --run "echo in nix-shell"
${IOHK_OPS} --help

# 1. check all packages build
nix-instantiate jobsets/cardano.nix --show-trace

# 2. check all environments evaluate
CLEANUP_DEPLS=""
cleanup() {
        set +xe
        echo "${CLEANUP_DEPLS:+Cleaning up deployments: ${CLEANUP_DEPLS}}" >&2
        for depl in ${CLEANUP_DEPLS}
        do
                test -z "${CLEANUP_CONFIGS}" ||
                        rm -f                "${depl}.yaml"
        done
        echo "Cleaning up home state: ${homestate}"
        rm -rf "${homestate}"
        echo "Cleanup done."
}
trap cleanup EXIT

banner() {
  # shellcheck disable=SC1117
        echo -e "--\n--\n--  $*\n--\n--\n"
}

GENERAL_OPTIONS=(--verbose --deployer 0.0.0.0)
COMMON_OPTIONS=( --topology topology-min.yaml --domain example.com )
CARDANO_COMPONENTS=( Nodes ${WITH_EXPLORER:+Explorer} ${WITH_MONITORING:+Monitoring} )
CARDANO_COMPONENTS_WITHOUT_MONITORING=( Nodes ${WITH_EXPLORER:+Explorer} )


echo '~~~ pre-building cardano-sl-tools'
nix-build default.nix -A nix-tools.exes.cardano-sl-tools -o cardano-sl-tools

echo '~~~ generating wireguard tests'
nix-shell modules/gen-wireguard-keys.nix --arg hosts '[ "monitoring" "packet-hydra-slave-1" "packet-hydra-slave-2" "packet-hydra-slave-3" "packet-hydra-slave-4" "packet-hydra-slave-5" "packet-buildkite-1" "packet-buildkite-2" "packet-buildkite-3" "mantis-slave-packet-1" "mantis-slave-packet-2" "hydra" "sarov" "cardano-deployer" ]'

PATH=$PATH:./cardano-sl-tools/bin/
export PATH

if [[ ${WITH_STAGING} == true ]]; then
  echo '~~~ testing staging'
CLEANUP_DEPLS="${CLEANUP_DEPLS} test-stag"
${IOHK_OPS}               new  --config 'test-stag.yaml'   --environment staging    "${COMMON_OPTIONS[@]}" 'test-stag'    "${CARDANO_COMPONENTS[@]}"
${IOHK_OPS} "${GENERAL_OPTIONS[@]}" --config 'test-stag.yaml'   create deploy --dry-run --initial-heap-size 4
banner 'Staging env evaluated'
fi

if [[ ${WITH_PRODUCTION} == true ]]; then
  echo '~~~ testing production'
CLEANUP_DEPLS="${CLEANUP_DEPLS} test-prod"
${IOHK_OPS}               new  --config 'test-prod.yaml'   --environment production "${COMMON_OPTIONS[@]}" 'test-prod'    "${CARDANO_COMPONENTS[@]}"
${IOHK_OPS} "${GENERAL_OPTIONS[@]}" --config 'test-prod.yaml'   create deploy --dry-run --initial-heap-size 4
banner 'Production env evaluated'
fi

if [[ ${WITH_TESTNET} == true ]]; then
  echo '~~~ testing testnet'
CLEANUP_DEPLS="${CLEANUP_DEPLS} test-stag"
${IOHK_OPS}               new  --config 'test-stag.yaml'   --environment testnet    "${COMMON_OPTIONS[@]}" 'test-stag'    "${CARDANO_COMPONENTS[@]}"
${IOHK_OPS} "${GENERAL_OPTIONS[@]}" --config 'test-stag.yaml'   create deploy --dry-run --initial-heap-size 4
banner 'Testnet env evaluated'
fi

if [[ ${WITH_DEVELOPMENT} == true ]]; then
  echo '~~~ testing development'
CLEANUP_DEPLS="${CLEANUP_DEPLS} test-devo"
${IOHK_OPS}               new  --config 'test-devo.yaml'                            "${COMMON_OPTIONS[@]}" 'test-devo'    "${CARDANO_COMPONENTS_WITHOUT_MONITORING[@]}"
${IOHK_OPS} "${GENERAL_OPTIONS[@]}" --config 'test-devo.yaml'   create deploy --dry-run --initial-heap-size 4
banner 'Development env evaluated'
fi

if [[ ${WITH_INFRA_PRODUCTION} == true ]]; then
  echo '~~~ testing production-infra'
CLEANUP_DEPLS="${CLEANUP_DEPLS} test-infra"
${IOHK_OPS}               new  --config 'test-infra.yaml'  --environment production "${COMMON_OPTIONS[@]}" 'test-infra'   Infra Monitoring
${IOHK_OPS} "${GENERAL_OPTIONS[@]}" --config 'test-infra.yaml'  create deploy --dry-run --initial-heap-size 4
banner 'Production infra evaluated'
fi

if [[ ${WITH_INFRA_STAGING} == true ]]; then
  echo '~~~ testing staging-infra'
CLEANUP_DEPLS="${CLEANUP_DEPLS} test-infra"
${IOHK_OPS}               new  --config 'test-infra.yaml'  --environment staging   "${COMMON_OPTIONS[@]}" 'test-infra'   Infra Monitoring
${IOHK_OPS} "${GENERAL_OPTIONS[@]}" --config 'test-infra.yaml'  create deploy --dry-run --initial-heap-size 4
banner 'Staging infra evaluated'
fi

echo "BENCHMARK ENABLED: ${WITH_BENCHMARK}"
  echo '~~~ testing benchmarking'
if [[ ${WITH_BENCHMARK} == true ]]; then
CLEANUP_DEPLS="${CLEANUP_DEPLS} test-bench"
${IOHK_OPS}               new  --config 'test-bench.yaml'   --environment benchmark    "${COMMON_OPTIONS[@]}" 'test-bench'    "${CARDANO_COMPONENTS[@]}"
${IOHK_OPS} "${GENERAL_OPTIONS[@]}" --config 'test-bench.yaml'   create deploy --dry-run
banner 'Benchmark env evaluated'
fi

echo '~~~ Validating terraform'
nix-shell --run "terraform validate -check-variables=false terraform/appveyor-s3-cache"

echo '~~~ Git commit ids:'
./scripts/find-all-revisions.sh

echo '~~~ All OK.'
