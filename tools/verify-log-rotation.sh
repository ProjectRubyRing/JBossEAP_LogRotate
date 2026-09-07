#!/usr/bin/env bash
# =====================================================================
# ログローテーション健全性チェック
#
#   ローテート済みファイルについて「ファイル名が示す期間」と
#   「中身の先頭行・末尾行のタイムスタンプ」を突き合わせ、はみ出しを検出する。
#
#   検出する事象:
#     [TZ-SKEW]   はみ出し量が一律 9 時間前後 → UTC/JST 不一致（分析書 RC-1）
#     [OVERRUN]   中身がファイル名の期間より後にはみ出す（RC-2 / RC-3）
#     [UNDERRUN]  中身がファイル名の期間より前にはみ出す（RC-2 / RC-5）
#     [BOOT-ROT]  rotate-on-boot による起動時退避（正常。異常件数に数えない）
#     [NO-TS]     タイムスタンプを抽出できない（書式不一致）
#
#   使い方:
#       ./verify-log-rotation.sh /mnt/logs/front-svc
#       ./verify-log-rotation.sh /mnt/logs/front-svc/mid/task-abc123
#       GRAN=day ./verify-log-rotation.sh /mnt/logs
#
#       # rotate-on-boot=false の旧構成を検査する（起動時退避を異常として扱う）
#       ROTATE_ON_BOOT=false ./verify-log-rotation.sh /mnt/logs/front-svc/mid
#
#   環境変数:
#       TZ_EXPECT  ファイル名の日付が属するはずの TZ（既定: Asia/Tokyo）
#                  zoneinfo が無い環境では POSIX 形式 "JST-9" も使える
#       GRAN       ローテート粒度 auto|day|hour（既定: auto）
#                  ※ "base.2026-09-01-19" の -19 は「19 時」とも
#                    「サイズ連番 19」とも読めるため、判別できない場合は
#                    GRAN で明示すること
#       ROTATE_ON_BOOT
#                  true|false（既定: true）
#                  true のとき、連番付きファイル（base.<日付>.<N>）で
#                  「前方はみ出しのみ・後方はみ出し無し」のものを
#                  [BOOT-ROT] と分類し、異常に数えない。
#                  JBoss の rotate-on-boot=true は起動時に既存ファイルを
#                  **起動日** の名前で退避するため、中身が前日以前から
#                  始まるのは正常な状態である（分析書 §3.5 副作用 1）。
#       MAX_FILES  走査するファイル数の上限（既定: 500）
#
#   前提: GNU coreutils の date(1)（Linux コンテナ / Amazon Linux で可）
#         ※ Windows の Git Bash は zoneinfo を持たないため
#           TZ_EXPECT=JST-9 を指定すること
# =====================================================================

set -uo pipefail

TARGET_DIR="${1:-.}"
TZ_EXPECT="${TZ_EXPECT:-Asia/Tokyo}"
GRAN="${GRAN:-auto}"
ROTATE_ON_BOOT="${ROTATE_ON_BOOT:-true}"
MAX_FILES="${MAX_FILES:-500}"

[ -d "$TARGET_DIR" ] || { echo "ERROR: ディレクトリが存在しません: $TARGET_DIR" >&2; exit 2; }
date --version >/dev/null 2>&1 || { echo "ERROR: GNU date が必要です（BSD date は非対応）" >&2; exit 2; }

# ---------------------------------------------------------------------
# TZ_EXPECT が実際に解決できているかを検証する。
#
# tzdata(zoneinfo) を持たない最小コンテナや Windows の Git Bash では、
# TZ=Asia/Tokyo は **エラーにならず無言で UTC にフォールバック**する。
# これを見逃すと本ツール自身が 9 時間ずれた判定を出すため、必ず検査する。
# （同じ罠は CloudWatch Agent の timezone:"Local" にも存在する）
# ---------------------------------------------------------------------
tz_offset=$(TZ="$TZ_EXPECT" date -d '2026-01-01 00:00:00' '+%z' 2>/dev/null)
if [ "$tz_offset" = "+0000" ] && ! printf '%s' "$TZ_EXPECT" | grep -qiE '^(utc|gmt|etc/utc|etc/gmt)$'; then
    cat >&2 <<MSG
ERROR: TZ_EXPECT="$TZ_EXPECT" が UTC(+0000) として解決されました。
       tzdata(zoneinfo) が無い環境の可能性があります。このまま実行すると
       本ツール自身が 9 時間ずれた判定を出します。

       対処 1: コンテナに tzdata を導入する
                 microdnf install -y tzdata   /  apk add --no-cache tzdata
       対処 2: POSIX 形式で指定する
                 TZ_EXPECT=JST-9 $0 $TARGET_DIR
MSG
    exit 2
fi

