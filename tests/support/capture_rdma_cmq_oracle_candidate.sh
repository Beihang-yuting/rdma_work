#!/usr/bin/env bash
# 目录：tests/support；职责：在维护者指定的临时目录捕获可审查 CMQ
# oracle 候选物。
# 依赖与所有权：调用只读 archive verifier 与 Python capture_candidate；
# 临时解压目录由本脚本清理。
set -euo pipefail

usage() {
	# 功能：输出捕获 helper 的参数契约。
	# 输入输出及副作用：向 stderr 打印帮助文本；失败边界：无输入时由
	# 调用者决定是否退出。
	cat >&2 <<'EOF'
usage: capture_rdma_cmq_oracle_candidate.sh --archive FILE --archive-lock FILE
  --source-manifest FILE --source-anchors FILE --cases FILE --oracle-source FILE
  --output-dir DIR --cc FILE
EOF
}

declare -A seen=()
archive=
archive_lock=
source_manifest=
source_anchors=
cases=
oracle_source=
output_dir=
cc=
while (($#)); do
	key=$1
	case "$key" in
		--archive)
			archive=${2-}
			;;
		--archive-lock)
			archive_lock=${2-}
			;;
		--source-manifest)
			source_manifest=${2-}
			;;
		--source-anchors)
			source_anchors=${2-}
			;;
		--cases)
			cases=${2-}
			;;
		--oracle-source)
			oracle_source=${2-}
			;;
		--output-dir)
			output_dir=${2-}
			;;
		--cc)
			cc=${2-}
			;;
		*)
			usage
			exit 2
			;;
	esac
	if [[ -z ${2-} || "$key" != --* ]]; then
		usage
		exit 2
	fi
	if [[ -n ${seen[$key]+x} ]]; then
		echo "duplicate option: $key" >&2
		exit 2
	fi
	seen[$key]=1
	shift 2
done
for required in \
	archive archive_lock source_manifest source_anchors cases \
	oracle_source output_dir cc; do
	if [[ -z ${!required} ]]; then
		echo "missing option: --$required" >&2
		usage
		exit 2
	fi
done

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
stage=$(mktemp -d /tmp/rdma_cmq_capture.XXXXXX)
cleanup() {
	# 功能：删除本次捕获的私有 archive staging。
	# 输入输出及副作用：递归移除明确的 /tmp staging；失败边界：路径不匹配时
	# 拒绝删除并返回失败。
	local status=$?
	if [[ "$stage" =~ ^/tmp/rdma_cmq_capture\.[A-Za-z0-9]{6}$ && -d "$stage" ]]; then
		rm -rf -- "$stage"
	fi
	trap - EXIT
	return "$status"
}
trap cleanup EXIT

kernel_root=$(python3 "$repo_root/tools/verify_rdma_archive.py" \
	--archive "$archive" \
	--lock "$archive_lock" \
	--source-manifest "$source_manifest" \
	--extract-dir "$stage" --print-kernel-root)
python3 - \
	"$kernel_root" \
	"$archive_lock" \
	"$source_manifest" \
	"$source_anchors" \
	"$cases" \
	"$oracle_source" \
	"$output_dir" \
	"$cc" <<'PY'
"""功能：桥接 shell 参数到 Python capture_candidate；
失败边界：任一契约异常返回非零。"""
import argparse
import sys
from pathlib import Path

from tools.verify_rdma_cmq_oracle import capture_candidate

args = argparse.Namespace(
    kernel_root=Path(sys.argv[1]),
    archive_lock=Path(sys.argv[2]),
    source_manifest=Path(sys.argv[3]),
    source_anchors=Path(sys.argv[4]),
    cases=Path(sys.argv[5]),
    oracle_source=Path(sys.argv[6]),
    output_dir=Path(sys.argv[7]),
    cc=Path(sys.argv[8]),
)
capture_candidate(args)
PY
