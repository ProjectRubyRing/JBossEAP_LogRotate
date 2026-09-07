# CloudWatch Agent サイドカー設定の解説

`amazon-cloudwatch-agent.json` の各設定値の根拠と、現行設定
（`CWA_Sidecar_Generator/cloudwatch-agent-config.json`）からの変更点。

---

## 1. 現行設定からの変更点サマリ

| 項目 | 現行 | 変更後 | 理由 |
|------|------|-------|------|
| `file_path` | `.../application.log*` | `.../*/application.log` | **`*` の位置をディレクトリ側へ移動**。ローテート済みファイルに一致させず、タスク固有ディレクトリを横断する |
| `timestamp_format` | `%Y-%m-%d %H:%M:%S,%f` | `%Y-%m-%d %H:%M:%S.%f%z`（アプリログ）<br>`%Y-%m-%d %H:%M:%S,%f%z`（server.log） | **`%z` でオフセットを解釈**。TZ 設定に依存しなくなる。またミリ秒区切りが `.` と `,` で異なるため分離 |
| `timezone` | `Local`（実効 UTC） | `Local`（実効 **JST**） | サイドカーに `TZ=Asia/Tokyo` を設定。`%z` が主、これはフォールバック |
| `multi_line_start_pattern` | error.log のみ | **全エントリ** | どのログにもスタックトレースが出うる。`{timestamp_format}` 指定で自動同期 |
| server.log の収集 | **なし** | `mid/*/server.log` を追加 | JBoss EAP のサーバログが CloudWatch に来ていなかった |
| tracelog の収集 | なし | 追加 | 報告事象の対象ファイル |

---

## 2. `file_path` の glob 設計（最重要）

```
/mnt/logs/front-svc/*/tracelog          ← 採用
/mnt/logs/front-svc/tracelog*           ← 不採用（現行方式）
```

### なぜ `tracelog*` ではいけないか

CloudWatch Agent は読み取りオフセットを **ファイルパス単位** で state ファイル
（`/opt/aws/amazon-cloudwatch-agent/logs/state`）に記録する。

```
23:59  tracelog                      … offset 900000 まで送信済み
00:00  rename → tracelog.2026-09-01.0
       ・"tracelog" は新規ファイル（offset 0 から。これは正しい）
       ・"tracelog.2026-09-01.0" は Agent にとって "初めて見るパス"
         → glob に一致すると **先頭から全部再送** → 900000 バイト分が重複
```

`*` をディレクトリ側に置けば、glob はローテート済みファイル
（`tracelog.2026-09-01.0`）に一致しないため、この重複が構造的に起きない。

ローテート直前の未送信分は、Agent が保持している **オープン済み fd が
rename 後も同じ inode を指し続ける**ため、そのまま読み切られる。

### 前提: アプリ側のタスク固有ディレクトリ化

この glob は `logback/logback-spring.xml` の変更 3（出力先を
`${LOG_OUT_DIR}/${LOG_INSTANCE_ID}/` に分離）とセットで初めて成立する。
片方だけ適用してはならない。

---

## 3. `timestamp_format` と TZ の三重防御

```
第 1 防御  ログ行に +0900 が入っている        → %z が解釈する（TZ 設定と無関係）
第 2 防御  サイドカーに TZ=Asia/Tokyo          → timezone:"Local" が JST になる
第 3 防御  JVM が -Duser.timezone=Asia/Tokyo   → そもそも行が JST で出る
```

`%z` が効いていれば `timezone` は参照されない。
`timezone: "Local"` を残しているのは、将来誰かがログ書式から `Z`（オフセット）を
外したときに、**フォールバックも正しい側（JST）に倒れる**ようにするため。
ここを `"UTC"` にすると、その場合に 9 時間ずれる。

### ミリ秒区切りが 2 種類ある点に注意

| 対象 | パターン | `timestamp_format` |
|------|---------|-------------------|
| JBoss EAP `server.log`<br>Logback `SERVER_PATTERN` | `HH:mm:ss,SSSZ`（**カンマ**） | `%Y-%m-%d %H:%M:%S,%f%z` |
| Logback `APP_PATTERN`（application/error/tracelog 等） | `HH:mm:ss.SSSZ`（**ドット**） | `%Y-%m-%d %H:%M:%S.%f%z` |

区切りを間違えるとタイムスタンプ抽出に失敗し、Agent は
**そのイベントの時刻を「取り込んだ現在時刻」で埋める**（無言で劣化する）。
稼働統計が壊れるため、§5 の検証を必ず実施すること。

---

