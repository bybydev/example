SHELL := /bin/bash

.PHONY: generate build test clean download-models verify-models install-model-fixtures

generate:
	xcodegen generate

build:
	xcodebuild -project Inkribe.xcodeproj -scheme InkribeMac -configuration Debug build

test:
	xcodebuild -project Inkribe.xcodeproj -scheme InkribeMac -configuration Debug test

download-models:
	./scripts/download-models.sh

verify-models:
	./scripts/verify-models.sh

install-model-fixtures:
	./scripts/install-model-fixtures.sh

clean:
	rm -rf .build DerivedData
