SHELL := /bin/bash

.PHONY: generate build test clean

generate:
	xcodegen generate

build:
	xcodebuild -project Inkribe.xcodeproj -scheme Inkribe -configuration Debug build

test:
	xcodebuild -project Inkribe.xcodeproj -scheme Inkribe -configuration Debug test

clean:
	rm -rf .build DerivedData
