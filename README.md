# JBossEAP_LogRotate

JBoss EAP / Logback のログローテーションで発生していた
**「ファイル名の日付と中身のタイムスタンプが一致しない」** 事象の分析と、
UTC / JST の不整合を構造的に排除する設定実装。

対象事象:

> `tracelog.2026-09-01-19` の中に `2026-09-02 00:14:03.424` のログが出ている
> （JBoss EAP の `server.log` でも同様）
>
> 異常終了して再起動したあとのログが、ローテーション前の日付が付いた
> `server.log.<前日>` に書き込まれている

---

## 結論

5 つの原因が重畳している。主因は **RC-1（UTC でローテートし JST で読む）**。

| # | 根本原因 | ずれ幅 |
|---|---------|-------|
| RC-1 | ローテート境界とファイル名が **UTC**、運用・稼働統計は **JST** | 常時 **9 時間** |
| RC-2 | ローテートが「境界時刻」ではなく「境界後の最初の書き込み」で起きる | 数百 ms 〜 数秒 |
| RC-3 | EFS 共有ディレクトリに複数タスクが同名ファイルを開く（rename 後も旧 inode へ書き続ける） | **無制限** |
| RC-4 | CloudWatch Agent が JST を UTC として解釈（`timezone:"Local"` + サイドカー TZ=UTC） | 9 時間 |
| RC-5 | 異常終了後の再起動がクラッシュ前のファイルへ追記を続ける。ファイル名は中身ではなく `lastModified` で決まる | **無制限（再起動後セッション全体）** |

検証済みの算術（Java 17 で実測）:

```
JST 2026-09-02 00:14:03.424  ==  UTC 2026-09-01 15:14:03.424
UTC 日 2026-09-01            ==  JST 2026-09-01 09:00 〜 2026-09-02 08:59:59.999

suffix ".yyyy-MM-dd"  JVM TZ=UTC        -> server.log.2026-09-01   ← 現状
                      JVM TZ=Asia/Tokyo -> server.log.2026-09-02   ← 修正後
```

詳細は **[docs/ANALYSIS_UTC_JST.md](docs/ANALYSIS_UTC_JST.md)**。

---

## 成果物

```
docs/
  ANALYSIS_UTC_JST.md              分析書（UTC/JST の関係、4 つの根本原因、設計方針）
  IMPLEMENTATION.md                適用手順・検証手順・移行時の注意

jboss/
  cli/10-logging-rotation-jst.cli  server.log のローテーション設定（jboss-cli、冪等）
  standalone-logging-snippet.xml   同等の standalone.xml 抜粋（CLI を使わない場合）
  conf/01-timezone.conf            JVM TZ 固定（standalone.conf へ追記する断片）

logback/
  logback-spring.xml               アプリログ（tracelog 等）の修正版

cloudwatch-agent/
  amazon-cloudwatch-agent.json     サイドカー設定（%z 解釈・glob 修正・multiline）
  README.md                        各設定値の根拠と検証手順

ecs/
  taskdef-timezone-snippet.json    タスク定義抜粋（TZ、state 永続化）
  entrypoint-log-instance-id.sh    タスク固有ディレクトリ解決（entrypoint 断片）

tools/
  verify-log-rotation.sh           ローテーション健全性チェック（事象の検出・修正の確認）
```

---

## 対策の骨子

### 1. どの層でも TZ を暗黙のまま使わない

| 層 | 対策 |
|----|------|
| コンテナ | `TZ=Asia/Tokyo`（アプリ・サイドカー両方） |
| JVM | `-Duser.timezone=Asia/Tokyo`（JDK は内蔵 tzdb を使うため tzdata 不要） |
| Logback `fileNamePattern` | `%d{yyyy-MM-dd, Asia/Tokyo}` — TZ を第 2 引数で固定 |
| Logback encoder | `%d{"yyyy-MM-dd HH:mm:ss.SSSZ", Asia/Tokyo}` |
| EAP handler `suffix` | **TZ 属性が無い**ため JVM 既定 TZ が唯一の制御点 |
| EAP `pattern-formatter` | `%d{yyyy-MM-dd HH:mm:ss,SSSZ}` |
| CloudWatch Agent | `timestamp_format` に `%z` + `TZ=Asia/Tokyo` |

### 2. ログ行を自己記述的にする

```
変更前: 2026-09-01 15:14:03.424
変更後: 2026-09-02 00:14:03.424+0900
```

行だけ見れば TZ が一意に決まり、CloudWatch Agent の `timezone` 設定への
依存が消える。移行期も `+0900` の有無で新旧を機械的に判別できる。

### 3. 「1 ファイル = 1 プロセス」を構造的に保証する（空間軸と時間軸）

