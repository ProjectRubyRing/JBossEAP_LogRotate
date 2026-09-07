# ログローテーション異常の分析 — UTC / JST の関係と根本原因

対象事象:

> `tracelog.2026-09-01-19` の中に `2026-09-02 00:14:03.424` のログが出ている
> （JBoss EAP の `server.log` でも同様の事象が発生）

---

## 0. 結論（先に要約）

原因は 1 つではなく、**性質も影響時間幅も異なる 4 つの欠陥が重畳**している。

| # | 根本原因 | ずれの大きさ | 影響対象 |
|---|---------|------------|---------|
| **RC-1** | ローテーション境界とファイル名の日付が **UTC** で決まる一方、運用・稼働統計は **JST** で読む | **常時 9 時間** | tracelog / server.log / 全ファイルログ |
| **RC-2** | ローテートは「境界時刻」ではなく「境界後の最初の書き込み」で起きる（遅延ローテート）。行の時刻は *生成時刻*、ローテート判定は *書き込み時刻* | 数百 ms 〜 数秒 | 全ファイルログ |
| **RC-3** | EFS のサービス共有ディレクトリに **複数タスクが同名ファイルへ書き込む**。`rename` 後も旧 inode へ書き続ける | **無制限（数時間〜）** | アプリログ（tracelog 等）※ server.log はタスク固有 dir のため対象外 |
| **RC-4** | CloudWatch Agent が JST のタイムスタンプを **UTC として解釈**（`timezone: "Local"` かつサイドカー TZ=UTC） | **9 時間** | CloudWatch Logs 上のイベント時刻 |

**RC-1 が本件の主因**であり、ご指摘の「UTC と JST の関係」そのものである。
RC-3 は「ファイル名と中身が無関係になる」最悪ケースを作るため、稼働統計を取る前に必ず塞ぐ必要がある。

---

## 1. RC-1: UTC 境界でローテートし、JST で読む

### 1.1 現状構成（調査結果）

| レイヤ | TZ 設定の有無 | 実効 TZ |
|--------|-------------|--------|
| アプリコンテナ（`Dockerfile.base` / タスク定義） | `TZ` 環境変数なし | **UTC** |
| JVM（JBoss EAP） | `-Duser.timezone` なし | **UTC**（OS 既定を継承） |
| Logback `fileNamePattern` の `%d` | TZ 指定なし | **JVM 既定 = UTC** |
| Logback encoder の `%d` | TZ 指定なし | **JVM 既定 = UTC** |
| EAP `periodic-rotating-file-handler` の `suffix` | TZ 属性が存在しない | **JVM 既定 = UTC** |
| EAP `pattern-formatter` の `%d` | TZ 指定なし | **JVM 既定 = UTC** |
| CloudWatch Agent サイドカー | `TZ` 環境変数なし | **UTC** |
| 運用者・稼働統計・障害報告 | — | **JST** |

つまり **書く側が全部 UTC、読む側が JST**。
ファイル自体は仕様どおりローテートされているが、その「日」は UTC の日である。

### 1.2 UTC 日と JST 日の対応（9 時間ずれ）

```
JST = UTC + 09:00     （日本は 1951 年以降 夏時間なし = 年間を通じて固定オフセット）

  UTC 日 2026-09-01   00:00:00 ─────────────────────────── 23:59:59.999
                          │                                     │
                          ▼                                     ▼
  JST                2026-09-01 09:00:00           2026-09-02 08:59:59.999
                     └─────────┬──────────┘        └──────────┬──────────┘
                       JST 09-01 の後半 15 時間        JST 09-02 の前半 9 時間
```

- **1 つの UTC 日ファイルは、必ず JST の 2 日分にまたがる。**
- **1 つの JST 日は、必ず 2 つの UTC 日ファイルに分割される。**

時間単位ローテート（`.yyyy-MM-dd-HH`）の場合も同様で、
UTC の HH 時ファイルは JST の `HH+9` 時（超えたら翌日）に対応する。

### 1.3 報告事象の算術的検証

