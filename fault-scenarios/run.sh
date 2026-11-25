#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

RELEASE=astronomy
NAMESPACE=otel-demo
CHART=opentelemetry-demo
CHART_REPO=https://open-telemetry.github.io/opentelemetry-helm-charts
CHART_VERSION=0.42.7
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_REVISION_FILE="$HOME/.fault-scenarios-original-revision"
LENS_URL="${LENS_URL:-http://104.198.168.204:9108}"

usage() {
    cat <<'EOF'
Usage: ./run.sh <command>

  setup        Save the current Helm revision, create the ConfigMaps and deploy the healthy baseline
  1            Bad deploy: product-catalog image whose GetProduct endpoint fails
  2            Bad deploy: product-catalog image with a slow ListProducts query
  3            Bad deploy: checkout image that crash-loops on a missing setting
  4            Bad deploy: payment memory limit lowered (PAYMENT_MEMORY_LIMIT, default 40Mi)
  5            Bad deploy: email image tag that does not exist
  6            Config: frontend-config points CART_ADDR at a host that does not exist
  7            Config: product-catalog-config shrinks the DB pool from 10 to 2
  8            Config: same pool change through an environment variable
  baseline     Re-apply the healthy baseline through Helm
  watch        Wait until Lens (or anyone) brings everything back to the baseline and print the time
  revert <n>   Undo scenario n by hand, if Lens did not
  status       Show the Helm revision, what still differs from the baseline and every pod that is not healthy
  restore      Roll the release back to the revision saved by setup and delete the ConfigMaps
EOF
}

log() {
    echo "[$(TZ=Asia/Kolkata date '+%H:%M:%S IST')] $*"
}

upgrade() {
    if grep -q GOOD_TAG_PENDING "$DIR/baseline.yaml"; then
        echo "baseline.yaml has no product-catalog image tag yet" >&2
        exit 1
    fi
    helm upgrade "$RELEASE" "$CHART" --repo "$CHART_REPO" --version "$CHART_VERSION" \
        --namespace "$NAMESPACE" --reuse-values -f "$DIR/baseline.yaml" "$@"
}

set_config() {
    kubectl -n "$NAMESPACE" patch configmap "$1" --type merge -p "{\"data\":{\"$2\":\"$3\"}}"
}

restart() {
    kubectl -n "$NAMESPACE" rollout restart "deployment/$1"
}

record_deploy() {
    local token by payload code
    if ! token=$(kubectl -n "$NAMESPACE" get secret lens-ingest -o jsonpath='{.data.token}' | base64 -d) || [ -z "$token" ]; then
        log "Could not read the lens-ingest token, so the $1 deploy is not recorded in Lens"
        return 0
    fi
    by=cloud-shell
    if [ -n "${BUILD_URL:-}" ]; then
        by=jenkins
    fi
    payload=$(printf '{"service":"%s","version":"%s","description":"%s","deployed_by":"%s"}' "$1" "$2" "$3" "$by")
    if [ -n "${LENS_REPO:-}" ]; then
        payload="${payload%\}},\"repo\":\"$LENS_REPO\"}"
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "$LENS_URL/api/v1/deployments" \
        -H 'Content-Type: application/json' -H "Authorization: Bearer $token" -d "$payload") || code=000
    log "Lens deploy record for $1 $2: HTTP $code"
}

container_field() {
    kubectl -n "$NAMESPACE" get deployment "$1" -o jsonpath="{.spec.template.spec.containers[0]$2}"
}

config_value() {
    kubectl -n "$NAMESPACE" get configmap "$1" -o jsonpath="{.data.$2}"
}

changed=0

check() {
    if [ "$3" = "$4" ]; then
        echo "  ok       $2: $3"
    else
        echo "  CHANGED  $2: $3 (baseline: $4) -> ./run.sh revert $1"
        changed=1
    fi
}

mebibytes() {
    case "$1" in
        *Gi) echo $(( ${1%Gi} * 1024 )) ;;
        *Mi) echo "${1%Mi}" ;;
        *) echo 0 ;;
    esac
}

compare() {
    changed=0
    check 1 "product-catalog image" "$(container_field product-catalog '.image')" \
        "$(awk '/repository:/ {print $2; exit}' "$DIR/baseline.yaml"):$(awk '/tag:/ {print $2; exit}' "$DIR/baseline.yaml")"
    check 3 "checkout image" "$(container_field checkout '.image')" "ghcr.io/open-telemetry/demo:3.1.0-checkout"
    payment_limit=$(container_field payment '.resources.limits.memory')
    if [ "$(mebibytes "$payment_limit")" -ge 140 ]; then
        check 4 "payment memory limit (140Mi or more)" "$payment_limit" "$payment_limit"
    else
        check 4 "payment memory limit" "$payment_limit" "140Mi"
    fi
    check 5 "email image" "$(container_field email '.image')" "ghcr.io/open-telemetry/demo:3.1.0-email"
    check 6 "frontend-config CART_ADDR" "$(config_value frontend-config CART_ADDR)" "cart:8080"
    check 7 "product-catalog-config DB_MAX_OPEN_CONNS" "$(config_value product-catalog-config DB_MAX_OPEN_CONNS)" "10"
    pool_env_name=$(container_field product-catalog '.env[?(@.name=="DB_MAX_OPEN_CONNS")].name')
    pool_env=$(container_field product-catalog '.env[?(@.name=="DB_MAX_OPEN_CONNS")].value')
    if [ -z "$pool_env_name" ]; then
        pool_env="not set"
    elif [ -z "$pool_env" ]; then
        pool_env="set from a ConfigMap"
    fi
    check 8 "product-catalog env DB_MAX_OPEN_CONNS" "$pool_env" "not set"
}

