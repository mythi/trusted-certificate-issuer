REGISTRY ?= intel
IMG_TAG ?= latest
# Image URL to use all building/pushing image targets
IMG ?= $(REGISTRY)/trusted-certificate-issuer:$(IMG_TAG)
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true,preserveUnknownFields=false"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

vendor:
	go mod tidy -compat=1.17
	go mod vendor

manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=role paths="./controllers/..." paths="./api/..."

generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./api/..."

fmt: ## Run go fmt against code.
	@go fmt ./...

vet: ## Run go vet against code.
	@go vet ./...

ENVTEST_ASSETS_DIR=$(shell pwd)/testbin
test: vendor manifests fmt ## Run tests.
	mkdir -p ${ENVTEST_ASSETS_DIR}
	test -f ${ENVTEST_ASSETS_DIR}/setup-envtest.sh || curl -sSLo ${ENVTEST_ASSETS_DIR}/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.7.2/hack/setup-envtest.sh
	source ${ENVTEST_ASSETS_DIR}/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR); ACK_GINKGO_DEPRECATIONS=1.16.4 go test ./... -coverprofile cover.out

##@ Build

build: generate fmt vet ## Build manager binary.
	go build -o bin/tcs-issuer main.go

run: manifests generate fmt vet ## Run a controller from your host.
	go run ./main.go

# additional arguments to pass to 'docker build'
BUILD_ARGS ?=
# Adjust this argument and accodingly the 'enclave-config/sign-enclave.sh'
# script in CI build system to reflect with the right private key
# and/or signing with external tool.
DOCKER_BUILD_DEPS ?= enclave-config/privatekey.pem
docker-build: ${DOCKER_BUILD_DEPS} vendor ## Build docker image with the manager.
	docker build ${BUILD_ARGS} -t ${IMG} .

enclave-config/privatekey.pem:
	openssl genrsa -3 -out enclave-config/privatekey.pem 3072

docker-push: ## Push docker image with the manager.
	docker push ${IMG}

##@ Deployment

install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image tcs-issuer=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

deploy-manifests: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image tcs-issuer=${IMG}
	mkdir -p deployment && $(KUSTOMIZE) build config/default -o deployment/tcs_issuer.yaml
	mkdir -p deployment/crds && $(KUSTOMIZE) build -o deployment/crds config/crd
## Rename CRDs; remove prefixed type information
	@cd deployment/crds; for f in $$(ls ./apiextensions*.yaml); do newname=$$(echo $$f|sed -e 's|apiextensions.k8s.io_v1_customresourcedefinition_\(.*\)|\1|g'); mv $$f $$newname; done

undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/default | kubectl delete -f -


CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.4.1)

KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v3@v3.8.7)

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go get $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef
