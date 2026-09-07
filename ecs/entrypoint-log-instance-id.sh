#!/bin/sh
# =====================================================================
# アプリコンテナ entrypoint に組み込む断片
#
#   目的: ログ出力先を「1 タスク 1 ディレクトリ」にするための
#         LOG_INSTANCE_ID を解決して export する。
#
#   これにより Logback は
#       ${LOG_OUT_DIR}/${LOG_INSTANCE_ID}/tracelog
#       ${LOG_OUT_DIR}/mid/${LOG_INSTANCE_ID}/server.log
#   へ出力し、EFS のサービス共有ディレクトリで複数タスクが同名ファイルを
#   開くこと（分析書 RC-3）が構造的に起きなくなる。
#
#   ECS_EFS_Dockerfile_Symboliclink の initialize-efs.sh が既に算出している
#   TASK_INSTANCE_ID と **同じ値** を使うこと。アプリログと JBoss サーバログを
#   同一タスク単位で突き合わせられるようにするため。
# =====================================================================

set -eu

# --- タイムゾーン（保険）---------------------------------------------
# タスク定義の environment で TZ=Asia/Tokyo を設定済みなら不要だが、
# 設定漏れで無言のまま UTC で回り続けるのを防ぐため既定値を入れておく。
: "${TZ:=Asia/Tokyo}"
export TZ

# --- タスク固有 ID の解決 ---------------------------------------------
# ECS Task Metadata Endpoint V4 から TaskARN 末尾を取得する。
# 取得できない場合（ローカル実行・メタデータ障害）は UUID にフォールバックし、
# 警告を出す。フォールバックでもタスク間の衝突は起きない。
resolve_task_instance_id() {
    _id=""

    if [ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ]; then
        _json=$(curl -fsS --max-time 3 "${ECS_CONTAINER_METADATA_URI_V4}/task" 2>/dev/null || true)
        if [ -n "$_json" ]; then
            # "TaskARN":"arn:aws:ecs:ap-northeast-1:123456789012:task/cluster/abcdef0123456789"
            _id=$(printf '%s' "$_json" \
                  | sed -n 's/.*"TaskARN"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
                  | sed 's#.*/##')
        fi
    fi

    if [ -n "$_id" ]; then
        printf 'task-%s' "$_id"
        return 0
    fi

    # フォールバック
    if [ -r /proc/sys/kernel/random/uuid ]; then
        _uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        _uuid=$(hostname)-$$
    fi
    echo "WARN: Task Metadata V4 からタスクIDを取得できませんでした。" \
         "fallback-${_uuid} を使用します。" >&2
    printf 'fallback-%s' "$_uuid"
}

: "${LOG_INSTANCE_ID:=$(resolve_task_instance_id)}"
export LOG_INSTANCE_ID

# --- 出力先ディレクトリの作成 -----------------------------------------
# Logback / JBoss はディレクトリを自動作成するが、EFS 上のパーミッションを
# 確定させるため明示的に作る。readonlyRootFilesystem: true でも
# マウント済みボリューム配下なので書き込める。
: "${LOG_OUT_DIR:=/mnt/logs}"
mkdir -p "${LOG_OUT_DIR}/${LOG_INSTANCE_ID}"
mkdir -p "${LOG_OUT_DIR}/mid/${LOG_INSTANCE_ID}"

# --- JBoss EAP のサーバログ出力先 -------------------------------------
# jboss.server.log.dir をタスク固有ディレクトリに向ける。
# jboss/cli/10-logging-rotation-jst.cli の FILE ハンドラは
# relative-to="jboss.server.log.dir" を使うため、これだけで
# server.log がタスク固有ディレクトリへ出る。
JBOSS_LOG_DIR="${LOG_OUT_DIR}/mid/${LOG_INSTANCE_ID}"
export JBOSS_LOG_DIR

echo "INFO: TZ=${TZ}"
echo "INFO: LOG_INSTANCE_ID=${LOG_INSTANCE_ID}"
echo "INFO: アプリログ出力先 = ${LOG_OUT_DIR}/${LOG_INSTANCE_ID}/"
echo "INFO: JBossログ出力先  = ${JBOSS_LOG_DIR}/"

# --- 起動 --------------------------------------------------------------
# 例:
# exec "$JBOSS_HOME/bin/standalone.sh" \
#     -Djboss.server.log.dir="${JBOSS_LOG_DIR}" \
#     -Duser.timezone=Asia/Tokyo \
#     -b 0.0.0.0
#
# ※ -Duser.timezone は standalone.conf 側（jboss/conf/01-timezone.conf）でも
#   設定しているが、起動引数でも明示しておくと ps で確認しやすい。
