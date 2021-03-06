MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:
.SUFFIXES:

# The version which will be reported by the --version argument of each binary
# and which will be used as the Docker image tag
VERSION ?= $(shell git describe --tags)

# Image URL to use all building/pushing image targets
IMG ?= controller:${VERSION}
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# BIN is the directory where tools will be installed
export BIN ?= ${CURDIR}/bin

OS := $(shell go env GOOS)
ARCH := $(shell go env GOARCH)

# Kind
KIND_VERSION := 0.9.0
KIND := ${BIN}/kind-${KIND_VERSION}
K8S_CLUSTER_NAME := sample-external-issuer-e2e

# cert-manager
CERT_MANAGER_VERSION ?= 1.0.4

all: manager

# Run tests
test: generate fmt vet manifests
	go test ./... -coverprofile cover.out

# Build manager binary
manager: generate fmt vet
	go build -o bin/manager main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet manifests
	go run ./main.go

# Install CRDs into a cluster
install: manifests
	kustomize build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: manifests
	kustomize build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy:
	cd config/manager && kustomize edit set image controller=${IMG}
	kustomize build config/default | kubectl apply -f -

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

# Run go fmt against code
fmt:
	go fmt ./...

# Run go vet against code
vet:
	go vet ./...

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# Build the docker image
docker-build:
	docker build \
		--build-arg VERSION=$(VERSION) \
		--tag ${IMG} \
		--file Dockerfile \
		${CURDIR}

# Push the docker image
docker-push:
	docker push ${IMG}

# find or download controller-gen
# download controller-gen if necessary
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.2.5 ;\
	rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

# ==================================
# E2E testing
# ==================================
.PHONY: kind-cluster
kind-cluster: ## Use Kind to create a Kubernetes cluster for E2E tests
kind-cluster: ${KIND}
	 ${KIND} get clusters | grep ${K8S_CLUSTER_NAME} || ${KIND} create cluster --name ${K8S_CLUSTER_NAME}

.PHONY: kind-load
kind-load: ## Load all the Docker images into Kind
	${KIND} load docker-image --name ${K8S_CLUSTER_NAME} ${IMG}

.PHONY: kind-export-logs
kind-export-logs:
	${KIND} export logs --name ${K8S_CLUSTER_NAME} ${E2E_ARTIFACTS_DIRECTORY}


.PHONY: deploy-cert-manager
deploy-cert-manager: ## Deploy cert-manager in the configured Kubernetes cluster in ~/.kube/config
	kubectl apply --filename=https://github.com/jetstack/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.yaml
	kubectl wait --for=condition=Available --timeout=300s apiservice v1.cert-manager.io

e2e:
	kubectl apply --filename config/samples

	kubectl wait --for=condition=Ready --timeout=5s issuers.sample-issuer.example.com issuer-sample
	kubectl wait --for=condition=Ready --timeout=5s  certificaterequests.cert-manager.io issuer-sample
	kubectl wait --for=condition=Ready --timeout=5s  certificates.cert-manager.io certificate-by-issuer

	kubectl wait --for=condition=Ready --timeout=5s clusterissuers.sample-issuer.example.com clusterissuer-sample
	kubectl wait --for=condition=Ready --timeout=5s  certificaterequests.cert-manager.io clusterissuer-sample
	kubectl wait --for=condition=Ready --timeout=5s  certificates.cert-manager.io certificate-by-clusterissuer

	kubectl delete --filename config/samples

# ==================================
# Download: tools in ${BIN}
# ==================================
${BIN}:
	mkdir -p ${BIN}

${KIND}: ${BIN}
	curl -sSL -o ${KIND} https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-${OS}-${ARCH}
	chmod +x ${KIND}
