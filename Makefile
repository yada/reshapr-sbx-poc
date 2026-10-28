.PHONY: up verify down validate

up:       ## start reShapr + publish the demo API
	./scripts/up.sh

verify:   ## create the sandbox with the kit and run the checks
	./scripts/verify.sh

down:     ## remove everything
	./scripts/down.sh

validate: ## static check of both kits
	SBX_KIT_BUILDER=sandbox sbx kit inspect ./sbx-kits/reshapr-outside-sbx
	SBX_KIT_BUILDER=sandbox sbx kit inspect ./sbx-kits/reshapr-inside-sbx
