# 適用手順

分析結果（`docs/ANALYSIS_UTC_JST.md`）に基づく実装の適用手順。

**重要: 1〜4 は必ずセットで適用すること。** 部分適用すると、
かえって「ログ行は JST・CloudWatch は UTC 解釈」のような新しいずれが生じる。

| # | 対象 | ファイル | 効果 |
|---|------|---------|------|
| 1 | JVM / コンテナ TZ | `jboss/conf/01-timezone.conf`, `ecs/taskdef-timezone-snippet.json` | ローテート境界とファイル名を JST 化 |
| 2 | JBoss EAP server.log | `jboss/cli/10-logging-rotation-jst.cli` | 日次+サイズローテート、オフセット印字、**起動時退避（RC-5 対策）** |
| 3 | アプリログ（tracelog 等） | `logback/logback-spring.xml`, `ecs/entrypoint-log-instance-id.sh` | TZ 固定 + タスク固有ディレクトリ |
| 4 | CloudWatch Agent | `cloudwatch-agent/amazon-cloudwatch-agent.json` | `%z` 解釈、glob 修正、multiline |

---

## 1. JVM / コンテナのタイムゾーンを JST に固定

### 1-1. イメージビルド時（standalone.conf へ追記）

```dockerfile
COPY jboss/conf/01-timezone.conf /tmp/01-timezone.conf
RUN cat /tmp/01-timezone.conf >> "$JBOSS_HOME/bin/standalone.conf" \
 && rm -f /tmp/01-timezone.conf
```

`readonlyRootFilesystem: true` でもビルド時の操作なので問題ない。

> **JAVA_OPTS を ECS タスク定義の環境変数で渡してはいけない。**
> `standalone.conf` は `JAVA_OPTS` が既に設定済みだと EAP 既定の
> ヒープ・GC 設定をすべて破棄する。TZ は必ず standalone.conf 追記で渡すこと。

### 1-2. OS 側の TZ（tzdata）

```dockerfile
# date(1) など OS コマンドも JST にしたい場合のみ必要
RUN microdnf install -y tzdata && microdnf clean all
```

- **JVM は tzdata 不要**（JDK が内蔵 tzdb を持つ）。`-Duser.timezone=Asia/Tokyo` は
  tzdata の無いイメージでも正しく動く。
- **CloudWatch Agent（Go 実装）は tzdata 必要**。無い場合 `TZ=Asia/Tokyo` は
  **エラーにならず無言で UTC にフォールバック**する。
  だからこそログ行に `+0900` を印字して `%z` で解釈させる設計にしている（§4）。

### 1-3. タスク定義

`ecs/taskdef-timezone-snippet.json` を参照し、**全コンテナ**（アプリ・サイドカー）に
`TZ=Asia/Tokyo` を設定する。

---

## 2. JBoss EAP の server.log

### 2-1. 適用

```bash
$JBOSS_HOME/bin/jboss-cli.sh --file=jboss/cli/10-logging-rotation-jst.cli
```

サーバ未起動状態で `embed-server` により `standalone.xml` を直接書き換える。
冪等なので再実行してよい。

CLI が使えない場合は `jboss/standalone-logging-snippet.xml` の内容で
`standalone.xml` の logging サブシステムを置き換える。

### 2-2. 設定内容

```
handler   : periodic-size-rotating-file-handler (旧: periodic-rotating-file-handler)
suffix    : .yyyy-MM-dd          … JVM 既定 TZ (=JST) で解釈 → 1 JST 日 = 1 グループ
rotate-size=100m                 … 同一日内のサイズ超過で連番を作る閾値
max-backup-index=20              … 連番の保持世代数（0 にすると rotate-on-boot が無効化される）
append=true / autoflush=true
rotate-on-boot=true              … RC-5 対策: 起動時に既存 server.log を退避
formatter : %d{yyyy-MM-dd HH:mm:ss,SSSZ} %-5p [%c] (%t) %s%e%n
```

出力例:

```
2026-09-02 00:14:03,424+0900 INFO  [com.example.Foo] (default task-1) processed
```

**`periodic-rotating-file-handler` には `rotate-on-boot` 属性が無い。**
RC-5 を塞ぐには `periodic-size-rotating-file-handler` への型変換が必須で、
本 CLI はその変換も併せて行う。

### 2-3. 出力先はタスク固有ディレクトリを維持すること

`relative-to="jboss.server.log.dir"` を使い、起動時に

```
-Djboss.server.log.dir=/mnt/logs/<comp>/logs/<svc>/mid/<TASK_INSTANCE_ID>
```

を渡す（既存の `ECS_EFS_Dockerfile_Symboliclink` の方式どおり）。
**ここをサービス共有ディレクトリに変えると RC-3 が発生する。**