## 4. `multi_line_start_pattern: "{timestamp_format}"`

`{timestamp_format}` は「`timestamp_format` と同じものを複数行開始パターンとして使う」
という特殊指定。正規表現を二重管理せずに済む。

これにより Java のスタックトレース

```
2026-09-02 00:14:03.424+0900 ERROR [http-nio-1] c.e.Foo - failed
java.lang.IllegalStateException: ...
        at com.example.Foo.bar(Foo.java:42)
Caused by: java.sql.SQLException: ...
        ... 12 more
```

が **1 イベント**として CloudWatch Logs に入る。
現行設定では error.log にしか指定がなく、他のログではスタックトレースが
1 行ずつバラバラのイベントになっていた。

---

## 5. 適用後の検証手順

### 5-1. `%z` が解釈できているかを確認する

サイドカーを一時的に debug 有効で起動する（`"agent": {"debug": true}`）。

```bash
# サイドカーのセルフログ（/ecs/jbosseap/cwagent-selflog）を確認
aws logs tail /ecs/jbosseap/cwagent-selflog --since 10m --follow
```

タイムスタンプ抽出に失敗している場合、次の警旨のログが出る。

```
W! Failed to parse timestamp from log line ...
```

### 5-2. イベント時刻とログ行の時刻が一致するかを確認する（本質的な検証）

```bash
aws logs filter-log-events \
  --log-group-name /ecs/jbosseap/front/server \
  --limit 5 \
  --query 'events[].[timestamp,message]' --output text
```

出力の `timestamp`（epoch ミリ秒 = UTC）を JST に直し、
同じ行の先頭に印字されている時刻と **一致すること** を確認する。

```bash
# epoch ミリ秒 → JST
TZ=Asia/Tokyo date -d @$(( 1788361443424 / 1000 )) '+%Y-%m-%d %H:%M:%S'
```

9 時間ずれていれば `%z` が効いておらず、かつ `timezone` も UTC になっている。

### 5-3. `%z` が非対応だった場合のフォールバック

使用中の Agent が `timestamp_format` の `%z` に対応していない場合
（古いバージョン）は、次の 2 点で代替する。

1. `amazon-cloudwatch-agent.json` の全エントリから `%z` を外す
   （`"%Y-%m-%d %H:%M:%S.%f"` / `"%Y-%m-%d %H:%M:%S,%f"`）
2. サイドカーコンテナに `TZ=Asia/Tokyo` を**必ず**設定する
   （`timezone: "Local"` が JST として解決される）

この構成でも結果は正しくなるが、
「サイドカーの TZ 設定漏れ = 無言で 9 時間ずれる」という脆さが残るため、
`%z` が使えるなら `%z` を優先すること。

---

## 6. 運用上の注意

### 6-1. state ファイルの永続化（再送・重複対策）

Agent の読み取りオフセットは
`/opt/aws/amazon-cloudwatch-agent/logs/state` に保存される。
Fargate ではコンテナローカルのため、**サイドカー再起動でオフセットが失われ、
既存ファイルを先頭から再送する**（CloudWatch Logs 側で重複）。

タスク固有の EFS パスをこのディレクトリにマウントすると回避できる。

```json
{
  "sourceVolume": "efs-logs",
  "containerPath": "/opt/aws/amazon-cloudwatch-agent/logs/state",
  "readOnly": false
}
```

※ この場合サイドカーの EFS マウントを `readOnly: true` にはできない。
ログ本体用（読み取り専用）と state 用（書き込み可）でマウントポイントを分けること。

### 6-2. `auto_removal: false` を維持する理由

`true` にすると Agent が送信後にファイルを削除する。
EFS 上のログは「CloudWatch とは別系統の一次証跡」として残す方針のため false。
その代わり EFS 側の増加は以下で抑える。

- Logback: `maxHistory` / `totalSizeCap`（タスク固有ディレクトリ内で完結）
- JBoss `server.log`: 日付サフィックス付きファイルには世代管理が効かないため、
  EFS ライフサイクル管理（IA 移行）＋定期削除ジョブが必須
- 終了済みタスクのディレクトリ（`<taskid>/`、`mid/<taskid>/`）の定期削除

### 6-3. 稼働統計は CloudWatch のイベント時刻から取る

ファイル名の期間と中身の時刻範囲は、ローテートが書き込み契機である以上
秒オーダーで染み出す（分析書 RC-2）。集計は CloudWatch Logs Insights で行う。

```
fields dateFloor(@timestamp + 9 * 3600 * 1000, 1d) as jst_day
| stats count(*) as cnt by jst_day
| sort jst_day desc
```
