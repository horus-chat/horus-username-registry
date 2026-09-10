#!/usr/bin/env bash
# Back-compat wrapper → deploy.sh local
exec "$(cd "$(dirname "$0")" && pwd)/deploy.sh" local