### 2-4. 時間帯別統計が必要な場合

`suffix` を `.yyyy-MM-dd-HH` に変更すると毎時ローテートになる。
その場合 `tools/verify-log-rotation.sh` は `GRAN=hour` で実行すること。

### 2-5. `rotate-on-boot=true` の意味と確認（RC-5 対策）

#### 何が変わるか

| | 変更前 (`rotate-on-boot=false`) | 変更後 (`rotate-on-boot=true`) |
|--|-------------------------------|------------------------------|
| 再起動直後の書き込み先 | 前プロセスが残した `server.log` に**追記** | **空の新しい** `server.log` |
| 前プロセス分の確定名 | mtime 由来の日付（クラッシュ前日になりうる） | `server.log.<起動日>.1` |
| 1 ファイルの中身 | 再起動を跨いで混在しうる | **1 ファイル = 1 起動** |
| 正しさの担保 | 「境界判定が毎回当たること」に依存 | **構造で保証**（書き込み前に退避） |

理屈は `docs/ANALYSIS_UTC_JST.md` §3.5 を参照。

#### 発火条件（設定しても症状が変わらないときは、まずここを見る）

```java
rotateOnBoot && maxBackupIndex > 0 && file.exists() && file.length() > 0
```

- `max-backup-index=0` だと **エラーも警告も無く無効化**される。
- **起動時に `server.log` が存在しない経路では発火しない。**
  ECS でタスクごとに `mid/<TASK_INSTANCE_ID>/` が変わる構成がこれに当たる。
  その経路ではそもそも RC-5 が起きていない（分析書 §3.5.4 の表で確認すること）。

#### 副作用（承知の上で採用している）

1. **退避ファイルの日付は「起動日」**。09-01 の内容が 09-02 の起動で退避されると
   `server.log.2026-09-02.1` になる。ファイル名ではなく**行の時刻（`+0900` 付き）を正**とする。
   `tools/verify-log-rotation.sh` はこれを `[BOOT-ROT]` として異常と区別する。
2. **1 起動につき連番を 1 つ消費**する（`.max` を削除 → `.N` を `.N+1` へシフト → `server.log` を `.1` へ）。
   `.1` が最新（逆時系列）。`max-backup-index=20` なら同一日に 20 回の再起動で当日分が一巡する。
   保険は CloudWatch Logs 側（`autoflush=true` により行は書かれた時点で送信済み）。
3. **適用直後の 1 回だけ**、logging サブシステム初期化前のブート数行が退避側の末尾に入る
   （`configuration/logging.properties` が現行モデルから再生成されるのは次回起動時のため）。

#### 動作確認

サーバを 2 回起動して、退避が起きていることを実測する。

```bash
LOGDIR=/mnt/logs/front-svc/mid/task-abc123   # jboss.server.log.dir

# 1 回目の起動 → 適当に稼働させて server.log にログを溜める
ls -la "$LOGDIR"
#   server.log

# サーバを停止（異常終了の再現なら kill -9 でよい）
# 2 回目の起動
ls -la "$LOGDIR"
#   server.log            ← 空から始まっている（先頭行が今回の起動ログ）
#   server.log.<起動日>.1  ← 前回稼働分がここへ退避されている

# 期待どおりなら、新しい server.log の先頭は必ず今回の起動ログになる
head -3 "$LOGDIR/server.log"

# 退避側の末尾は前回の停止時刻で終わっている（副作用 3 の数行を除く）
tail -3 "$LOGDIR/server.log.<起動日>.1"
```

**判定基準**

| 観測 | 判定 |
|------|------|
| 新 `server.log` の先頭が今回の起動ログ | ✅ RC-5 は解消 |
| 新 `server.log` の先頭が前回稼働中のログ | ❌ 退避が発火していない → 発火条件と `max-backup-index` を確認 |
| `server.log.<日付>.1` が増えていない | ❌ 同上 |
| 退避側の末尾に今回の起動ログが数行ある | ⚠️ 副作用 3。もう一度再起動して消えれば正常 |

CLI 適用後の属性確認:

```bash
$JBOSS_HOME/bin/jboss-cli.sh -c \
  '/subsystem=logging/periodic-size-rotating-file-handler=FILE:read-resource(include-defaults=true)'
# rotate-on-boot => true / max-backup-index => 20 / append => true の 3 点を確認
```

---

## 3. アプリログ（tracelog 等）

### 3-1. 適用

1. `logback/logback-spring.xml` を
   `dhapp_2/src/main/resources/logback-spring.xml` へ配置（差し替え）
2. `ecs/entrypoint-log-instance-id.sh` の内容をアプリコンテナの entrypoint に組み込む