`tracelog` のローテート定義は
`${LOG_OUT_DIR}/tracelog.%d{yyyy-MM-dd}.%i`（`dhapp_2/src/main/resources/logback-spring.xml:169`）。
末尾の `-19` / `.19` は **`%i`（同一日内のサイズローテート連番）** である。
すなわち `tracelog.2026-09-01-19` = **UTC 日 2026-09-01 の 20 番目のセグメント**。

| 値 | UTC 表現 | JST 表現 |
|----|---------|---------|
| ファイル名が示す期間 | 2026-09-01 00:00:00 〜 23:59:59.999 | 2026-09-01 09:00 〜 **2026-09-02 08:59** |
| 問題のログ行 | 2026-09-01 **15:14:03.424** | 2026-09-02 **00:14:03.424** |

→ UTC 15:14:03.424 は UTC 日 09-01 の範囲内であり、**ファイル振り分けは仕様どおり正しい**。
異常なのは「行の時刻を JST として読む人間」と「UTC で切られたファイル名」の不整合である。

> **`-19` を「時（`.yyyy-MM-dd-HH`）」と解釈した場合の検証**
> UTC 19 時ファイル = JST 翌 04:00〜04:59 となり、JST 00:14 の行が入ることは
> RC-1 単独では説明できない。その場合の原因は **RC-3（多重書き込み）** である。
> どちらの解釈でも本書の対策で解消する。

### 1.4 稼働統計にとって何が問題か

- 「JST の 1 日分」を取るには **UTC 日 D-1 と D の 2 ファイルを連結し、時刻で再フィルタ**する必要がある。
- 日次／時間帯別の件数・レスポンスタイム集計が、9 時間ずれた区間で算出される。
- 深夜帯（JST 00:00〜09:00）のログが「前日」ファイルに入るため、障害発生日の切り出しを誤る。
- `maxHistory`（保持日数）／`totalSizeCap` も UTC 日基準で切れるため、JST 基準の保持ポリシーとずれる。
- 月次・年次の締めでは、月初 9 時間分が前月ファイルに残る。

---

## 2. RC-2: 遅延ローテート — 「行の時刻」と「ローテート判定の時刻」が違う

ローテーションは *タイマー* ではなく **書き込み契機**で起きる。

| 実装 | ローテート判定に使う時刻 | 行に印字される時刻 |
|------|----------------------|------------------|
| Logback `TimeBasedRollingPolicy` / `SizeAndTimeBasedRollingPolicy` | `System.currentTimeMillis()` = **appender 到達時刻** | `ILoggingEvent#getTimeStamp()` = **イベント生成時刻** |
| JBoss `PeriodicRotatingFileHandler` | `ExtLogRecord#getMillis()`（`preWrite` で判定）= **生成時刻** | 同左 |

この差から、境界付近で次が起きる。

```
23:59:59.990  スレッド A がイベント生成（行の時刻 = 09-01 23:59:59.990）
              ↓ GC / ロック待ち / キューイングで遅延
00:00:00.010  A が appender に到達 → currentTimeMillis が境界を超えている
              → ここでローテート（旧ファイルを 09-01 として確定・rename）
              → その後 A のイベントを *新しい* ファイルへ書く

結果: "2026-09-01 23:59:59.990" の行が 09-02 のファイルに入る
```

JBoss 側は逆向きも起きる。`async-handler` を挟むと生成時刻順と書き込み順がずれ、
境界後のレコードでローテートした直後に境界前のレコードが新ファイルへ落ちる。

**ずれ幅は秒オーダー**であり 9 時間の説明にはならないが、
「ファイル名の期間 = 中身の時刻範囲」という前提は**厳密には成立しない**。
これが「稼働統計をファイル名に依存させてはいけない」根拠になる（§5 方針 4）。

---

## 3. RC-3: EFS 共有ディレクトリでの多重書き込み（最も危険）

`ECS_EFS_Dockerfile_Symboliclink/docs/DESIGN.md` §4.2 / §11-1 のとおり、