# ---------------------------------------------------------------------
# 行頭のタイムスタンプを epoch 秒へ変換する。
#   2026-09-02 00:14:03.424+0900   (Logback APP_PATTERN)
#   2026-09-02 00:14:03,424+0900   (JBoss / SERVER_PATTERN)
#   2026-09-02 00:14:03.424        (オフセット無し = 旧形式 → TZ_EXPECT と解釈)
# ---------------------------------------------------------------------
ts_to_epoch() {
    local ts
    ts=$(printf '%s' "$1" \
         | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]{1,9})?([+-][0-9]{2}:?[0-9]{2}|Z)?' \
         | head -1)
    [ -z "$ts" ] && return 1
    ts="${ts/,/.}"
    if printf '%s' "$ts" | grep -qE '([+-][0-9]{2}:?[0-9]{2}|Z)$'; then
        date -d "$ts" +%s 2>/dev/null
    else
        TZ="$TZ_EXPECT" date -d "$ts" +%s 2>/dev/null
    fi
}

# 先頭 / 末尾のタイムスタンプ付き行（空行・スタックトレース継続行は飛ばす）
first_ts() {
    local line e
    while IFS= read -r line; do
        e=$(ts_to_epoch "$line") && { printf '%s' "$e"; return 0; }
    done < <(head -n 200 "$1" 2>/dev/null)
    return 1
}
last_ts() {
    local line e
    while IFS= read -r line; do
        e=$(ts_to_epoch "$line") && { printf '%s' "$e"; return 0; }
    done < <(tail -n 200 "$1" 2>/dev/null | tac)
    return 1
}

# ---------------------------------------------------------------------
# ファイル名から期間を割り出す。
#   base.2026-09-01          → 日次
#   base.2026-09-01.3        → 日次（連番付き）
#   base.2026-09-01-19       → GRAN=hour なら 19 時、GRAN=day なら連番扱い
#   base.2026-09-01.3.log    → 拡張子付き
#
# あわせて「連番が付いているか」も返す。連番は次の 2 つで作られる:
#   - サイズ超過によるローテート（%i 相当）
#   - rotate-on-boot による起動時退避（退避先は必ず base.<日付>.1）
# 起動時退避のファイルは必ず連番付きになるため、これが [BOOT-ROT] 判定の
# 必要条件になる（分析書 §3.5 副作用 1・2）。
#
# 出力: "<start_epoch> <end_epoch> <granularity> <ambiguous:0|1> <indexed:0|1>"
# ---------------------------------------------------------------------
AMBIG_SEEN=0
period_from_name() {
    local name="$1" d h start amb=0 idx=0
    if [ "$GRAN" != "day" ] \
       && [[ "$name" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})-([0-9]{2})([.\-][0-9]+)?(\.[A-Za-z]+)?$ ]]; then
        d="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"
        [ -n "${BASH_REMATCH[3]}" ] && idx=1
        if [ "$h" -le 23 ]; then
            [ "$GRAN" = "auto" ] && amb=1
            start=$(TZ="$TZ_EXPECT" date -d "$d $h:00:00" +%s 2>/dev/null) || return 1
            printf '%s %s hour %s %s' "$start" "$(( start + 3599 ))" "$amb" "$idx"; return 0
        fi
    fi
    if [[ "$name" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})([.\-][0-9]+)?(\.[A-Za-z]+)?$ ]]; then
        d="${BASH_REMATCH[1]}"
        idx=0; [ -n "${BASH_REMATCH[2]}" ] && idx=1
        start=$(TZ="$TZ_EXPECT" date -d "$d 00:00:00" +%s 2>/dev/null) || return 1
        printf '%s %s day 0 %s' "$start" "$(( start + 86399 ))" "$idx"; return 0
    fi
    return 1
}

fmt() { TZ="$TZ_EXPECT" date -d "@$1" '+%Y-%m-%d %H:%M:%S%z' 2>/dev/null; }
hours() { awk -v s="$1" 'BEGIN{printf "%.1f", s/3600}'; }

# ---------------------------------------------------------------------
echo "======================================================================"
echo " ログローテーション健全性チェック"
echo "   対象ディレクトリ : $TARGET_DIR"
echo "   期待タイムゾーン : $TZ_EXPECT ($tz_offset)"
echo "   ローテート粒度   : $GRAN"
echo "   rotate-on-boot   : $ROTATE_ON_BOOT  (true = 起動時退避を [BOOT-ROT] とし異常に数えない)"
echo "======================================================================"
echo

ok=0; ng=0; skipped=0; boot_rot=0; over_samples=()

