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
| **RC-5** | **異常終了後の再起動**が、クラッシュしたプロセスの残した `server.log` に追記を続ける。ファイル名は中身ではなく `lastModified` から決まる | **無制限（再起動後セッション全体）** | server.log（`append=true` かつ `rotate-on-boot=false` のとき） |

**RC-1 が本件の主因**であり、ご指摘の「UTC と JST の関係」そのものである。
RC-3 は「ファイル名と中身が無関係になる」最悪ケースを作るため、稼働統計を取る前に必ず塞ぐ必要がある。
**RC-5 は RC-3 の“時間軸版”**（同じファイルを 2 つのプロセスが *空間的* に共有するのが RC-3、
*時間的* に共有するのが RC-5）であり、対策も同じ「1 ファイル = 1 プロセス」の徹底になる。

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

## 3.5. RC-5: 異常終了後の再起動が「ローテート前の日付」のファイルに入る

> 報告事象:
> 「異常終了して再起動したあとのログが、ローテーション前の日付が付いた
>   `server.log.<前日>` に書き込まれている」

RC-3 が「同じファイルを **複数タスクが空間的に共有**する」問題なのに対し、
RC-5 は「同じファイルを **クラッシュ前後のプロセスが時間的に共有**する」問題である。
`server.log` がタスク固有ディレクトリにあっても、**同じディレクトリで JVM が
起動し直る限り発生する**（→ §3.5.4）。

### 3.5.1 前提となる 2 つの実装事実

`org.jboss.logmanager.handlers.PeriodicRotatingFileHandler` の実装（jboss-logmanager 2.x）:

```java
// ① ファイルを開いた *後* に、ファイルの mtime からローテート情報を作る
public void setFile(final File file) throws FileNotFoundException {
    synchronized (outputLock) {
        super.setFile(file);                       // FileOutputStream(file, append) で open
        if (format != null && file != null && file.lastModified() > 0) {
            calcNextRollover(file.lastModified()); // ← mtime が基準
        }
    }
}

// ② ローテートは *タイマーではなく書き込み契機*
protected void preWrite(final ExtLogRecord record) {
    final long recordMillis = record.getMillis();
    if (recordMillis >= nextRollover) {
        rollOver();                    // server.log → server.log + nextSuffix
        calcNextRollover(recordMillis);
    }
}

private void calcNextRollover(final long fromTime) {
    ...
    nextSuffix = format.format(new Date(fromTime));   // ← ファイル名はここで決まる
    ...
}
```

ここから導かれる性質は 2 つ:

| # | 性質 | 帰結 |
|---|------|------|
| A | `append=true` で開いても mtime は更新されない（`FileOutputStream(file, true)` は truncate しない）。したがって `nextSuffix` は **クラッシュ直前の最終書き込み時刻**から作られる | ファイル名は「中身の日付」ではなく「mtime の日付」 |
| B | 境界判定は `preWrite` でしか行われない。**書き込みが起きるまでローテートは起きない** | 境界判定が 1 回でも外れると、以後そのファイルは古い `nextSuffix` のまま確定する |

### 3.5.2 事象が成立する経路

`append=true` + `rotate-on-boot=false` では、**再起動したプロセスは
クラッシュしたプロセスが残した物理ファイルにそのまま追記する**。
その物理ファイルが最終的にどの名前で確定するかは、A のとおり
**クラッシュ前の mtime** で決まっている。

```
09-01 23:58  最後の書き込み → server.log の mtime = 09-01 23:58
09-01 23:59  異常終了（JVM が buffer を flush しきらずに死ぬ）
09-02 00:05  再起動
             setFile(server.log)
               → append で open（mtime は 09-01 23:58 のまま）
               → calcNextRollover(09-01 23:58)
                    nextSuffix  = ".2026-09-01"      ← 前日で確定
                    nextRollover = 09-02 00:00:00
09-02 00:05〜 再起動後のログを **同じ物理ファイル** に追記
             → 後でこのファイルは server.log.2026-09-01 という名前で確定する
```

境界判定（B）が正しく発火すれば、最初の 1 行で `rollOver()` が走って分離される。
しかし発火は次の条件に依存しており、**異常終了の周辺はまさにその条件が崩れる場面**である。

| 発火が外れる条件 | 異常終了時に起きる理由 |
|-----------------|---------------------|
| `mtime` が最終ログ行より **新しい** | EFS(NFS) はクライアントの flush/close 契機で mtime を更新する。監視・バックアップ・`cp` などが触っても更新される。→ `nextRollover` が実際より未来に押し出され、境界をまたいだ再起動でも発火しない |
| `record.getMillis()` の順序が書き込み順と違う | `async-handler` を挟んでいる場合（RC-2 と同根）。境界後のレコードで先にローテートし、境界前のレコードが新ファイルへ落ちる／その逆 |
| クラッシュで失われた分だけ mtime と内容がずれる | `autoflush=false` の区間や OS バッファに残った分は、mtime だけ進んで内容が無い |