**空間軸（RC-3）— 同時刻の別タスクと共有しない**

```
変更前: /mnt/logs/<svc>/tracelog                    ← 全タスクが同じファイルを開く
変更後: /mnt/logs/<svc>/<TASK_INSTANCE_ID>/tracelog ← 1 タスク専有
```

**ファイル名は変えずディレクトリで分離する**ため、既存の運用手順は壊れない。
副次効果として CloudWatch Agent の glob を `/mnt/logs/<svc>/*/tracelog` と書け、
ローテート済みファイルに一致しない（＝二重送信が起きない）。

**時間軸（RC-5）— クラッシュ前のプロセスと共有しない**

```
変更前: rotate-on-boot="false"  ← 再起動後も前プロセスのファイルへ追記
変更後: rotate-on-boot="true"   ← 起動時に退避し、必ず空ファイルから開始
```

`periodic-size-rotating-file-handler` の `rotate-on-boot=true` は、
**最初の 1 行を書く前に**既存 `server.log` を `server.log.<起動日>.1` へ退避する。
「境界判定が毎回正しく当たること」に correctness を賭ける構成をやめ、
**1 ファイル = 1 起動**を構造で保証する。

| 前提条件 | 内容 |
|---------|------|
| ハンドラ型 | `periodic-rotating-file-handler` には `rotate-on-boot` が無い。型変換が必須 |
| `max-backup-index` | **> 0** でないと無言で無効化される（`=0` 禁止） |
| `append` | `true` のまま維持。`append=false` は退避ではなく **truncate** で、障害解析に必要な直前ログを破壊する |
| 発火条件 | 起動時に `server.log` が既存でサイズ > 0。ECS でタスクごとにディレクトリが変わる経路では発火しない（そこでは RC-5 も起きない） |

副作用は 3 つ（いずれも許容、詳細は分析書 §3.5）:
退避ファイルの日付が「起動日」になる／1 起動につき連番を 1 つ消費する／
適用直後の 1 回だけブート数行が退避側に入る。

### 4. 稼働統計はファイル名ではなくイベント時刻から取る

RC-2 により「ファイル名の期間 = 中身の時刻範囲」は秒オーダーで染み出す。
集計は CloudWatch Logs Insights のイベント時刻（epoch UTC）を正とする。

```
fields dateFloor(@timestamp + 9 * 3600 * 1000, 1d) as jst_day
| stats count(*) as cnt by jst_day
| sort jst_day desc
```

---

## 使い方

適用は `docs/IMPLEMENTATION.md` の手順に従う。**1〜4 は必ずセットで適用すること**
（部分適用すると「ログ行は JST・CloudWatch は UTC 解釈」の新たなずれが生じる）。

現状確認・適用後確認:

```bash
./tools/verify-log-rotation.sh /mnt/logs/front-svc
./tools/verify-log-rotation.sh /mnt/logs/front-svc/mid

# tzdata の無い環境（TZ=Asia/Tokyo が無言で UTC に落ちる）では
TZ_EXPECT=JST-9 ./tools/verify-log-rotation.sh /mnt/logs/front-svc

# 末尾 "-NN" がサイズ連番（%i）の場合
GRAN=day ./tools/verify-log-rotation.sh /mnt/logs/front-svc

# rotate-on-boot=false の旧構成を検査する（起動時退避も異常として数える）
ROTATE_ON_BOOT=false ./tools/verify-log-rotation.sh /mnt/logs/front-svc/mid
```

はみ出し量による原因の切り分け:

| はみ出し | 原因 |
|---------|------|
| ちょうど 32400 秒（9.0 時間・後方） | RC-1（UTC/JST 不一致） |
| 不定かつ大きい（後方） | RC-3（多重書き込み） |
| 数秒以内 | RC-2（境界の染み出し・許容範囲） |
| 前方のみ・連番付きファイル | RC-5 対策の起動時退避 → `[BOOT-ROT]` として正常扱い |
| 前方かつ連番なし、または前方＋後方 | RC-5 が未解消の可能性 → `rotate-on-boot` の発火条件を確認 |

---

## 関連プロジェクト

| プロジェクト | 関係 |
|------------|------|
| `ECS_EFS_Dockerfile_Symboliclink` | EFS 上のログ配置設計。§11-1 が RC-3 を既知リスクとして記載 |
| `CWA_Sidecar_Generator` | 現行の CloudWatch Agent サイドカー設定（本実装で置き換え） |
| `dhapp_2` | `logback-spring.xml` の元ファイル（tracelog を含む） |
| `dhapp2` | `configure-logging.cli`（server.log の出力先変更） |
