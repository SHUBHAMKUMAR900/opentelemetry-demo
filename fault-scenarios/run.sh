#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

RELEASE=astronomy
NAMESPACE=otel-demo
CHART=opentelemetry-demo
CHART_REPO=https://open-telemetry.github.io/opentelemetry-helm-charts
CHART_VERSION=0.42.7
BASE_IMAGE=ghcr.io/open-telemetry/demo
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_REVISION_FILE="$HOME/.fault-scenarios-original-revision"

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
  baseline     Re-apply the healthy baseline through Helm, ending every Helm scenario
  watch        Print every scenario that starts or gets fixed, with the time
  revert <n>   Undo scenario n by hand, if Lens did not, and leave the other scenarios running
  status       Show the Helm revision, what still differs from the baseline and every pod that is not healthy
  restore      Roll the release back to the revision saved by setup and delete the ConfigMaps

Scenarios add up: starting one leaves the others running. 1 and 2 both change
product-catalog, so the second of them deploys an image with both bugs.
EOF
}

log() {
    echo "[$(TZ=Asia/Kolkata date '+%H:%M:%S IST')] $*"
}

args=()

upgrade() {
    helm upgrade "$RELEASE" "$CHART" --repo "$CHART_REPO" --version "$CHART_VERSION" \
        --namespace "$NAMESPACE" --reuse-values ${args[@]+"${args[@]}"} "$@"
}

set_config() {
    kubectl -n "$NAMESPACE" patch configmap "$1" --type merge -p "{\"data\":{\"$2\":\"$3\"}}"
}

restart() {
    kubectl -n "$NAMESPACE" rollout restart "deployment/$1"
}

container_field() {
    kubectl -n "$NAMESPACE" get deployment "$1" -o jsonpath="{.spec.template.spec.containers[0]$2}"
}

config_value() {
    kubectl -n "$NAMESPACE" get configmap "$1" -o jsonpath="{.data.$2}"
}

mebibytes() {
    case "$1" in
        *Gi) echo $(( ${1%Gi} * 1024 )) ;;
        *Mi) echo "${1%Mi}" ;;
        *) echo 0 ;;
    esac
}

add_baseline() {
    case "$1" in
        product-catalog|checkout)
            args+=(--set "components.$1.imageOverride.repository=$BASE_IMAGE"
                --set "components.$1.imageOverride.tag=3.1.0-$1"
                --set-json "components.$1.envOverrides=[]")
            ;;
        email)
            args+=(--set "components.email.imageOverride.repository=$BASE_IMAGE"
                --set "components.email.imageOverride.tag=3.1.0-email")
            ;;
        payment)
            args+=(--set "components.payment.resources.limits.memory=140Mi")
            ;;
    esac
}

# Pins every service except $1 to what it runs now, so that --reuse-values does not
# redeploy a scenario that Lens already rolled back with kubectl
keep_live() {
    local service image attributes
    for service in product-catalog checkout email; do
        image=$(container_field "$service" '.image')
        if [ "$service" = "$1" ] || [ -n "$(container_field "$service" '.env[?(@.name=="DB_MAX_OPEN_CONNS")].name')" ]; then
            continue
        elif [ "$image" = "$BASE_IMAGE:3.1.0-$service" ]; then
            add_baseline "$service"
        else
            args+=(--set "components.$service.imageOverride.repository=${image%:*}"
                --set "components.$service.imageOverride.tag=${image##*:}")
            if [ "$service" != email ]; then
                # Escapes the commas, which --set would otherwise read as separators
                attributes=$(container_field "$service" '.env[?(@.name=="OTEL_RESOURCE_ATTRIBUTES")].value' | sed 's/,/\\,/g')
                args+=(--set "components.$service.envOverrides[0].name=OTEL_RESOURCE_ATTRIBUTES"
                    --set "components.$service.envOverrides[0].value=$attributes")
            fi
        fi
    done
    if [ "$1" != payment ]; then
        args+=(--set "components.payment.resources.limits.memory=$(container_field payment '.resources.limits.memory')")
    fi
}

product_catalog_tag() {
    local image
    image=$(container_field product-catalog '.image')
    echo "${image##*:}"
}

