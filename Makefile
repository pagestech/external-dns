# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#? cover: Creates coverage report for whole project excluding vendor and opens result in the default browser
.PHONY: cover cover-html
.DEFAULT_GOAL := build

cover:
	@go test -cover -coverprofile=cover.out -v ./...

#? cover-html: Run tests with coverage and open coverage report in the browser
cover-html: cover
	@go tool cover -html=cover.out

#? controller-gen: download controller-gen if necessary
controller-gen-install:
	@scripts/install-tools.sh --generator
ifeq (, $(shell which controller-gen))
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

#? golangci-lint-install: Install golangci-lint tool
golangci-lint-install:
	@scripts/install-tools.sh --golangci

#? go-lint: Run the golangci-lint tool
.PHONY: go-lint
go-lint: golangci-lint-install
	golangci-lint config verify
	gofmt -l -s -w .
	golangci-lint run --timeout=30m --fix ./...

#? licensecheck: Run the to check for license headers
.PHONY: licensecheck
licensecheck:
	@echo ">> checking license header"
	@licRes=$$(for file in $$(find . -type f -iname '*.go' ! -path './vendor/*') ; do \
               awk 'NR<=5' $$file | grep -Eq "(Copyright|generated|GENERATED)" || echo $$file; \
       done); \
       if [ -n "$${licRes}" ]; then \
               echo "license header checking failed:"; echo "$${licRes}"; \
               exit 1; \
       fi

#? oas-lint: Requires to install spectral. See github.com/stoplightio/spectral
oas-lint:
	spectral lint api/*.yaml

#? lint: Run all the linters
.PHONY: lint
lint: licensecheck go-lint oas-lint

#? crd: Generates CRD using controller-gen and copy it into chart
.PHONY: crd
crd: controller-gen-install
	${CONTROLLER_GEN} object crd:crdVersions=v1 paths="./endpoint/..."
	${CONTROLLER_GEN} object crd:crdVersions=v1 paths="./apis/..." output:crd:stdout | yamlfmt - | yq eval '.' --no-doc --split-exp '"./config/crd/standard/" + .metadata.name + ".yaml"'
	yq eval '.metadata.annotations |= with_entries(select(.key | test("kubernetes\.io")))' --no-doc --split-exp '"./charts/external-dns/crds/" + .metadata.name + ".yaml"' ./config/crd/standard/*.yaml

#? test: The verify target runs tasks similar to the CI tasks, but without code coverage
.PHONY: test
test:
	go test -race -coverprofile=profile.cov ./...

#? build: The build targets allow to build the binary and container image
.PHONY: build

BINARY        ?= external-dns
SOURCES        = $(shell find . -name '*.go')
IMAGE_STAGING  = gcr.io/k8s-staging-external-dns/$(BINARY)
REGISTRY      ?= us.gcr.io/k8s-artifacts-prod/external-dns
IMAGE         ?= $(REGISTRY)/$(BINARY)
VERSION       ?= $(shell git describe --tags --always --dirty --match "v*")
GIT_COMMIT    ?= $(shell git rev-parse --short HEAD)
BUILD_FLAGS   ?= -v
LDFLAGS       ?= -X sigs.k8s.io/external-dns/pkg/apis/externaldns.Version=$(VERSION) -w -s
LDFLAGS       += -X sigs.k8s.io/external-dns/pkg/apis/externaldns.GitCommit=$(GIT_COMMIT)
ARCH          ?= amd64
SHELL          = /bin/bash
IMG_PLATFORM  ?= linux/amd64,linux/arm64,linux/arm/v7
IMG_PUSH      ?= true
IMG_SBOM      ?= none

build: build/$(BINARY)

build/$(BINARY): $(SOURCES)
	CGO_ENABLED=0 go build -o build/$(BINARY) $(BUILD_FLAGS) -ldflags "$(LDFLAGS)" .

build.push/multiarch: ko
	KO_DOCKER_REPO=${IMAGE} \
    VERSION=${VERSION} \
    ko build --tags ${VERSION} --bare --sbom ${IMG_SBOM} \
      --image-label org.opencontainers.image.source="https://github.com/kubernetes-sigs/external-dns" \
      --image-label org.opencontainers.image.revision=$(shell git rev-parse HEAD) \
      --platform=${IMG_PLATFORM}  --push=${IMG_PUSH} .

build.image/multiarch:
	$(MAKE) IMG_PUSH=false build.push/multiarch

build.image:
	$(MAKE) IMG_PLATFORM=linux/$(ARCH) build.image/multiarch

build.image-amd64:
	$(MAKE) ARCH=amd64 build.image

build.image-arm64:
	$(MAKE) ARCH=arm64 build.image

build.image-arm/v7:
	$(MAKE) ARCH=arm/v7 build.image

build.push:
	$(MAKE) IMG_PLATFORM=linux/$(ARCH) build.push/multiarch

build.push-amd64:
	$(MAKE) ARCH=amd64 build.push

build.push-arm64:
	$(MAKE) ARCH=arm64 build.push

build.push-arm/v7:
	$(MAKE) ARCH=arm/v7 build.push

build.arm64:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o build/$(BINARY) $(BUILD_FLAGS) -ldflags "$(LDFLAGS)" .

build.amd64:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o build/$(BINARY) $(BUILD_FLAGS) -ldflags "$(LDFLAGS)" .

build.arm/v7:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -o build/$(BINARY) $(BUILD_FLAGS) -ldflags "$(LDFLAGS)" .

clean:
	@rm -rf build
	@go clean -cache

.PHONY: release.staging
#? release.staging: Builds and push container images to the staging bucket.
release.staging: test
	IMAGE=$(IMAGE_STAGING) $(MAKE) build.push/multiarch

release.prod: test
	$(MAKE) build.push/multiarch

.PHONY: ko
ko:
	scripts/install-ko.sh

.PHONY: generate-flags-documentation
#? generate-flags-documentation: Generate documentation (docs/flags.md)
generate-flags-documentation:
	go run internal/gen/docs/flags/main.go

.PHONY: generate-metrics-documentation
#? generate-metrics-documentation: Generate documentation (docs/monitoring/metrics.md)
generate-metrics-documentation:
	go run internal/gen/docs/metrics/main.go

#? pre-commit-install: Install pre-commit hooks
pre-commit-install:
	@pre-commit install
	@pre-commit gc

#? pre-commit-uninstall: Uninstall pre-commit hooks
pre-commit-uninstall:
	@pre-commit uninstall

#? pre-commit-validate: Validate files with pre-commit hooks
pre-commit-validate:
	@pre-commit run --all-files

.PHONY: help
#? help: Get more info on available commands
help: Makefile
	@sed -n 's/^#?//p' $< | column -t -s ':' |  sort | sed -e 's/^/ /'

#? helm-test: Run unit tests
helm-test:
	scripts/helm-tools.sh --helm-unittest

#? helm-template: Run helm template
helm-template:
	scripts/helm-tools.sh --helm-template

#? helm-lint: Run helm linting (schema,docs)
helm-lint:
	scripts/helm-tools.sh --schema
	scripts/helm-tools.sh --docs

.PHONY: go-dependency
#? go-dependency: Dependency maintanance
go-dependency:
	go mod tidy

.PHONY: mkdocs-serve
#? mkdocs-serve: Run the builtin development server for mkdocs
mkdocs-serve:
	@$(info "contribute to documentation docs/contributing/dev-guide.md")
	@mkdocs serve
