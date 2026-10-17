# H1 plugin for the Host self-test (H1_DRY=1): a stub block that writes synthetic run dirs; no VM, no SSH.
HOOK_FILE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../test" && pwd)/stub-block.sh
BLOCK_CMD=(bash $HOOK_FILE)
BLOCK_ENV=(STUB_WORKLOAD=$W STUB_FAIL=${STUB_FAIL:-})
PIN_SHA256=
