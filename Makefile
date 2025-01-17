MAKEFLAGS += --no-print-directory
CONTAINER_RUNTIME ?= podman
IMAGE ?= quay.io/akaris/testpmd:latest

.PHONY: clean
clean:
	rm -Rf build-dir/*

.PHONY: build
build: ## Build dpdk-testpmd locally.
	./build-dpdk.sh

.PHONY: build-container
build-container: ## Build the container. CONTAINER_RUNTIME and IMAGE to override default behavior.
	$(CONTAINER_RUNTIME) build -t $(IMAGE) .

.PHONY: push-container
push-container: ## Push the container. CONTAINER_RUNTIME and IMAGE to override default behavior.
	$(CONTAINER_RUNTIME) push $(IMAGE)

# https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: kustomize-machineconfig
kustomize-machineconfig:
	@kustomize build yamls/machineconfig | \
		envsubst

.PHONY: kustomize-prerequisites
kustomize-prerequisites:
	@kustomize build yamls/prerequisites | \
		envsubst

.PHONY: kustomize-testpmd-portforwarder
ifeq ($(ROOT), true)
kustomize-testpmd-portforwarder: export RUN_AS_NON_ROOT = false
kustomize-testpmd-portforwarder: export RUN_AS_USER = 0
kustomize-testpmd-portforwarder: export RUN_AS_GROUP = 0
kustomize-testpmd-portforwarder: export FS_GROUP = 0
else
kustomize-testpmd-portforwarder: export RUN_AS_NON_ROOT = true
kustomize-testpmd-portforwarder: export RUN_AS_USER = 1001
kustomize-testpmd-portforwarder: export RUN_AS_GROUP = 2001
kustomize-testpmd-portforwarder: export FS_GROUP = 2002
endif
kustomize-testpmd-portforwarder:
	@cat yamls/testpmd-portforwarder/configmap.yaml
	@cat yamls/testpmd-portforwarder/deployment.yaml | envsubst

.PHONY: kustomize-testpmd-tap
ifeq ($(ROOT), true)
kustomize-testpmd-tap: export RUN_AS_NON_ROOT = false
kustomize-testpmd-tap: export RUN_AS_USER = 0
kustomize-testpmd-tap: export RUN_AS_GROUP = 0
kustomize-testpmd-tap: export FS_GROUP = 0
else
kustomize-testpmd-tap: export RUN_AS_NON_ROOT = true
kustomize-testpmd-tap: export RUN_AS_USER = 1001
kustomize-testpmd-tap: export RUN_AS_GROUP = 2001
kustomize-testpmd-tap: export FS_GROUP = 2002
endif
kustomize-testpmd-tap:
	@cat yamls/testpmd-tap/tap.yaml
	@cat yamls/testpmd-tap/configmap.yaml
	@cat yamls/testpmd-tap/deployment.yaml | envsubst

.PHONY: deploy-machineconfig
deploy-machineconfig: ## Apply machineconfig changes for rootless DPDK.
	make kustomize-machineconfig | oc apply -f -

.PHONY: undeploy-machineconfig
undeploy-machineconfig: ## Apply machineconfig changes for rootless DPDK.
	make kustomize-machineconfig | oc delete -f -

.PHONY: deploy-testpmd-portforwarder
deploy-testpmd-portforwarder: ## Deploy kubernetes resources for testpmd-portforwarder.
	make kustomize-prerequisites | oc apply -f -
	make kustomize-testpmd-portforwarder | oc apply -f -

.PHONY: undeploy-testpmd-portforwarder
undeploy-testpmd-portforwarder: ## Undeploy testpmd-portforwarder resources.
	make kustomize-testpmd-portforwarder | oc delete -f -
	make kustomize-prerequisites | oc delete -f -

.PHONY: deploy-testpmd-tap
deploy-testpmd-tap: ## Deploy kubernetes resources for testpmd-tap.
	make kustomize-prerequisites | oc apply -f -
	make kustomize-testpmd-tap | oc apply -f -

.PHONY: undeploy-testpmd-tap
undeploy-testpmd-tap: ## Undeploy testpmd-tap resources.
	make kustomize-testpmd-tap | oc delete -f -
	make kustomize-prerequisites | oc delete -f -

embed-readme:
	embedmd -w README.md
