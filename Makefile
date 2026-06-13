# ================= Project Configuration =================
PROJECT_NAME := $(notdir $(CURDIR))
PROJECT_TYPE := exe

.DEFAULT_GOAL := build

# Force cmd.exe as the shell so built-in commands (if, mkdir, start, etc.)
# work correctly without spawning stray windows.
SHELL       := cmd.exe
.SHELLFLAGS := /c

# ================= Compiler Flags =========================

# Common flags for ALL builds
ODIN_FLAGS :=

# Debug flags
# -o:minimal is better than -o:none: same compile time but enables #force_inline.
DEBUG_FLAGS := -debug -o:minimal

# Release flags
# -microarch:native tunes codegen to your local CPU (remove for distributed builds).
# For shipping add: -disable-assert -no-bounds-check
RELEASE_FLAGS := -o:speed -microarch:native

# Vet flags applied to EVERY build — community standard.
# Remove/override only if you have a specific reason.
VET_FLAGS := -vet -strict-style

# Test-specific flags
TEST_FLAGS :=

# Extra flags appended last (highest priority).
# Example: make build EXTRA_FLAGS="-target:windows_amd64"
EXTRA_FLAGS :=

# ================= Directory Layout =======================
BUILD_DIR  := bin
SRC_DIR    := src
TEST_DIR   := tests
LIBS_DIR   := libs
RADDBG_DIR := .raddbg
DEPS_FILE  := deps.txt

# ================= Derived Names ==========================
ifeq ($(PROJECT_TYPE),lib)
    EXE       :=
    DEBUG_EXE :=
else
    EXE       := $(PROJECT_NAME).exe
    DEBUG_EXE := $(PROJECT_NAME)_debug.exe
endif
TEST_EXE := $(PROJECT_NAME)_tests.exe
PROJECT  := $(RADDBG_DIR)/project

COLLECTIONS := -collection:src=$(SRC_DIR) -collection:libs=./$(LIBS_DIR)

# Composed flag sets
ALL_DEBUG_FLAGS   := $(ODIN_FLAGS) $(DEBUG_FLAGS)   $(VET_FLAGS) $(EXTRA_FLAGS)
ALL_RELEASE_FLAGS := $(ODIN_FLAGS) $(RELEASE_FLAGS) $(VET_FLAGS) $(EXTRA_FLAGS)
ALL_TEST_FLAGS    := $(ODIN_FLAGS) $(DEBUG_FLAGS)   $(VET_FLAGS) $(TEST_FLAGS) $(EXTRA_FLAGS)


# ================= Build Targets ==========================

.PHONY: build
build:
ifeq ($(PROJECT_TYPE),lib)
	@odin check $(SRC_DIR) $(COLLECTIONS) $(ALL_DEBUG_FLAGS)
	@echo Library '$(PROJECT_NAME)' checked successfully (debug)
else
	@if not exist $(BUILD_DIR) mkdir $(BUILD_DIR)
	@odin build $(SRC_DIR) $(COLLECTIONS) $(ALL_DEBUG_FLAGS) -show-timings -out:$(BUILD_DIR)/$(DEBUG_EXE)
endif

.PHONY: package
package:
ifeq ($(PROJECT_TYPE),lib)
	@odin check $(SRC_DIR) $(COLLECTIONS) $(ALL_RELEASE_FLAGS)
	@echo Library '$(PROJECT_NAME)' checked successfully (release)
else
	@if not exist $(BUILD_DIR) mkdir $(BUILD_DIR)
	@odin build $(SRC_DIR) $(COLLECTIONS) $(ALL_RELEASE_FLAGS) -show-timings -out:$(BUILD_DIR)/$(EXE)
endif

.PHONY: build-test
build-test:
	@if not exist $(BUILD_DIR) mkdir $(BUILD_DIR)
	@odin build $(TEST_DIR) $(COLLECTIONS) -build-mode:test -all-packages $(ALL_TEST_FLAGS) -out:$(BUILD_DIR)/$(TEST_EXE)

.PHONY: check
check:
	@odin check $(SRC_DIR) $(COLLECTIONS) $(ODIN_FLAGS) $(VET_FLAGS) $(EXTRA_FLAGS)

.PHONY: check-strict
check-strict:
	@odin check $(SRC_DIR) $(COLLECTIONS) $(ODIN_FLAGS) \
		-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do $(EXTRA_FLAGS)