**要するに `rotate-on-boot=false` は、「境界判定が毎回正しく当たること」に
correctness を賭けている構成である。** 通常運用では当たるが、異常終了はその
前提が崩れる典型ケースであり、外れたときの被害は「再起動後セッション丸ごと」と
無制限になる。

### 3.5.3 併発する二次被害: ローテート済みファイルの上書き

`rollOver()` が使う退避処理は **インデックス無しの 3 引数版**である。

```java
// PeriodicRotatingFileHandler#rollOver
suffixRotator.rotate(errorManager, file.toPath(), nextSuffix);

// SuffixRotator#rotate(ErrorManager, Path, String)  →  最終的に
Files.move(src, target, StandardCopyOption.REPLACE_EXISTING);   // ← 既存を破壊する
```

つまり遅延ローテートで `server.log.2026-09-01` を作るとき、
**同名ファイルが既にあれば警告なく上書き消滅する**。
同一日に複数回クラッシュ／再起動していると、先に確定していた分が失われる。

### 3.5.4 どの経路で実際に起きるか（重要）

`rotate-on-boot` の発火条件は次のとおり（`PeriodicSizeRotatingFileHandler#setFile`）:

```java
if (rotateOnBoot && maxBackupIndex > 0 && file != null && file.exists() && file.length() > 0L) { ... }
```

**「起動時に `server.log` が既に存在する」ことが前提**である。したがって:

| 経路 | 起動時に server.log が既存か | RC-5 | rotate-on-boot |
|------|--------------------------|------|----------------|
| ECS で **タスクごと置き換わる**（TaskARN が変わる → `mid/<TASK_INSTANCE_ID>/` が新規） | 存在しない | 起きない | 発火しない（無害） |
| 同一タスク内で**コンテナだけ再起動**する | 存在する | **起きる** | 発火する |
| EC2 / オンプレの**固定ログディレクトリ** | 存在する | **起きる** | 発火する |
| `LOG_INSTANCE_ID` を固定値・ホスト名等で運用している | 存在する | **起きる** | 発火する |
| ゾンビ JVM が残ったまま新 JVM が起動 | 存在する | **起きる**（RC-3 も併発） | 発火するが、旧 JVM の fd は旧 inode に残る |

> **設定しても症状が変わらない場合はこの表を先に確認すること。**
> 「タスクごとに新しいディレクトリになる」経路では RC-5 はそもそも起きず、
> `rotate-on-boot=true` は何もしない（設定して害は無い）。

### 3.5.5 対策: `rotate-on-boot=true`

`periodic-size-rotating-file-handler` の `rotate-on-boot=true` は、
**`setFile` の中で、最初の 1 行が書かれるより前に**既存ファイルを退避する。

```java
// PeriodicSizeRotatingFileHandler#setFile
if (rotateOnBoot && maxBackupIndex > 0 && file != null && file.exists() && file.length() > 0L) {
    final String suffix = getNextSuffix();
    ...
    setFileInternal(null, false);                                    // 先に閉じる
    suffixRotator.rotate(getErrorManager(), file.toPath(), suffix, maxBackupIndex);
}
setFileInternal(file, false);                                        // 空ファイルから開始
```

これで **§3.5.2 の前提（クラッシュ前のファイルへ追記する）が成立しなくなる**。
境界判定が当たるかどうかに correctness を賭けるのをやめ、
「1 起動 = 1 ファイル」を構造で保証する形に変わる。
§3.5.3 の上書き破壊も、退避先が `.1` 側（連番シフト）になるため起きなくなる。

> `periodic-rotating-file-handler` には `rotate-on-boot` 属性が **無い**。
> RC-5 を塞ぐには `periodic-size-rotating-file-handler` への型変換が必須である。

#### 採用に伴う 3 つの副作用（いずれも許容だが、知らないと誤診する）

**副作用 1: 退避ファイルの日付は「内容の日付」ではなく「起動日」になる**

WildFly の属性適用順は
`..., ROTATE_ON_BOOT, SUFFIX, NAMED_FORMATTER, FILE`
（`PeriodicSizeRotatingHandlerResourceDefinition#ATTRIBUTES`）。
`suffix` を適用する時点では `file` がまだ未設定なので、`setSuffix()` の中では

```java
final File file = getFile();
if (file != null && file.lastModified() > 0) { now = file.lastModified(); }
else { now = System.currentTimeMillis(); }     // ← こちらが選ばれる
calcNextRollover(now);
```