### 3-2. 変更点は 3 つだけ

| 変更 | 変更前 | 変更後 |
|------|-------|-------|
| ローテート境界 | `%d{yyyy-MM-dd}` | `%d{yyyy-MM-dd, Asia/Tokyo}` |
| ログ行 | `%d{yyyy-MM-dd HH:mm:ss.SSS}` | `%d{yyyy-MM-dd HH:mm:ss.SSSZ, Asia/Tokyo}` |
| 出力先 | `${LOG_OUT_DIR}/tracelog` | `${LOG_OUT_DIR}/${LOG_INSTANCE_ID}/tracelog` |

**ファイル名（`tracelog`, `accesslog`, `keax0003.log` …）は一切変えていない。**
既存の運用手順・grep 対象名はそのまま使える。

### 3-3. `%d` の TZ 指定が効く理由

Logback の `TimeBasedRollingPolicy` は `fileNamePattern` の `%d` に指定された
TZ から `RollingCalendar` を構築してローテート境界を計算する。
つまり **JVM の TZ 設定に関係なく**、この 1 箇所で境界が JST に固定される
（§1 の JVM TZ 設定とあわせて二重の保険になる）。

### 3-4. パターン中のカンマに注意

Logback の `%d{...}` はカンマを「第 2 引数 = TZ」の区切りとして解釈する。
日付パターン自体にカンマを含む場合（`HH:mm:ss,SSS`）は
**日付パターンだけをダブルクォートで囲む**。

```
OK : %d{"yyyy-MM-dd HH:mm:ss,SSSZ", Asia/Tokyo}
NG : %d{yyyy-MM-dd HH:mm:ss,SSSZ, Asia/Tokyo}
     → ZoneRulesException: Unknown time-zone ID: SSSZ で起動失敗
```

---

## 4. CloudWatch Agent サイドカー

`cloudwatch-agent/amazon-cloudwatch-agent.json` を配置し、
サイドカーに `TZ=Asia/Tokyo` を設定する。
詳細な根拠と検証手順は `cloudwatch-agent/README.md` を参照。

要点のみ:

| 項目 | 値 | 理由 |
|------|----|----|
| `file_path` | `/mnt/logs/<svc>/*/tracelog` | `*` をディレクトリ側に置き、ローテート済みファイルに一致させない（二重送信防止） |
| `timestamp_format` | `%Y-%m-%d %H:%M:%S.%f%z`（アプリ）<br>`%Y-%m-%d %H:%M:%S,%f%z`（server.log） | `%z` でオフセットを解釈。ミリ秒区切りが `.` と `,` で違う点に注意 |
| `timezone` | `Local`（+ サイドカー `TZ=Asia/Tokyo`） | `%z` が主。これはフォールバック |
| `multi_line_start_pattern` | `{timestamp_format}` | 全エントリに設定。スタックトレースを 1 イベントに |

---

## 5. 適用後の検証

### 5-1. TZ が効いているか

```bash
# コンテナ内
ps -ef | grep -o 'user.timezone=[^ ]*'      # -> user.timezone=Asia/Tokyo
date                                         # -> JST（tzdata を入れた場合）
```

### 5-2. ログ行とファイル名が JST で揃っているか

```bash
# 適用前に採取したログで異常を確認（ベースライン）
./tools/verify-log-rotation.sh /mnt/logs/front-svc

# 適用後、1 日以上経過してから再実行 → 「異常: 0 件」になること
./tools/verify-log-rotation.sh /mnt/logs/front-svc
./tools/verify-log-rotation.sh /mnt/logs/front-svc/mid
```

想定される出力（適用前）:

```
[OVERRUN] tracelog.2026-09-01-19  (day単位)
            ファイル名の期間 : 2026-09-01 00:00:00+0900 〜 2026-09-01 23:59:59+0900
            中身の時刻範囲   : 2026-09-01 09:00:12+0900 〜 2026-09-02 08:59:59+0900
            はみ出し(後方)   : 32400 秒 (9.0 時間)
...
 [TZ-SKEW] はみ出し量が一律 9 時間前後です。
```

はみ出しが **ちょうど 32400 秒（9 時間）** なら RC-1（UTC/JST）、
**不定かつ大きい**なら RC-3（多重書き込み）、
**数秒以内**なら RC-2（境界の染み出し・許容範囲）。

#### `[BOOT-ROT]` の扱い（rotate-on-boot=true 適用後）

`rotate-on-boot=true` にすると、退避ファイルは「起動日」の名前を持ちつつ
中身は前日以前から始まる（§2-5 副作用 1）。これは**異常ではない**ため、
本ツールは連番付きファイル（`base.<日付>.<N>`）で
**前方はみ出しのみ・後方はみ出し無し**のものを `[BOOT-ROT]` として分類し、
異常件数に数えない。