| ログ種別 | EFS 上の出力先 | タスク間 |
|---------|--------------|---------|
| JBoss サーバログ | `/mnt/logs/<comp>/logs/<svc>/mid/<TASK_INSTANCE_ID>/` | **タスク固有（安全）** |
| アプリログ（tracelog 等） | `/mnt/logs/<comp>/logs/<svc>/` | **サービス内 全タスクで共有（危険）** |

同設計書 §11-1 は「複数タスクが同名ファイルへ書くと混在・ローテーション競合が起きるため、
アプリのログファイル名にホスト名等を含める設定を推奨（アプリ側責務）」と明記しているが、
`logback-spring.xml` には**未実装**である。

### 3.1 何が起きるか

```
タスク A の fd ──┐
                  ├──▶ inode #1000   ( パス名: "tracelog" )
タスク B の fd ──┘

00:00  タスク A がローテート: rename("tracelog" → "tracelog.2026-09-01-19")
       → inode #1000 は「名前が変わっただけ」。B の fd は依然 inode #1000 を指す
       → タスク A は新しい inode #1001 ("tracelog") へ書き始める
       → タスク B は 00:14 も 03:00 も、ずっと "tracelog.2026-09-01-19" へ書き続ける
```

**結果: ローテート済みファイルに、何時間も後のタイムスタンプの行が追記され続ける。**
これは報告事象（`-19` ファイルに `00:14:03.424`）を、UTC/JST に関係なく単独で説明する。

### 3.2 併発する二次被害

- 両タスクが同じ `%i` 連番を取り合い、**ローテート済みファイルを互いに上書き**する
- `maxHistory` / `totalSizeCap` の削除処理が競合し、**他タスクのログを消す**
- CloudWatch Agent は差し替わった inode を追えず、**取りこぼし・二重送信**が出る
- ファイルサイズ判定も他タスクの書き込み量を含むため、`maxFileSize` が想定より早く発火する

**JBoss の `server.log` はタスク固有ディレクトリのため RC-3 の対象外**だが、
`jboss.server.log.dir` をサービス共有ディレクトリへ変更すると同じ問題が発生する。
本実装では server.log のタスク固有配置を**維持することを設計制約として明示**する。

---

## 4. RC-4: CloudWatch Agent 側のタイムスタンプ解釈

現行 `CWA_Sidecar_Generator/cloudwatch-agent-config.json`:

```json
"timestamp_format": "%Y-%m-%d %H:%M:%S,%f",
"timezone": "Local"
```

- `timezone: "Local"` は **CloudWatch Agent サイドカーコンテナの TZ** を意味する。
  タスク定義に `TZ` 環境変数が無いため実効 **UTC**。
- 現状はログ行も UTC のため偶然一致しており、顕在化していない。
- **RC-1 を直してログ行を JST 化した瞬間、Agent は JST の文字列を UTC として解釈し、
  CloudWatch Logs のイベント時刻が 9 時間未来にずれる。**
  したがって RC-1 と RC-4 は**必ず同時に**対処する必要がある。

### 4.1 CloudWatch Logs 側の時刻モデル

- CloudWatch Logs のイベント時刻は内部的に **epoch ミリ秒（UTC）** で保持される。
- マネジメントコンソールは**ブラウザのローカル TZ（= JST）で表示**する。
- したがって **Agent が正しく解釈しさえすれば、CloudWatch 上の集計は TZ 安全**になる。

この性質が §5 方針 4（統計はイベント時刻から取る）の前提になる。

---

## 5. 対策の設計方針

### 方針 1: どの層でも TZ を暗黙のまま使わない

暗黙の既定 TZ に依存している箇所を**すべて明示指定**する。

