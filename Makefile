ARGS ?= ${ZIG_ARGS}

fix:
	zig fmt  .

lint:
	zig fmt --check .

test:
	zig build test --test-timeout 5s --summary all $(ARGS)

docs:
	zig build docs

serve:
	cd docs && mdbook serve

clean:
	rm -rf zig-cache zig-out

.PHONY: fix lint test docs serve clean
