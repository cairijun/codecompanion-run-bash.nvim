NVIM := nvim

# ============================================================
# Dependency Definitions
# ============================================================

# Dependency list
DEPS := mini.nvim plenary.nvim nvim-treesitter codecompanion.nvim

# URL mapping
DEP_URL_mini.nvim := https://github.com/nvim-mini/mini.nvim
DEP_URL_plenary.nvim := https://github.com/nvim-lua/plenary.nvim
DEP_URL_nvim-treesitter := https://github.com/nvim-treesitter/nvim-treesitter
DEP_URL_codecompanion.nvim := https://github.com/olimorris/codecompanion.nvim

# Pinned commit mapping (can be overridden by environment variables)
DEP_COMMIT_mini.nvim ?= a995fe9cd4193fb492b5df69175a351a74b3d36b
DEP_COMMIT_plenary.nvim ?= 50012918b2fc8357b87cff2a7f7f0446e47da174
DEP_COMMIT_nvim-treesitter ?= 4916d6592ede8c07973490d9322f187e07dfefac
DEP_COMMIT_codecompanion.nvim ?= 333c387ca762d7414e53fba5ba19c1cb085459f8

# ============================================================
# Dependency Mode
# ============================================================
DEPS_MODE ?= pinned

# Compute combined hash of all commits for marker filename
# When any commit changes, marker filename changes, triggering rebuild
COMMIT_HASH := $(shell echo "$(foreach dep,$(DEPS),$(DEP_COMMIT_$(dep)))" | md5sum | cut -c1-16)
COMMIT_MARKER := deps/.commit-$(DEPS_MODE)-$(COMMIT_HASH)

.ONESHELL:
.PHONY: all test test_file deps deps-pinned deps-nightly clean-deps clean

all: test

# Run all tests
test: $(COMMIT_MARKER)
	@echo "Running tests..."
	$(NVIM) --headless --noplugin -u ./tests/minimal_init.lua -c "lua MiniTest.run()" -c "qa!"

# Run a specific test file
test_file: $(COMMIT_MARKER)
ifndef FILE
	$(error FILE is required. Usage: make test_file FILE=tests/units/test_checker.lua)
endif
	@echo "Testing file: $(FILE)"
	$(NVIM) --headless --noplugin -u ./tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')" -c "qa!"

# ============================================================
# Dependency Installation
# ============================================================

# Generic install template, called via $(call install_dep,<dep>)
define install_dep
	if [ ! -d "deps/$(1)" ]; then \
		git clone --filter=blob:none $(DEP_URL_$(1)) deps/$(1); \
	fi; \
	(cd deps/$(1) && git fetch origin); \
	if [ "$(DEPS_MODE)" = "nightly" ]; then \
		(cd deps/$(1) && git checkout origin/HEAD); \
	else \
		(cd deps/$(1) && git checkout $(DEP_COMMIT_$(1))); \
	fi;
endef

deps: $(COMMIT_MARKER)

deps-pinned:
	$(MAKE) deps DEPS_MODE=pinned

deps-nightly:
	$(MAKE) deps DEPS_MODE=nightly

# Nightly mode uses .PHONY to always re-check for updates
# Pinned mode triggers rebuild via COMMIT_HASH change, no .PHONY needed
ifneq ($(DEPS_MODE),pinned)
.PHONY: $(COMMIT_MARKER)
endif

$(COMMIT_MARKER):
	@echo "Installing dependencies in $(DEPS_MODE) mode..."
	@rm -f deps/.commit-*
	@mkdir -p deps
	@set -e; $(foreach dep,$(DEPS),$(call install_dep,$(dep)))
	@touch $@
	@echo "✓ Dependencies installed ($(DEPS_MODE) mode):"
	@for dep in $(DEPS); do \
		commit=$$(cd deps/$$dep && git rev-parse --short HEAD); \
		echo "  $$dep: $$commit"; \
	done

format:
	stylua tests/ lua/

clean-deps:
	rm -rf deps/

clean: clean-deps