**起動時刻**が使われる。つまり退避先は `server.log.<起動日>.1`。

```
09-01 20:00 の内容を持つ server.log を 09-02 10:00 に起動して退避
   → server.log.2026-09-02.1   （中身は 09-01 のログ）
```

日付が **前方に** ずれる。RC-5 の元事象（後方にずれる = 前日名のファイルに翌日分が入る）
とは逆向きで、かつ **1 ファイル内の混在が起きない**点が決定的に違う。
「ファイル名の日付」を正にする運用はいずれにせよ破綻するため、
方針 2（行にオフセットを印字）と方針 4（統計はイベント時刻から取る）が前提条件になる。
`tools/verify-log-rotation.sh` はこのパターンを `[BOOT-ROT]` として
RC-1 / RC-3 の異常と区別する。

**副作用 2: 1 起動につき連番を 1 つ消費する**

退避は 4 引数版 `SuffixRotator#rotate(em, src, suffix, maxBackupIndex)` で行われ、
`.max` を削除 → `.N` を `.N+1` へシフト → `server.log` を `.1` へ、という順で動く。
つまり **`.1` が最新**（逆時系列）であり、`max-backup-index=20` なら
**同一日に 20 回再起動すると当日の最古世代から消えていく**。

- クラッシュループ（CrashLoopBackOff）では数分で一巡しうる。
- 保険は CloudWatch Logs 側にある。`autoflush=true` により行は即座に
  Agent へ渡っているため、**EFS 上の世代が消えてもイベントは残る**。
  これが方針 4（統計・調査はイベント時刻を正とする）を採る実利でもある。
- ECS でタスクごとにディレクトリが変わる経路では、そもそも退避が発生しないため無関係。

**副作用 3: 設定変更後の初回起動だけ、ブートの数行が退避側に入る**

logging サブシステム初期化前のブートメッセージは `standalone.xml` ではなく
`standalone/configuration/logging.properties` の設定で書かれる。同ファイルは
現行モデルから再生成されるため、`rotate-on-boot=true` が反映されるのは
**次回起動から**である。したがって適用直後の 1 回だけ、
ブート数行が退避側ファイルの末尾に残る。

影響は「数行・サブ秒」であり、RC-5 本体（再起動後セッション丸ごと・無制限）とは
桁が違う。実測手順は `docs/IMPLEMENTATION.md` §2-5。

#### 不採用にした代替案

| 案 | 不採用理由 |
|----|-----------|
| `append=false` | 退避ではなく **truncate**。クラッシュ直前のログ（＝障害解析で最も必要な部分）を破壊する。症状は消えるが原因調査ができなくなる |
| `rotate-on-boot=false` のまま `autoflush=true` で mtime 精度を上げる | 発火条件の一部（mtime のずれ）しか潰せない。`async-handler` 経路と EFS の mtime 更新契機は残る。「境界判定が毎回当たること」に賭ける構造自体が変わらない |
| 起動スクリプトで `server.log` を `mv` してから起動 | 実質同じことを外部で行う案。JVM 起動前に確実に動く利点はあるが、退避規則が JBoss 側と二重管理になり、`max-backup-index` による世代管理も効かない。EAP の属性で足りるなら属性で行う |
| suffix を毎時（`.yyyy-MM-dd-HH`）にして被害時間を縮める | 混入の *時間幅* が縮むだけで混入自体は残る。EFS 上のファイル数は 24 倍になる |
| ログ行の時刻だけを信じ、ファイル名の不整合は運用で許容 | 方針としては正しく、本実装でも方針 4 として採用している。ただし「EFS 上で人間が直接 grep する」調査導線が壊れたままになるため、**併用**であって代替ではない |

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

### 方針 3: 「1 ファイル = 1 プロセス」を構造的に保証する（空間軸と時間軸の両方）

**空間軸（RC-3）**: アプリログの出力先を **タスク固有ディレクトリ**にする
（JBoss ログが既に採用している `mid/<TASK_INSTANCE_ID>` と同じ思想）。

**時間軸（RC-5）**: JBoss の `FILE` ハンドラに `rotate-on-boot=true` を設定し、
起動時点で前プロセスのファイルを退避して**空ファイルから書き始める**。
「同じ物理ファイルを 2 つのプロセスが共有しない」という同一の原則を、
空間（同時刻の別タスク）と時間（クラッシュ前後の別プロセス）の両方に適用する。

| 軸 | 共有の形 | 根本原因 | 対策 | 実装ファイル |
|----|---------|---------|------|------------|
| 空間 | 同時刻の複数タスクが同名ファイルを開く | RC-3 | タスク固有ディレクトリ | `ecs/entrypoint-log-instance-id.sh`, `logback/logback-spring.xml` |
| 時間 | クラッシュ前後のプロセスが同一ファイルを開く | RC-5 | `rotate-on-boot=true` | `jboss/cli/10-logging-rotation-jst.cli` |

