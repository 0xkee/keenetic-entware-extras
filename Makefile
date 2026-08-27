# Makefile for keenetic-entware-extras
# CLI entry point for development workflow
#
# Usage:
#   make status              — project overview
#   make lint                — shellcheck all scripts
#   make lint PKG=geo-split  — shellcheck one package
#   make build PKG=geo-split — build .ipk package
#   make build-all           — build all packages
#   make check PKG=geo-split — pre-release validation
#   make release PKG=geo-split — full release cycle
#   make help                — show all targets

.PHONY: help status lint test build build-all check release backlog deploy

# Default
help:
	@echo "keenetic-entware-extras — development workflow"
	@echo ""
	@echo "Targets:"
	@echo "  status              Project overview (git, versions, backlog)"
	@echo "  lint [PKG=X]        ShellCheck (all or specific package)"
	@echo "  test                Development-time unit tests"
	@echo "  build PKG=X         Build .ipk package"
	@echo "  build-all           Build all packages"
	@echo "  check PKG=X         Pre-release validation"
	@echo "  release PKG=X       Full release: lint → check → build → tag → push"
	@echo "  deploy [HOST=X]     Deploy .ipk to routers (interactive / HOST=name / --all)"
	@echo "  backlog             Show project backlog"
	@echo "  help                This message"
	@echo ""
	@echo "Packages: keenetic-entware-extras geo-split geo-split-data"
	@echo "          smartdns-geo-conf smartdns-redirect webui net-check"

# All packages in build/release order
PACKAGES := keenetic-entware-extras geo-split geo-split-data smartdns-geo-conf smartdns-redirect webui net-check

# Package → source directory mapping
dir_keenetic-entware-extras := lib
dir_geo-split := geo-split
dir_geo-split-data := geo-split-data
dir_smartdns-geo-conf := smartdns-geo-conf
dir_smartdns-redirect := smartdns-redirect
dir_webui := webui
dir_net-check := net-check

# ---------------------------------------------------------------------------
# Project status overview
# ---------------------------------------------------------------------------
status:
	@echo "📊 Project Status — $$(date +%Y-%m-%d)"
	@echo ""
	@echo "📂 Git: $$(git branch --show-current) | $$(git status --short | wc -l | tr -d ' ') uncommitted files"
	@echo "📝 Last commits:"
	@git log --oneline -3 | sed 's/^/  • /'
	@echo ""
	@echo "📦 Package versions:"
	@for pkg in $(PACKAGES); do \
		ver=$$(grep '^Version:' packaging/$$pkg/control 2>/dev/null | cut -d' ' -f2); \
		if [ -z "$$ver" ]; then continue; fi; \
		src_dir=""; \
		case "$$pkg" in \
			keenetic-entware-extras) src_dir="lib" ;; \
			*) src_dir="$$pkg" ;; \
		esac; \
		changed=$$(git diff --name-only -- "$$src_dir/" 2>/dev/null | wc -l | tr -d ' '); \
		if [ "$$changed" -gt 0 ]; then \
			echo "  $$pkg  v$$ver  ⚡ $$changed files changed"; \
		else \
			echo "  $$pkg  v$$ver  ✓ clean"; \
		fi; \
	done
	@echo ""
	@if [ -f .project/backlog.md ]; then \
		in_progress=$$(grep -c '^\- \[ \]' .project/backlog.md 2>/dev/null || echo 0); \
		echo "📋 Backlog: $$in_progress pending items"; \
	fi

# ---------------------------------------------------------------------------
# Lint (shellcheck)
# ---------------------------------------------------------------------------
lint:
ifdef PKG
	@echo "🔍 Linting $(PKG)..."
	@pkg_dir=""; \
	case "$(PKG)" in \
		keenetic-entware-extras) pkg_dir="lib" ;; \
		*) pkg_dir="$(PKG)" ;; \
	esac; \
	find "$$pkg_dir/" lib/ -name '*.sh' -not -path './.git/*' 2>/dev/null | sort -u | xargs shellcheck -x -s sh
	@./scripts/test-geo-zones.sh
else
	@echo "🔍 Linting all scripts..."
	@find . -name '*.sh' -not -path './.git/*' -not -path './backups/*' -exec shellcheck -x -s sh {} +
	@./scripts/test-geo-zones.sh
endif

# ---------------------------------------------------------------------------
# Unit tests
# ---------------------------------------------------------------------------
test:
	@echo "🧪 Running development-time unit tests..."
	@./tests/run-all.sh

