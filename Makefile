.PHONY: help build test test-linux lint up prod down refresh logs
.DEFAULT_GOAL := help

help: ## Show this list
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

build: ## swift build
	swift build

test: ## swift test
	swift test

lint: ## swiftlint
	swiftlint

# GRDB needs sqlite3.h; the swift image ships only the runtime library.
test-linux: ## swift test inside the swift:6.3.3-noble image
	docker run --rm -v "$(PWD)":/src -w /src swift:6.3.3-noble \
	  sh -c 'apt-get update -q && apt-get install -qy --no-install-recommends libsqlite3-dev && swift test'

up: ## Build the image and (re)start the container
	docker compose up -d --build

prod: up ## Alias for up (matches AppcastHosting)

down: ## Stop and remove the container
	docker compose down

# Rebuild the image from scratch so the OS packages inside it are current (see Dockerfile), then
# recreate the container if the image changed. Meant for a weekly cron. The BuildKit cache mounts
# survive --no-cache, so the Swift build itself stays incremental.
refresh: ## Weekly: full rebuild with fresh OS packages, recreate, prune
	docker compose build --pull --no-cache
	docker compose up -d
	docker image prune -f

logs: ## Follow container logs
	docker compose logs -f --tail=100
