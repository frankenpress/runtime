# FrankenPress runtime — common dev tasks.
#
# Usage:
#   make build              build the runtime image (tag: runtime:dev)
#   make up                 docker compose up -d (runtime + redis)
#   make down               docker compose down -v (drop volumes)
#   make test               run the cache-spike integration test against a running stack
#   make ci                 build + up + test + down (one-shot CI loop locally)
#   make shell              shell into the running runtime container
#   make logs               tail runtime logs
#   make size               report compressed image size

IMAGE ?= runtime:dev
PHP_VERSION ?= 8.3
FRANKENPHP_VERSION ?= 1.12.2
FP_MU_PLUGIN_VERSION ?= v0.1.1

# Pass-through to docker compose. Override the image used by the compose stack
# by exporting FP_RUNTIME_IMAGE before invoking make.
export FP_RUNTIME_IMAGE ?= $(IMAGE)

.PHONY: build up down test ci shell logs size clean

build:
	docker build \
		--build-arg PHP_VERSION=$(PHP_VERSION) \
		--build-arg FRANKENPHP_VERSION=$(FRANKENPHP_VERSION) \
		--build-arg FP_MU_PLUGIN_VERSION=$(FP_MU_PLUGIN_VERSION) \
		-t $(IMAGE) \
		.

up:
	docker compose up -d

down:
	docker compose down -v

test:
	./tests/cache-spike.sh

ci: build up
	@printf "waiting for runtime healthcheck...\n"
	@until curl -fsS http://localhost:8080/healthz >/dev/null 2>&1; do sleep 1; done
	$(MAKE) test
	$(MAKE) down

shell:
	docker compose exec runtime bash

logs:
	docker compose logs -f runtime

size:
	@docker save $(IMAGE) | gzip | wc -c | awk '{printf "compressed: %.1f MB\n", $$1/1024/1024}'
	@docker images $(IMAGE) --format 'uncompressed: {{.Size}}'

clean: down
	docker rmi $(IMAGE) 2>/dev/null || true
