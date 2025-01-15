#!/bin/bash

set -eux

oc new-project dpdktest || true
oc apply -f sriovnetwork.yaml
oc apply -f deployment.yaml