case "${1:-}" in
    setup)
        if [ ! -f "$ORIGINAL_REVISION_FILE" ]; then
            helm history "$RELEASE" -n "$NAMESPACE" --max 1 | awk 'NR == 2 {print $1}' > "$ORIGINAL_REVISION_FILE"
        fi
        log "Original Helm revision: $(cat "$ORIGINAL_REVISION_FILE")"
        kubectl apply -f "$DIR/configmaps.yaml"
        upgrade
        kubectl -n "$NAMESPACE" rollout status deployment/product-catalog --timeout=5m
        kubectl -n "$NAMESPACE" rollout status deployment/frontend --timeout=5m
        log "Baseline is ready"
        ;;
    1)
        log "Scenario 1 started: product-catalog bad-get-product-errors, service.version 3.1.1"
        upgrade -f "$DIR/scenario-1.yaml"
        record_deploy product-catalog 3.1.1 "Show product ratings on the product page"
        ;;
    2)
        log "Scenario 2 started: product-catalog bad-slow-query, service.version 3.1.2"
        upgrade -f "$DIR/scenario-2.yaml"
        record_deploy product-catalog 3.1.2 "Sort the product list by popularity"
        ;;
    3)
        log "Scenario 3 started: checkout bad-missing-config, service.version 3.1.1"
        upgrade -f "$DIR/scenario-3.yaml"
        record_deploy checkout 3.1.1 "Calculate tax through the new tax service"
        ;;
    4)
        log "Scenario 4 started: payment memory limit ${PAYMENT_MEMORY_LIMIT:-40Mi}"
        upgrade --set components.payment.resources.limits.memory="${PAYMENT_MEMORY_LIMIT:-40Mi}"
        record_deploy payment 3.1.0 "Lower the payment memory limit to ${PAYMENT_MEMORY_LIMIT:-40Mi}"
        ;;
    5)
        log "Scenario 5 started: email image tag 3.1.0-emial"
        upgrade --set components.email.imageOverride.tag=3.1.0-emial
        record_deploy email 3.1.0-emial "Update the email image"
        ;;
    6)
        log "Scenario 6 started: frontend-config CART_ADDR=cart-v2:8080"
        set_config frontend-config CART_ADDR cart-v2:8080
        restart frontend
        ;;
    7)
        log "Scenario 7 started: product-catalog-config DB_MAX_OPEN_CONNS=2"
        set_config product-catalog-config DB_MAX_OPEN_CONNS 2
        restart product-catalog
        ;;
    8)
        log "Scenario 8 started: product-catalog env DB_MAX_OPEN_CONNS=2"
        upgrade -f "$DIR/scenario-8.yaml"
        record_deploy product-catalog 3.1.0 "Update product-catalog settings"
        ;;
    baseline)
        upgrade
        log "Baseline re-applied"
        ;;
    revert)
        case "${2:-}" in
            1|2|8)
                upgrade
                record_deploy product-catalog 3.1.0 "Roll back to 3.1.0"
                ;;
            3)
                upgrade
                record_deploy checkout 3.1.0 "Roll back to 3.1.0"
                ;;
            4)
                upgrade
                record_deploy payment 3.1.0 "Restore the payment memory limit"
                ;;
            5)
                upgrade
                record_deploy email 3.1.0 "Roll back to 3.1.0"
                ;;
            6)
                set_config frontend-config CART_ADDR cart:8080
                restart frontend
                ;;
            7)
                set_config product-catalog-config DB_MAX_OPEN_CONNS 10
                restart product-catalog
                ;;
            *)
                usage
                exit 1
                ;;
        esac
        log "Scenario ${2} reverted"
        ;;
    status)
        helm history "$RELEASE" -n "$NAMESPACE" --max 3
        echo
        kubectl -n "$NAMESPACE" get deployment product-catalog checkout payment email frontend \
            -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,UPDATED:.status.updatedReplicas,IMAGE:.spec.template.spec.containers[0].image'
        echo
        echo "Compared with the baseline:"
        compare
        echo
        if [ "$changed" = 1 ]; then
            echo "A scenario is still active: run the revert shown next to CHANGED before the next scenario"
        else
            echo "Everything matches the baseline"
        fi
        echo
        unhealthy=$(kubectl -n "$NAMESPACE" get pods --no-headers |
            awk '{split($2, r, "/"); if ($3 != "Completed" && ($3 != "Running" || r[1] != r[2])) print}')
        if [ -n "$unhealthy" ]; then
            echo "Pods that are not healthy:"
            echo "$unhealthy"
        else
            echo "All pods are healthy"
        fi
        ;;
    watch)
        log "Waiting for everything to match the baseline again (checks every 20 s, Ctrl+C to stop)"
        while true; do
            compare > /dev/null
            if [ "$changed" = 0 ]; then
                echo
                log "Back to the baseline"
                break
            fi
            printf '.'
            sleep 20
        done
        ;;
    restore)
        revision="${ORIGINAL_REVISION:-}"
        if [ -z "$revision" ] && [ -f "$ORIGINAL_REVISION_FILE" ]; then
            revision=$(cat "$ORIGINAL_REVISION_FILE")
        fi
        if [ -z "$revision" ]; then
            echo "No saved revision: run setup first or set ORIGINAL_REVISION" >&2
            exit 1
        fi
        helm rollback "$RELEASE" "$revision" -n "$NAMESPACE" --wait --timeout 10m
        kubectl delete -f "$DIR/configmaps.yaml" --ignore-not-found
        rm -f "$ORIGINAL_REVISION_FILE"
        log "Release restored to its state before the tests"
        ;;
    *)
        usage
        exit 1
        ;;
esac
