# Fault scenarios

Bad deploys and config changes for testing Lens against the demo on the
`astronomy-gke` cluster, where it runs as the Helm release `astronomy` in the
`otel-demo` namespace (chart `opentelemetry-demo` 0.42.7).

Run everything from Google Cloud Shell. The cluster only accepts control plane
connections from allowlisted networks and Google Cloud addresses.

```sh
git clone -b jenkins-pipeline https://github.com/SHUBHAMKUMAR900/opentelemetry-demo.git
cd opentelemetry-demo/fault-scenarios
gcloud container clusters get-credentials astronomy-gke --zone asia-south1-a --project ct-lens
./run.sh setup
```

`setup` saves the current Helm revision, creates the two ConfigMaps and deploys
the healthy baseline: product-catalog runs our image that reads
`DB_MAX_OPEN_CONNS`, and frontend reads `CART_ADDR` from a ConfigMap.

Then run one scenario at a time and leave 5 to 10 minutes between them:

| Command | Type | Service | Change | Expected Lens action |
| --- | --- | --- | --- | --- |
| `./run.sh 1` | Bad deploy | product-catalog | Image `bad-get-product-errors`: GetProduct queries a column that does not exist | Roll back |
| `./run.sh 2` | Bad deploy | product-catalog | Image `bad-slow-query`: ListProducts takes 0.5 s longer | Roll back |
| `./run.sh 3` | Bad deploy | checkout | Image `bad-missing-config`: needs `TAX_SERVICE_ADDR`, crash-loops without it | Roll back |
| `./run.sh 4` | Bad deploy | payment | Memory limit 140Mi to 40Mi (`PAYMENT_MEMORY_LIMIT`) | Restore the limit |
| `./run.sh 5` | Bad deploy | email | Image tag `3.1.0-emial` does not exist | Roll back |
| `./run.sh 6` | Config | frontend | `frontend-config` points `CART_ADDR` at `cart-v2:8080` | Revert and restart |
| `./run.sh 7` | Config | product-catalog | `product-catalog-config` sets `DB_MAX_OPEN_CONNS` from 10 to 2 | Revert and restart |
| `./run.sh 8` | Config | product-catalog | Same pool change through an environment variable | None (gap test) |

Scenarios 3, 4 and 5 do not affect users: with one replica, Kubernetes keeps the
old pod serving until the new one is ready, so only the rollout gets stuck.

Other commands:

- `./run.sh status` shows the Helm revision, every setting that still differs
  from the baseline with the revert command for it, and every pod that is not
  healthy. Scenarios 1, 2, 6, 7 and 8 keep all pods healthy, so check the
  baseline comparison, not the pod list, before starting the next scenario.
- `./run.sh watch` waits, checking every 20 seconds, until everything matches
  the baseline again and prints the time. Start it right after a scenario to
  record when Lens rolled it back. A payment memory limit of 140Mi or more
  counts as fixed.
- `./run.sh revert <n>` undoes scenario `n` when Lens did not.
- `./run.sh restore` rolls the release back to the revision saved by `setup`
  and deletes the ConfigMaps. Run it once all scenarios are done.

The bad images are built by the Go Jenkins pipeline with `CUSTOM_TAG` set to the
image tag above, from a commit that is reverted right after the build.
