.PHONY: test runtime package

test:
	./tests/run.sh

runtime:
	./tools/build-runtime.sh

package: runtime
	./tools/package.sh