```
[BOOT-ROT] server.log.2026-09-02.1  (day単位)
            ファイル名の期間 : 2026-09-02 00:00:00+0900 〜 2026-09-02 23:59:59+0900
            中身の時刻範囲   : 2026-09-01 20:11:04+0900 〜 2026-09-01 23:58:41+0900
            前方はみ出し     : 14340 秒 (4.0 時間)  ← 起動時退避によるもの（正常）
```

適用前の構成（`rotate-on-boot=false`）を検査するときは
`ROTATE_ON_BOOT=false` を指定する。この場合は従来どおり `[UNDERRUN]` として
異常に数えられる。

```bash
ROTATE_ON_BOOT=false ./tools/verify-log-rotation.sh /mnt/logs/front-svc/mid
```

**受け入れ基準**: 適用後は「異常: 0 件」。`[BOOT-ROT]` は件数が出てよいが、
その件数は**再起動回数と一致するはず**である。一致しない場合は
RC-2/RC-3 と混同していないか個別に確認すること。

> `tools/verify-log-rotation.sh` は tzdata の無い環境で
> `TZ=Asia/Tokyo` が無言で UTC に落ちることを自前で検出して停止する。
> その場合は `TZ_EXPECT=JST-9` を指定するか、tzdata を導入すること。

### 5-3. CloudWatch のイベント時刻が正しいか

```bash
aws logs filter-log-events \
  --log-group-name /ecs/jbosseap/front/server \
  --limit 5 --query 'events[].[timestamp,message]' --output text
```

`timestamp`（epoch ミリ秒 = UTC）を JST に直し、
同じ行の先頭に印字されている時刻と一致することを確認する。

```bash
TZ=Asia/Tokyo date -d @$(( <timestamp> / 1000 )) '+%Y-%m-%d %H:%M:%S'
```

### 5-4. 1 ファイル = 1 タスクになっているか

```bash
ls -la /mnt/logs/front-svc/
# task-abc123/  task-def456/  mid/   のようにタスク単位で分かれていること
# tracelog がルート直下に無いこと（あれば旧構成の残骸）
```

---

## 6. 移行時の注意

1. **切替日時を記録する。**
   UTC で書かれた既存ファイルと JST で書かれた新ファイルが混在する期間がある。
   ログ行の `+0900` の有無で機械的に判別できる。

2. **切替直後の 9 時間は集計から除外するか、個別に扱う。**
   切替時点で開いていたファイルは、前半 UTC・後半 JST の混在になる。

3. **既存の EFS 上のログはそのまま残す。**
   ファイル名の意味が変わるだけで、内容は失われない。
   過去分を JST で集計する場合は「UTC 日 D-1 と D を連結して JST で再フィルタ」する。

4. **ローリングデプロイ中は新旧タスクが同居する。**
   旧タスクは共有ディレクトリの `tracelog` に、新タスクは
   `<task-id>/tracelog` に書くため、衝突はしない（安全に移行できる）。

5. **CloudWatch のロググループが増える。**
   server.log / tracelog の収集を新規に追加しているため、
   保持期間とコストを事前に確認すること。

---

## 7. 残課題（本実装のスコープ外）

- **日付サフィックス付きファイルの世代管理。**
  JBoss の `max-backup-index` はサイズ連番にしか効かない。
  EFS ライフサイクル管理（IA 移行）＋定期削除ジョブが別途必要。
  `rotate-on-boot=true` により、この連番は「サイズ超過」と「起動時退避」の
  両方で消費されるようになった点に注意（`.1` が最新の逆時系列）。
- **クラッシュループ時の EFS 上の世代喪失。**
  同一日に `max-backup-index` 回を超えて再起動すると、当日の古い退避分から消える。
  `autoflush=true` により CloudWatch Logs 側には残るため実害は限定的だが、
  EFS 上での完全保全が要件なら `max-backup-index` の引き上げを検討する。
- **Logback 側の RC-5。**
  `TimeBasedRollingPolicy` にも同じ構造（既存ファイルの `lastModified` から
  現在周期を決める）があるが、`rotate-on-boot` 相当の属性が無い。
  ECS のタスク固有ディレクトリ構成では発生しにくいため現状維持とした。
  詳細と選択肢は `docs/ANALYSIS_UTC_JST.md` §7-8。
- **終了済みタスクのディレクトリ掃除。**
  `<task-id>/` と `mid/<task-id>/` の定期削除（例: 90 日超）。
- **CloudWatch Agent の state 永続化。**
  未対応だとサイドカー再起動時に重複送信が発生する
  （`ecs/taskdef-timezone-snippet.json` に構成例を記載）。
