#!/usr/bin/env bash
set -euo pipefail

kubectl kustomize apps/nginx/overlays/dev
