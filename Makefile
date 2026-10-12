.PHONY: up verify down validate

up:       ## start reShapr + publish the demo API
	./scripts/up.sh

verify:   ## create the sandbox with the kit and run the checks
	./scripts/verify.sh

down:     ## remove everything
	./scripts/down.sh

validate: ## static check of the kit
	sbx kit validate ./kit