# ================= Format Targets =========================
# odinfmt must be on PATH (built from the OLS repo).
# Config is read from odinfmt.json at the project root.

.PHONY: fmt
fmt:
	@for /r $(SRC_DIR) %%f in (*.odin) do @odinfmt "%%f" & @echo   fmt %%~nxf

.PHONY: fmt-tests
fmt-tests:
	@for /r $(TEST_DIR) %%f in (*.odin) do @odinfmt "%%f" & @echo   fmt %%~nxf


# ================= Run Targets ============================

ifeq ($(PROJECT_TYPE),exe)

.PHONY: run
run:
	@if not exist $(BUILD_DIR) mkdir $(BUILD_DIR)
	@odin run $(SRC_DIR) $(COLLECTIONS) $(ALL_DEBUG_FLAGS) -out:$(BUILD_DIR)/$(DEBUG_EXE)

.PHONY: run-release
run-release:
	@if not exist $(BUILD_DIR) mkdir $(BUILD_DIR)
	@odin run $(SRC_DIR) $(COLLECTIONS) $(ALL_RELEASE_FLAGS) -out:$(BUILD_DIR)/$(EXE)

endif # exe


# ================= RAD Debugger Targets ===================
#
# Workflow:
#   1. `make debug` — builds and opens raddbg with your program running.
#   2. Use `make debug-step` if you want raddbg to pause at the entry point.
#
# Note: `start "" <exe>` is required on Windows CMD — the empty string is
# the window title argument. Without it CMD treats the first word as the title.

ifeq ($(PROJECT_TYPE),exe)

.PHONY: debug
debug: build
	@if not exist $(RADDBG_DIR) mkdir $(RADDBG_DIR)
	@start "" raddbg --auto_run --project:$(PROJECT) $(BUILD_DIR)/$(DEBUG_EXE)

.PHONY: debug-step
debug-step: build
	@if not exist $(RADDBG_DIR) mkdir $(RADDBG_DIR)
	@start "" raddbg --auto_step --project:$(PROJECT) $(BUILD_DIR)/$(DEBUG_EXE)

.PHONY: debug-open
debug-open: build
	@if not exist $(RADDBG_DIR) mkdir $(RADDBG_DIR)
	@start "" raddbg --project:$(PROJECT) $(BUILD_DIR)/$(DEBUG_EXE)

endif # exe

# ================= Test Targets ===========================

.PHONY: test
test:
	@odin test $(TEST_DIR) $(COLLECTIONS) -all-packages $(ALL_TEST_FLAGS)

.PHONY: test-strict
test-strict:
	@odin test $(TEST_DIR) $(COLLECTIONS) -all-packages \
		$(ODIN_FLAGS) $(DEBUG_FLAGS) $(TEST_FLAGS) \
		-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do $(EXTRA_FLAGS)

.PHONY: test-debug
test-debug: build-test
	@if not exist $(RADDBG_DIR) mkdir $(RADDBG_DIR)
	@start "" raddbg --auto_run --project:$(PROJECT) $(BUILD_DIR)/$(TEST_EXE)

.PHONY: test-debug-step
test-debug-step: build-test
	@if not exist $(RADDBG_DIR) mkdir $(RADDBG_DIR)
	@start "" raddbg --auto_step --project:$(PROJECT) $(BUILD_DIR)/$(TEST_EXE)


# ================= Dependency Management ==================
#
# Dependencies are vendored via git subtree into libs/ and committed to repo.
#
# Usage:
#   make get NAME=sokol URL=https://github.com/floooh/sokol-odin BRANCH=main
#   make update NAME=sokol
#   make remove NAME=sokol

.PHONY: get
get:
ifndef NAME
	$(error Usage: make get NAME=<n> URL=<git-url> BRANCH=<branch>)
endif
ifndef URL
	$(error Usage: make get NAME=<n> URL=<git-url> BRANCH=<branch>)
endif
ifndef BRANCH
	$(error Usage: make get NAME=<n> URL=<git-url> BRANCH=<branch>)
endif
	@if not exist $(LIBS_DIR) mkdir $(LIBS_DIR)
	@git subtree add --prefix=$(LIBS_DIR)/$(NAME) --squash $(URL) $(BRANCH)
	@powershell -Command "\
		if (-not (Test-Path '$(DEPS_FILE)') -or \
		    -not (Select-String -Path '$(DEPS_FILE)' -Pattern '^$(NAME) ' -Quiet)) \
		{ '$(NAME) $(URL) $(BRANCH)' | Add-Content '$(DEPS_FILE)' }"
	@echo Added dependency: $(NAME)

