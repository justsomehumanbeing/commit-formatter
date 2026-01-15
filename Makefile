.PHONY: install-makefile-snippet

install-makefile-snippet: makefile.snippet
	@cat "makefile.snippet" >> ../Makefile