| 層 | 対策 | 実装ファイル |
|----|------|------------|
| コンテナ（アプリ／サイドカー両方） | `TZ=Asia/Tokyo` を環境変数で明示 | `ecs/taskdef-timezone-snippet.json` |
| JVM | `-Duser.timezone=Asia/Tokyo`（JDK は内蔵 tzdb を使うため OS の tzdata 不要） | `jboss/conf/01-timezone.conf` |
| Logback `fileNamePattern` | `%d{yyyy-MM-dd, Asia/Tokyo}` — **TZ を第 2 引数で固定** | `logback/logback-spring.xml` |
| Logback encoder | `%d{"yyyy-MM-dd HH:mm:ss.SSSZ", Asia/Tokyo}` — TZ 固定 + オフセット印字 | 同上 |
| EAP handler の `suffix` | TZ 属性が無いため JVM 既定 TZ が唯一の制御点 → 上記 JVM 設定で JST 化 | `jboss/cli/10-logging-rotation-jst.cli` |
| EAP `pattern-formatter` | `%d{yyyy-MM-dd HH:mm:ss,SSSZ}` — オフセット印字 | 同上 |
| CloudWatch Agent | `timestamp_format` に `%z` を含める + サイドカーに `TZ=Asia/Tokyo` | `cloudwatch-agent/amazon-cloudwatch-agent.json` |

> **重要（EAP 固有の制約）**
> WildFly / JBoss EAP の `logging` サブシステムには、
> `periodic-rotating-file-handler` / `periodic-size-rotating-file-handler` の
> **`suffix` に適用する TZ を指定する属性が無い**。
> 内部実装（`org.jboss.logmanager.handlers.PeriodicRotatingFileHandler`）は
> `TimeZone.getDefault()` を使うため、**JVM 既定 TZ が唯一の制御点**である。
> 使用中の EAP バージョンで属性の有無を確認するには次を実行する:
> ```
> /subsystem=logging/periodic-size-rotating-file-handler=FILE:read-resource-description
> ```

### 方針 2: ログ行を自己記述的にする

タイムスタンプに **UTC オフセットを含める**（`2026-09-02 00:14:03,424+0900`）。

- 行だけ見れば TZ が一意に決まり、誰がどの環境で読んでも誤解しない
- CloudWatch Agent の `timezone` 設定への依存が消える（行内の `%z` が優先される）
- 将来コンテナ TZ が変わっても、既存ログの解釈が壊れない
- 過去ログ（オフセット無し・UTC）と新ログ（オフセット有り・JST）が
  **見た目で判別できる**ため、移行期の混乱を防げる

### 方針 3: 「1 ファイル = 1 プロセス」を構造的に保証する

アプリログの出力先を **タスク固有ディレクトリ**にする
（JBoss ログが既に採用している `mid/<TASK_INSTANCE_ID>` と同じ思想）。

```
/mnt/logs/<svc>/<TASK_INSTANCE_ID>/tracelog            ← 実体（1 タスク専有）
/mnt/logs/<svc>/<TASK_INSTANCE_ID>/tracelog.2026-09-01.0
/mnt/logs/<svc>/mid/<TASK_INSTANCE_ID>/server.log      ← 既存どおり
```

**ファイル名は変えずディレクトリで分離する**ため、既存の運用手順・grep 対象名を壊さない。
副次効果として CloudWatch Agent の glob を
`/mnt/logs/<svc>/*/tracelog` と書け、**ローテート済みファイルに一致しない**
（= 二重送信が構造的に起きない）。

#### 不採用にした代替案

| 案 | 不採用理由 |
|----|-----------|
| Logback `prudent` モード（ファイルロックで多重書き込みを調停） | サイズベースのローテートと併用不可。EFS(NFS) 上のロックは高コストでスループットが出ない |
| ファイル名にホスト名を埋める（`tracelog-<host>`） | CWAgent の glob がローテート済みファイル（`tracelog-<host>.2026-09-01.0`）にも一致し、二重送信の温床になる。既存の grep 手順も壊れる |
| OS の `logrotate(8)` を cron 併用 | JVM 側のローテートと二重に走り競合する。`copytruncate` は書き込み中のファイルオフセットを壊し、NUL 埋めが発生する |
| 全レイヤを UTC に統一（運用も UTC で読む） | 技術的には最も単純だが、稼働統計・障害報告・監査が JST 前提のため運用負担が大きい。※採用する場合は本実装の `Asia/Tokyo` を `UTC` に置換するだけで成立する |
| ローテート済みファイルも CWAgent の glob に含める | Agent の state はパス単位のため、rename でパスが変わると先頭から再送され重複する |