> `rotate-on-boot` は `max-backup-index > 0` かつ「起動時に対象ファイルが既存」の
> ときだけ発火する。ECS でタスクごとにディレクトリが変わる経路では発火しない
> （そもそも RC-5 も起きない）。→ §3.5.4

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
| 異常終了後の再起動ログ | 前プロセスのファイルへ追記され、前日名で確定しうる（RC-5・無制限） | **起動時に退避され、必ず空ファイルから始まる** |
| 再起動を跨ぐ 1 ファイル内の混在 | 起こりうる（RC-5） | **起こらない**（1 ファイル = 1 起動） |
| CloudWatch のイベント時刻 | UTC 解釈（JST 化した瞬間 9h ずれる） | `%z` により常に正しい |
| JST 日次統計 | 2 ファイル連結 + 再フィルタが必要 | **1 JST 日 = 1 グループ**（`server.log.<日付>` + `<日付>.N`） |
| 境界付近のずれ | 秒オーダー（RC-2） | 秒オーダー（残存。統計はイベント時刻で取るため実害なし） |
| 起動を跨いだ日のファイル名 | — | 退避分は **起動日** が付く（§3.5 副作用 1）。中身は行の時刻で判定する |

---

## 7. 残存リスクと運用上の注意

1. **RC-2 は構造上ゼロにできない。**
   ローテートが書き込み契機である以上、境界 ±数百 ms の行が隣のファイルに入りうる。
   厳密な期間集計は CloudWatch Logs Insights 側で行うこと。

2. **`periodic-size-rotating-file-handler` の `max-backup-index` はサイズ連番にのみ効く。**
   日付サフィックス付きファイルは無限に増えるため、EFS ライフサイクル管理か
   定期削除ジョブが必須（`DESIGN.md` §11-3 と同種の課題）。
   なお `rotate-on-boot=true` を入れたことで、この連番は
   **「サイズ超過」と「起動時退避」の両方で消費される**ようになった。
   `.1` が最新（逆時系列）である点にも注意。

2-1. **クラッシュループ時に同一日の古い世代が失われる（RC-5 対策の副作用）。**
   `max-backup-index=20` なら同一日に 20 回の再起動で当日分が一巡する。
   EFS 上の世代は失われるが、`autoflush=true` により行は書かれた時点で
   CloudWatch Agent に渡っているため **CloudWatch Logs 側には残る**。
   EFS 上での完全な保全が要件なら `max-backup-index` を引き上げるか、
   起動ごとにログディレクトリが変わる構成（ECS のタスク固有ディレクトリ）を採る。

2-2. **`rotate-on-boot` が発火するのは「起動時に対象ファイルが既存」の場合だけ。**
   ECS でタスクごとに `mid/<TASK_INSTANCE_ID>/` が変わる経路では発火しない。
   設定しても症状が変わらない場合、まず §3.5.4 の表で自分の経路を確認すること
   （その経路なら RC-5 自体が起きていない）。

2-3. **退避ファイルの日付は「起動日」であり「中身の日付」ではない。**
   §3.5 副作用 1。ファイル名を稼働統計の根拠に使わないこと（方針 4）。

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

8. **Logback 側にも RC-5 と同じ構造がある（本実装のスコープ外）。**
   `TimeBasedRollingPolicy`（`DefaultTimeBasedFileNamingAndTriggeringPolicy#start`）も、
   `<file>` が指定されているとき **既存ファイルの `lastModified()` から現在周期を決める**。
   したがって「クラッシュ前のファイルに追記し、名前は mtime で決まる」という
   §3.5.1 の性質 A / B は Logback にも当てはまる。
   ただし Logback には `rotate-on-boot` 相当の属性が無く、取りうる選択肢は次のとおり:

   | 案 | 評価 |
   |----|------|
   | `<file>` を書かず `fileNamePattern` だけにする（アクティブファイル自体が日付付きになる） | 構造的には最も正しい。ただし `tracelog` → `tracelog.2026-09-02.0` とファイル名が変わり、本実装の「ファイル名を変えない」制約と CloudWatch Agent の glob 設計を壊す |
   | 起動スクリプトで既存ファイルを退避してから起動 | 世代管理が Logback 側と二重になる |
   | 現状維持（タスク固有ディレクトリで RC-3 を潰し、統計はイベント時刻で取る） | **本実装の選択**。ECS ではタスクごとにディレクトリが変わるため、Logback 側の RC-5 は実際には発生しにくい（§3.5.4 と同じ理屈） |

   アプリログでも RC-5 を実測できた場合のみ、上の 1 案目を別途検討する。
