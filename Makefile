.PHONY: install-makefile-snippet

MAKEFILE_SNIPPET_TEMPLATE = makefile.snipped
MAKEFILE_SNIPPET_OUTPUT = makefile.snippet

install-makefile-snippet: makefile.snippet
	@super_root="$$(git rev-parse --show-superproject-working-tree 2>/dev/null)"; \
	if [[ -z "$${super_root}" ]]; then \
		echo "commit-fmt: unable to determine superproject root from submodule" >&2; \
		exit 1; \
	fi; \
	cat "$(MAKEFILE_SNIPPET_OUTPUT)" >> "$${super_root}/Makefile"

makefile.snippet: $(MAKEFILE_SNIPPET_TEMPLATE)
	@super_root="$$(git rev-parse --show-superproject-working-tree 2>/dev/null)"; \
	if [[ -z "$${super_root}" ]]; then \
		echo "commit-fmt: unable to determine superproject root from submodule" >&2; \
		exit 1; \
	fi; \
	submodule_root="$$(git rev-parse --show-toplevel 2>/dev/null)"; \
	if [[ -z "$${submodule_root}" ]]; then \
		echo "commit-fmt: unable to determine submodule root" >&2; \
		exit 1; \
	fi; \
	submodule_path="$$(realpath --relative-to="$${super_root}" "$${submodule_root}")"; \
	submodule_path="$${submodule_path%/}"; \
	if [[ -z "$${submodule_path}" || "$${submodule_path}" == "." ]]; then \
		echo "commit-fmt: unable to determine relative submodule path" >&2; \
		exit 1; \
	fi; \
	submodule_dir="$${submodule_path##*/}"; \
	sed -e "s#__COMMIT_FMT_SUBMODULE_PATH__#$${submodule_path}#g" \
		-e "s#__COMMIT_FMT_SUBMODULE_DIR__#$${submodule_dir}#g" \
		"$(MAKEFILE_SNIPPET_TEMPLATE)" > "$(MAKEFILE_SNIPPET_OUTPUT)"
