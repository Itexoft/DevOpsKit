For scripts in osx-run/tests use Bash with set -Eeuo pipefail
No comments allowed in any code
osx-run/tests/run-tests.sh creates isolated HOME and OSX_ROOT for each test and removes them
Run shellcheck on osx-run/osx-run.sh osx-run/tests/*.sh squid-cache/squid-cache.sh
GitHub Action runs shellcheck and tests on push and pull requests