# A product-catalog release on top of another bad one keeps its bug, as a real release built on that code would
stack_on() {
    local tag
    tag=$(product_catalog_tag)
    case "$tag" in
        "$1"|bad-errors-and-slow)
            log "product-catalog already runs $tag, so this release keeps that bug too: image bad-errors-and-slow"
            args+=(--set components.product-catalog.imageOverride.tag=bad-errors-and-slow)
            ;;
    esac
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

compare() {
    changed=0
    check 1 "product-catalog image" "$(container_field product-catalog '.image')" "$BASE_IMAGE:3.1.0-product-catalog"
    check 3 "checkout image" "$(container_field checkout '.image')" "$BASE_IMAGE:3.1.0-checkout"
    payment_limit=$(container_field payment '.resources.limits.memory')
    if [ "$(mebibytes "$payment_limit")" -ge 140 ]; then
        check 4 "payment memory limit (140Mi or more)" "$payment_limit" "$payment_limit"
    else
        check 4 "payment memory limit" "$payment_limit" "140Mi"
    fi
    check 5 "email image" "$(container_field email '.image')" "$BASE_IMAGE:3.1.0-email"
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
        upgrade -f "$DIR/baseline.yaml"
        kubectl -n "$NAMESPACE" rollout status deployment/product-catalog --timeout=5m
        kubectl -n "$NAMESPACE" rollout status deployment/frontend --timeout=5m
        log "Baseline is ready"
        ;;
    1)
        log "Scenario 1 started: product-catalog bad-get-product-errors, service.version 3.1.1"
        keep_live product-catalog
        stack_on bad-slow-query
        upgrade -f "$DIR/scenario-1.yaml"
        ;;
    2)
        log "Scenario 2 started: product-catalog bad-slow-query, service.version 3.1.2"
        keep_live product-catalog
        stack_on bad-get-product-errors
        upgrade -f "$DIR/scenario-2.yaml"
        ;;
    3)
        log "Scenario 3 started: checkout bad-missing-config, service.version 3.1.1"
        keep_live checkout
        upgrade -f "$DIR/scenario-3.yaml"
        ;;
    4)
        log "Scenario 4 started: payment memory limit ${PAYMENT_MEMORY_LIMIT:-40Mi}"
        keep_live payment
        upgrade --set components.payment.resources.limits.memory="${PAYMENT_MEMORY_LIMIT:-40Mi}"
        ;;
    5)
        log "Scenario 5 started: email image tag 3.1.0-emial"
        keep_live email
        upgrade --set components.email.imageOverride.tag=3.1.0-emial
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
        keep_live product-catalog
        upgrade -f "$DIR/scenario-8.yaml"
        ;;
    baseline)
        upgrade -f "$DIR/baseline.yaml"
        log "Baseline re-applied"
        ;;
    revert)
        case "${2:-}" in
            1|2|3|4|5|8)
                case "$2" in
                    3) service=checkout ;;
                    4) service=payment ;;
                    5) service=email ;;
                    *) service=product-catalog ;;
                esac
                keep_live "$service"
                if [ "$2" -le 2 ] && [ "$(product_catalog_tag)" = bad-errors-and-slow ]; then
                    log "product-catalog runs the bugs of scenarios 1 and 2, removing only the bug of scenario $2"
                    upgrade -f "$DIR/scenario-$((3 - $2)).yaml"
                else
                    add_baseline "$service"
                    upgrade
                fi
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
            echo "Scenarios still active: every CHANGED line, with the command that reverts it"
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
        before=$(compare)
        log "Active now:"
        echo "$before" | grep CHANGED || echo "  nothing, everything matches the baseline"
        log "Printing every change from here on (checks every 20 s, Ctrl+C to stop)"
        while true; do
            sleep 20
            now=$(compare)
            changes=$(awk 'NR == FNR {line[FNR] = $0; next} $0 != line[FNR]' <(echo "$before") <(echo "$now"))
            if [ -n "$changes" ]; then
                echo
                echo "$changes" | while IFS= read -r line; do log "$line"; done
                if ! echo "$now" | grep -q CHANGED; then
                    log "Everything matches the baseline"
                fi
            else
                printf '.'
            fi
            before=$now
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
