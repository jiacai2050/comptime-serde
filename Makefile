ARGS ?= ${ZIG_ARGS}

fix:
	zig fmt  .

lint:
	zig fmt --check .

test:
	zig build test $(ARGS)

docs:
	zig build docs

clean:
	rm -rf zig-cache zig-out

.PHONY: fix lint test docs clean
