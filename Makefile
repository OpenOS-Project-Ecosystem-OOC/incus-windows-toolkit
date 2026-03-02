.PHONY: help lint test test-all validate install uninstall man clean

SHELL := /bin/bash
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share/iwt
MANDIR ?= $(PREFIX)/share/man/man1
COMPLETIONDIR_BASH ?= $(PREFIX)/share/bash-completion/completions
COMPLETIONDIR_ZSH ?= $(PREFIX)/share/zsh/site-functions
VERSION := $(shell grep '^VERSION=' cli/iwt.sh | cut -d'"' -f2)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint: ## Run shellcheck on all scripts
	find . -name '*.sh' -exec shellcheck -x -S warning {} +

test: ## Run unit tests and lint
	tests/run-tests.sh

test-all: ## Run all tests including integration (requires incus)
	tests/run-tests.sh --all

validate: ## Validate profile YAML files
	profiles/validate.sh

# --- Man page generation ---

man: doc/iwt.1 ## Generate man page

doc/iwt.1: doc/iwt.1.md
	@mkdir -p doc
	@if command -v pandoc &>/dev/null; then \
		pandoc -s -t man doc/iwt.1.md -o doc/iwt.1; \
		echo "Generated doc/iwt.1"; \
	else \
		echo "pandoc not found; skipping man page generation"; \
	fi

# --- Install ---

install: ## Install iwt to PREFIX (default: /usr/local)
	@echo "Installing IWT v$(VERSION) to $(PREFIX)"
	install -Dm755 cli/iwt.sh $(DESTDIR)$(BINDIR)/iwt
	install -Dm644 cli/lib.sh $(DESTDIR)$(DATADIR)/cli/lib.sh
	install -Dm755 cli/backup.sh $(DESTDIR)$(DATADIR)/cli/backup.sh
	install -Dm755 image-pipeline/scripts/build-image.sh $(DESTDIR)$(DATADIR)/image-pipeline/scripts/build-image.sh
	install -Dm755 image-pipeline/scripts/download-iso.sh $(DESTDIR)$(DATADIR)/image-pipeline/scripts/download-iso.sh
	install -Dm755 image-pipeline/scripts/manage-drivers.sh $(DESTDIR)$(DATADIR)/image-pipeline/scripts/manage-drivers.sh
	install -d $(DESTDIR)$(DATADIR)/image-pipeline/answer-files
	install -d $(DESTDIR)$(DATADIR)/image-pipeline/drivers
	cp -r image-pipeline/answer-files/. $(DESTDIR)$(DATADIR)/image-pipeline/answer-files/ 2>/dev/null || true
	cp -r image-pipeline/drivers/. $(DESTDIR)$(DATADIR)/image-pipeline/drivers/ 2>/dev/null || true
	install -d $(DESTDIR)$(DATADIR)/profiles/x86_64
	install -d $(DESTDIR)$(DATADIR)/profiles/arm64
	install -d $(DESTDIR)$(DATADIR)/profiles/gpu
	install -Dm644 profiles/x86_64/*.yaml $(DESTDIR)$(DATADIR)/profiles/x86_64/
	install -Dm644 profiles/arm64/*.yaml $(DESTDIR)$(DATADIR)/profiles/arm64/
	install -Dm644 profiles/gpu/*.yaml $(DESTDIR)$(DATADIR)/profiles/gpu/
	install -Dm755 profiles/validate.sh $(DESTDIR)$(DATADIR)/profiles/validate.sh
	install -d $(DESTDIR)$(DATADIR)/remoteapp/backend
	install -d $(DESTDIR)$(DATADIR)/remoteapp/freedesktop
	install -Dm755 remoteapp/backend/incus-backend.sh $(DESTDIR)$(DATADIR)/remoteapp/backend/incus-backend.sh
	install -Dm755 remoteapp/backend/launch-app.sh $(DESTDIR)$(DATADIR)/remoteapp/backend/launch-app.sh
	install -Dm644 remoteapp/freedesktop/apps.conf $(DESTDIR)$(DATADIR)/remoteapp/freedesktop/apps.conf
	install -Dm644 remoteapp/freedesktop/shares.conf $(DESTDIR)$(DATADIR)/remoteapp/freedesktop/shares.conf
	install -Dm755 remoteapp/freedesktop/generate-desktop-entries.sh $(DESTDIR)$(DATADIR)/remoteapp/freedesktop/generate-desktop-entries.sh
	install -d $(DESTDIR)$(DATADIR)/guest
	install -Dm755 guest/setup-guest.sh $(DESTDIR)$(DATADIR)/guest/setup-guest.sh
	install -Dm755 guest/setup-winfsp.sh $(DESTDIR)$(DATADIR)/guest/setup-winfsp.sh
	install -Dm755 guest/first-boot.sh $(DESTDIR)$(DATADIR)/guest/first-boot.sh
	install -d $(DESTDIR)$(DATADIR)/gpu
	install -Dm755 gpu/setup-vfio.sh $(DESTDIR)$(DATADIR)/gpu/setup-vfio.sh
	install -Dm755 gpu/setup-looking-glass.sh $(DESTDIR)$(DATADIR)/gpu/setup-looking-glass.sh
	install -d $(DESTDIR)$(DATADIR)/templates
	install -Dm644 templates/*.yaml $(DESTDIR)$(DATADIR)/templates/
	install -Dm755 templates/engine.sh $(DESTDIR)$(DATADIR)/templates/engine.sh
	install -d $(DESTDIR)$(DATADIR)/tui
	install -Dm755 tui/iwt-tui.sh $(DESTDIR)$(DATADIR)/tui/iwt-tui.sh
	@if [ -d $(DESTDIR)$(COMPLETIONDIR_BASH) ] || [ "$(DESTDIR)" != "" ]; then \
		install -d $(DESTDIR)$(COMPLETIONDIR_BASH); \
		cli/iwt.sh completion bash > $(DESTDIR)$(COMPLETIONDIR_BASH)/iwt 2>/dev/null || true; \
	fi
	@if [ -d $(DESTDIR)$(COMPLETIONDIR_ZSH) ] || [ "$(DESTDIR)" != "" ]; then \
		install -d $(DESTDIR)$(COMPLETIONDIR_ZSH); \
		cli/iwt.sh completion zsh > $(DESTDIR)$(COMPLETIONDIR_ZSH)/_iwt 2>/dev/null || true; \
	fi
	@if [ -f doc/iwt.1 ]; then \
		install -Dm644 doc/iwt.1 $(DESTDIR)$(MANDIR)/iwt.1; \
	fi
	@echo "IWT v$(VERSION) installed to $(PREFIX)"

uninstall: ## Remove iwt from PREFIX
	rm -f $(DESTDIR)$(BINDIR)/iwt
	rm -rf $(DESTDIR)$(DATADIR)
	rm -f $(DESTDIR)$(COMPLETIONDIR_BASH)/iwt
	rm -f $(DESTDIR)$(COMPLETIONDIR_ZSH)/_iwt
	rm -f $(DESTDIR)$(MANDIR)/iwt.1
	@echo "IWT uninstalled from $(PREFIX)"

# --- Convenience targets ---

image-build: ## Build a Windows image for Incus
	image-pipeline/scripts/build-image.sh

profiles-install: ## Install Incus VM profiles
	cli/iwt.sh profiles install

remoteapp-install: ## Install RemoteApp desktop integration
	cli/iwt.sh remoteapp install

clean: ## Remove build artifacts
	rm -f doc/iwt.1
