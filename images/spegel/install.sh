#!/bin/sh
set -e

cd "$(dirname "$0")"

helm upgrade --create-namespace --namespace spegel \
  --install spegel ../../download/charts/spegel-0.8.1.tgz \
  --values spegel-values.yaml \
  --wait