while IFS= read -r f; do
    name=$(basename "$f")
    [ -s "$f" ] || { skipped=$((skipped+1)); continue; }

    period_out="$(period_from_name "$name")"
    [ -n "$period_out" ] || { skipped=$((skipped+1)); continue; }
    read -r p_start p_end gran amb idx <<<"$period_out"
    [ "${amb:-0}" = "1" ] && AMBIG_SEEN=1

    f_ts=$(first_ts "$f"); l_ts=$(last_ts "$f")
    if [ -z "${f_ts:-}" ] || [ -z "${l_ts:-}" ]; then
        printf '[NO-TS]    %s\n            タイムスタンプを抽出できません（書式不一致の可能性）\n\n' "$name"
        ng=$((ng+1)); continue
    fi

    over=$(( l_ts - p_end ))
    under=$(( p_start - f_ts ))

    if [ "$over" -le 0 ] && [ "$under" -le 0 ]; then
        ok=$((ok+1)); continue
    fi

    # -----------------------------------------------------------------
    # rotate-on-boot による起動時退避か？（分析書 §3.5 副作用 1）
    #
    #   退避ファイルは「起動日」の名前を持ち、中身はそれ以前から始まる。
    #   → 連番付き かつ 前方はみ出しのみ（後方はみ出し無し）を [BOOT-ROT]。
    #
    #   後方はみ出しがある場合は RC-1 / RC-3 の可能性が残るため、この分岐には
    #   入れず通常どおり異常として報告する。旧構成（rotate-on-boot=false）を
    #   検査するときは ROTATE_ON_BOOT=false を指定すれば従来どおり
    #   [UNDERRUN] として異常に数えられる。
    # -----------------------------------------------------------------
    if [ "$ROTATE_ON_BOOT" = "true" ] && [ "${idx:-0}" = "1" ] && [ "$under" -gt 0 ] && [ "$over" -le 0 ]; then
        boot_rot=$((boot_rot+1))
        printf '[BOOT-ROT] %s  (%s単位)\n' "$name" "$gran"
        printf '            ファイル名の期間 : %s 〜 %s\n' "$(fmt "$p_start")" "$(fmt "$p_end")"
        printf '            中身の時刻範囲   : %s 〜 %s\n' "$(fmt "$f_ts")"   "$(fmt "$l_ts")"
        printf '            はみ出し(前方)   : %s 秒 (%s 時間)  ← 起動時退避（正常）\n' "$under" "$(hours "$under")"
        echo
        continue
    fi

    ng=$((ng+1))
    label=""
    [ "$over"  -gt 0 ] && label="OVERRUN"
    [ "$under" -gt 0 ] && label="${label:+$label+}UNDERRUN"

    printf '[%s] %s  (%s単位)\n' "$label" "$name" "$gran"
    printf '            ファイル名の期間 : %s 〜 %s\n' "$(fmt "$p_start")" "$(fmt "$p_end")"
    printf '            中身の時刻範囲   : %s 〜 %s\n' "$(fmt "$f_ts")"   "$(fmt "$l_ts")"
    [ "$over"  -gt 0 ] && { printf '            はみ出し(後方)   : %s 秒 (%s 時間)\n' "$over"  "$(hours "$over")";  over_samples+=("$over"); }
    [ "$under" -gt 0 ] &&   printf '            はみ出し(前方)   : %s 秒 (%s 時間)\n' "$under" "$(hours "$under")"
    echo
done < <(find "$TARGET_DIR" -type f -name '*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' 2>/dev/null \
         | sort | head -n "$MAX_FILES")

echo "----------------------------------------------------------------------"
printf ' 正常: %d 件 / 異常: %d 件 / 起動時退避: %d 件 / 対象外: %d 件\n' \
       "$ok" "$ng" "$boot_rot" "$skipped"

if [ "$boot_rot" -gt 0 ]; then
    echo
    echo " [BOOT-ROT] rotate-on-boot=true による起動時退避を $boot_rot 件検出しました（正常）。"
    echo "            退避ファイルは「起動日」の名前を持ち、中身はそれ以前から始まります。"
    echo "            件数は「日付をまたいだ再起動の回数」と一致するはずです。"
    echo "            大きく食い違う場合は RC-2/RC-3 と混同していないか個別に確認してください。"
    echo "            旧構成（rotate-on-boot=false）の検査には ROTATE_ON_BOOT=false を指定します。"
fi

if [ "$AMBIG_SEEN" = "1" ]; then
    echo
    echo " [注意] 末尾 \"-NN\" を「時」と解釈しました。これがサイズローテートの"
    echo "        連番（%i）である場合は判定がずれます。GRAN=day で再実行して"
    echo "        比較してください。"
fi

if [ "${#over_samples[@]}" -ge 2 ]; then
    near9=0
    for s in "${over_samples[@]}"; do
        [ "$s" -ge 28800 ] && [ "$s" -le 36000 ] && near9=$((near9+1))
    done
    if [ "$near9" -gt 0 ] && [ "$near9" -ge $(( ${#over_samples[@]} / 2 )) ]; then
        echo
        echo " [TZ-SKEW] はみ出し量が一律 9 時間前後です。"
        echo "           ローテーション境界が UTC、ログ行が JST（またはその逆）に"
        echo "           なっている可能性が高い（分析書 RC-1）。"
        echo "           確認: JVM の -Duser.timezone / コンテナの TZ 環境変数 /"
        echo "                 Logback fileNamePattern の %d 第2引数"
    fi
fi
echo "----------------------------------------------------------------------"

[ "$ng" -eq 0 ] || exit 1