# ---------------------------------------------------------------------------
# Build .ipk
# ---------------------------------------------------------------------------
build:
ifndef PKG
	$(error PKG is required. Usage: make build PKG=geo-split)
endif
	@echo "📦 Building $(PKG)..."
	@./scripts/build-ipk.sh $(PKG)

build-all:
	@echo "📦 Building all packages..."
	@./scripts/build-ipk.sh all

# ---------------------------------------------------------------------------
# Pre-release check
# ---------------------------------------------------------------------------
check:
ifndef PKG
	$(error PKG is required. Usage: make check PKG=geo-split)
endif
	@echo "🔍 Pre-release check for $(PKG)..."
	@echo ""
	@# 1. Version exists
	@ver=$$(grep '^Version:' packaging/$(PKG)/control 2>/dev/null | cut -d' ' -f2); \
	if [ -z "$$ver" ]; then \
		echo "  ❌ No version found in packaging/$(PKG)/control"; exit 1; \
	fi; \
	echo "  ✓ Version: $$ver"
	@# 2. CHANGELOG has entry for version
	@ver=$$(grep '^Version:' packaging/$(PKG)/control | cut -d' ' -f2); \
	changelog=""; \
	case "$(PKG)" in \
		keenetic-entware-extras) changelog="CHANGELOG.md" ;; \
		*) changelog="$(PKG)/CHANGELOG.md" ;; \
	esac; \
	if [ -f "$$changelog" ]; then \
		if grep -q "$$ver" "$$changelog"; then \
			echo "  ✓ CHANGELOG entry found for v$$ver"; \
		else \
			echo "  ⚠️  No CHANGELOG entry for v$$ver in $$changelog"; \
		fi; \
	else \
		echo "  ⚠️  CHANGELOG not found: $$changelog"; \
	fi
	@# 3. Tag doesn't exist yet
	@ver=$$(grep '^Version:' packaging/$(PKG)/control | cut -d' ' -f2); \
	tag_prefix=""; \
	case "$(PKG)" in \
		keenetic-entware-extras) tag_prefix="base-v" ;; \
		geo-split) tag_prefix="geo-split-v" ;; \
		geo-split-data) tag_prefix="geo-split-data-v" ;; \
		smartdns-geo-conf) tag_prefix="smartdns-geo-conf-v" ;; \
		smartdns-redirect) tag_prefix="smartdns-redirect-v" ;; \
		webui) tag_prefix="webui-v" ;; \
	esac; \
	tag="$${tag_prefix}$${ver}"; \
	if git tag -l "$$tag" | grep -q .; then \
		echo "  ⚠️  Tag $$tag already exists (already released?)"; \
	else \
		echo "  ✓ Tag $$tag not yet created"; \
	fi
	@# 4. shellcheck passes
	@echo ""
	$(MAKE) lint PKG=$(PKG)
	@# 5. Build succeeds
	@echo ""
	$(MAKE) build PKG=$(PKG)
	@echo ""
	@echo "✅ Pre-release check passed for $(PKG)"

# ---------------------------------------------------------------------------
# Full release
# ---------------------------------------------------------------------------
release:
ifndef PKG
	$(error PKG is required. Usage: make release PKG=geo-split)
endif
	@echo "🚀 Release $(PKG)..."
	$(MAKE) check PKG=$(PKG)
	@echo ""
	./scripts/release.sh $(PKG)

# ---------------------------------------------------------------------------
# Deploy to routers
# Optional: HOST=name PKG=name FORCE=1
# ---------------------------------------------------------------------------
DEPLOY_ARGS :=
ifdef HOST
  DEPLOY_ARGS += --host "$(HOST)"
endif
ifdef PKG
  DEPLOY_ARGS += --pkg "$(PKG)"
endif
ifdef FORCE
  DEPLOY_ARGS += --force
endif

deploy:
	@./scripts/deploy.sh $(DEPLOY_ARGS)

deploy-all:
	@./scripts/deploy.sh --all $(if $(PKG),--pkg "$(PKG)")

deploy-dry:
	@./scripts/deploy.sh --dry-run $(if $(HOST),--host "$(HOST)",--all) $(if $(PKG),--pkg "$(PKG)")

# ---------------------------------------------------------------------------
# Show backlog
# ---------------------------------------------------------------------------
backlog:
	@if [ -f .project/backlog.md ]; then \
		cat .project/backlog.md; \
	else \
		echo "No backlog found. Run: /backlog sync"; \
	fi
