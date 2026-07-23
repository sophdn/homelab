.PHONY: validate

# Prove every stack in this repo parses: compose config + shellcheck + yamllint.
# Requires docker, shellcheck, and yamllint on PATH (CI installs them).
validate:
	@./ci/validate.sh
