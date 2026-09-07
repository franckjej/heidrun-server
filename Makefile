.PHONY: build test test-linux lint up down refresh logs

build:
	swift build

test:
	swift test

lint:
	swiftlint

# GRDB needs sqlite3.h; the swift image ships only the runtime library.
test-linux:
	docker run --rm -v "$(PWD)":/src -w /src swift:6.3.3-noble \
	  sh -c 'apt-get update -q && apt-get install -qy --no-install-recommends libsqlite3-dev && swift test'

up:
	docker compose up -d --build

down:
	docker compose down

# Rebuild the image from scratch so the OS packages inside it are current (see Dockerfile), then
# recreate the container if the image changed. Meant for a weekly cron. The BuildKit cache mounts
# survive --no-cache, so the Swift build itself stays incremental.
refresh:
	docker compose build --pull --no-cache
	docker compose up -d
	docker image prune -f

logs:
	docker compose logs -f --tail=100