.PHONY: update
update:
ifndef NAME
	$(error Usage: make update NAME=<n>)
endif
	@powershell -Command "\
		$$line = Get-Content $(DEPS_FILE) | Where-Object { $$_ -match '^$(NAME) ' }; \
		if ($$line) { \
			$$parts = $$line -split ' '; \
			git subtree pull --prefix=$(LIBS_DIR)/$(NAME) --squash $$parts[1] $$parts[2] \
		} else { Write-Error 'Dependency $(NAME) not found in $(DEPS_FILE)' }"

.PHONY: update-all
update-all:
	@if exist $(DEPS_FILE) powershell -Command "\
		Get-Content $(DEPS_FILE) | ForEach-Object { \
			if ($$_.Trim() -and -not $$_.StartsWith('#')) { \
				$$p = $$_ -split ' '; \
				Write-Host \"Updating $$p[0]\"; \
				git subtree pull --prefix=$(LIBS_DIR)/$$p[0] --squash $$p[1] $$p[2] \
			}}"

.PHONY: deps
deps:
	@if exist $(DEPS_FILE) (type $(DEPS_FILE)) else (echo No dependencies configured)

.PHONY: remove
remove:
ifndef NAME
	$(error Usage: make remove NAME=<n>)
endif
	@if exist $(LIBS_DIR)/$(NAME) rmdir /s /q $(LIBS_DIR)/$(NAME)
	@powershell -Command "\
		(Get-Content $(DEPS_FILE)) \
		| Where-Object { $$_ -notmatch '^$(NAME) ' } \
		| Set-Content $(DEPS_FILE)"
	@echo Removed: $(NAME)


# ================= Misc Targets ===========================

.PHONY: clean
clean:
	@if exist $(BUILD_DIR) rmdir /s /q $(BUILD_DIR)

.PHONY: clean-all
clean-all: clean
	@if exist $(RADDBG_DIR) rmdir /s /q $(RADDBG_DIR)

.PHONY: info
info:
	@echo Project:  $(PROJECT_NAME) [$(PROJECT_TYPE)]
	@echo Src:      $(SRC_DIR)
	@echo Build:    $(BUILD_DIR)
	@echo Debug:    $(DEBUG_FLAGS)
	@echo Release:  $(RELEASE_FLAGS)
	@echo Vet:      $(VET_FLAGS)

.PHONY: help
help:
	@echo.
	@echo $(PROJECT_NAME) Makefile  [PROJECT_TYPE=$(PROJECT_TYPE)]
	@echo.
	@echo Build
	@echo   make build              Debug build  [DEFAULT]
	@echo   make package            Release build (optimized)
	@echo   make check              Type-check only
	@echo   make check-strict       Type-check with full vet + warnings-as-errors
	@echo.
	@echo Run
	@echo   make run                Build debug and run
	@echo   make run-release        Build release and run
	@echo.
	@echo Debug  (RAD Debugger)
	@echo   make debug              Open raddbg + auto-run
	@echo   make debug-step         Open raddbg + pause at entry
	@echo   make debug-open         Open raddbg, don't run yet
	@echo.
	@echo Test
	@echo   make test               Run all tests
	@echo   make test-strict        Run tests with full vet
	@echo   make test-debug         Debug tests with raddbg
	@echo.
	@echo Format
	@echo   make fmt                Format src/ with odinfmt
	@echo   make fmt-tests          Format tests/ with odinfmt
	@echo.
	@echo Dependencies
	@echo   make get NAME=x URL=y BRANCH=z    Add via git subtree
	@echo   make update NAME=x                Update one dependency
	@echo   make update-all                   Update all dependencies
	@echo   make deps                         List all dependencies
	@echo   make remove NAME=x                Remove a dependency
	@echo.
	@echo Misc
	@echo   make clean              Remove bin/
	@echo   make clean-all          Remove bin/ and .raddbg/
	@echo   make info               Show current configuration
	@echo.
	@echo Flag overrides  (append to any target):
	@echo   VET_FLAGS="-vet -strict-style -warnings-as-errors"
	@echo   RELEASE_FLAGS="-o:speed -no-bounds-check -disable-assert"  (with make package)
	@echo   TEST_FLAGS="-define:ODIN_TEST_FANCY=false"
	@echo   EXTRA_FLAGS="-target:linux_amd64"
