TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bats_require_minimum_version 1.5.0
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
ORIGINAL_PATH=$PATH
SYSTEM_JQ=$(command -v jq)

# On macOS we must use GNU getopt
if [[ -x /opt/homebrew/opt/util-linux/bin/getopt ]]; then
    SYSTEM_GETOPT=/opt/homebrew/opt/util-linux/bin/getopt
elif [[ -x /opt/local/bin/getopt ]]; then
    SYSTEM_GETOPT=/opt/local/bin/getopt
elif [[ -x /usr/local/bin/getopt ]]; then
    SYSTEM_GETOPT=/usr/local/bin/getopt
else
    SYSTEM_GETOPT=${GETOPT:-$(command -v getopt)}
fi
if [[ -x /opt/local/bin/grealpath ]]; then
    SYSTEM_REALPATH=/opt/local/bin/grealpath
else
    SYSTEM_REALPATH=${REALPATH:-$(command -v grealpath || command -v realpath)}
fi
if [[ -x /opt/local/bin/bash ]]; then
    SYSTEM_BASH=/opt/local/bin/bash
else
    SYSTEM_BASH=${SYSTEM_BASH:-$(command -v bash)}
fi
export TESTS_DIR REPO_ROOT ORIGINAL_PATH SYSTEM_JQ SYSTEM_GETOPT SYSTEM_REALPATH SYSTEM_BASH

# shellcheck source=helpers/assertions.bash
source "$TESTS_DIR/helpers/assertions.bash"
# shellcheck source=helpers/environment.bash
source "$TESTS_DIR/helpers/environment.bash"

function setup {
    setup_test_environment
}

function teardown {
    cleanup_test_environment
}