### 方針 4: 稼働統計はファイル名ではなくイベント時刻から取る

RC-2 により「ファイル名の期間 = 中身の時刻範囲」は厳密には保証できない（秒オーダーの染み出し）。
稼働統計は **CloudWatch Logs のイベント時刻（epoch UTC）** を正とし、
Logs Insights で JST に変換して集計する。

```
# JST 日付でグルーピングする例（CloudWatch Logs Insights）
fields dateFloor(@timestamp + 9 * 3600 * 1000, 1d) as jst_day
| stats count(*) as cnt by jst_day
| sort jst_day desc
```

```
# JST の時間帯別
fields (toMillis(@timestamp) + 9 * 3600 * 1000) / 3600000 % 24 as jst_hour
| stats count(*) as cnt by jst_hour
| sort jst_hour asc
```

ファイル名の JST 化は「EFS 上で人間が直接調査するとき」のためのものであり、
両方を揃えて初めて CloudWatch と EFS の突き合わせが可能になる。

---

## 6. 対策適用後の期待状態

| 観点 | 適用前 | 適用後 |
|------|-------|-------|
| `tracelog.2026-09-01.*` の中身 | UTC 09-01（= JST 09-01 09:00 〜 09-02 08:59） | **JST 09-01 00:00:00 〜 23:59:59** |
| `server.log.2026-09-01` の中身 | 同上 | **JST 09-01 の 1 日分** |
| ログ行 | `2026-09-01 15:14:03.424`（TZ 不明） | `2026-09-02 00:14:03,424+0900`（自己記述） |
| ローテート済みファイルへの追記 | 起こりうる（RC-3） | **起こらない**（1 ファイル = 1 タスク） |
| CloudWatch のイベント時刻 | UTC 解釈（JST 化した瞬間 9h ずれる） | `%z` により常に正しい |
| JST 日次統計 | 2 ファイル連結 + 再フィルタが必要 | **1 ファイル = 1 JST 日** |
| 境界付近のずれ | 秒オーダー（RC-2） | 秒オーダー（残存。統計はイベント時刻で取るため実害なし） |

---

## 7. 残存リスクと運用上の注意

1. **RC-2 は構造上ゼロにできない。**
   ローテートが書き込み契機である以上、境界 ±数百 ms の行が隣のファイルに入りうる。
   厳密な期間集計は CloudWatch Logs Insights 側で行うこと。

2. **`periodic-size-rotating-file-handler` の `max-backup-index` はサイズ連番にのみ効く。**
   日付サフィックス付きファイルは無限に増えるため、EFS ライフサイクル管理か
   定期削除ジョブが必須（`DESIGN.md` §11-3 と同種の課題）。

3. **タスク終了後のディレクトリが残置される。**
   `mid/task-*` と同様、アプリログのタスク固有ディレクトリにも定期削除が必要。

4. **CloudWatch Agent の state ファイルはコンテナローカル**
   （`/opt/aws/amazon-cloudwatch-agent/logs/state`）。
   サイドカー再起動で読み取りオフセットが失われ、再送（重複）が発生しうる。
   タスク固有の EFS パスをこのディレクトリにマウントすると回避できる。

5. **移行期に 9 時間の重なりが生じる。**
   UTC で書かれた既存ファイルと JST で書かれた新ファイルが混在する期間があるため、
   切替日時を記録し、集計クエリで切替点をまたがないようにすること。
   ログ行のオフセット有無（`+0900` の有無）で機械的に判別できる。

6. **夏時間は考慮不要。**
   `Asia/Tokyo` は 1951 年以降 DST なし・固定 +09:00。
   固定オフセット `GMT+09:00` でも実害はないが、tzdb 準拠の `Asia/Tokyo` を推奨する。

7. **`%z` の CloudWatch Agent 対応。**
   `timestamp_format` の `%z` は Agent が対応している前提の実装だが、
   使用中の Agent バージョンで必ず検証すること（手順は `docs/IMPLEMENTATION.md` §5）。
   非対応だった場合のフォールバックも同節に記載している。
