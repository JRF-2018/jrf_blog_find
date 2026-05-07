# ブログ退避計画

## 大目的

JRF のブログ等を一括検索できる静的アーカイブサイト「JRF ブログ退避所」を構築する。
主要言語は Perl で、GitHub Actions (YAML) により自動ビルド・デプロイする。

- サイト URL: https://jrf-2018.github.io/jrf_blog_find/
- GitHub リポジトリ: https://github.com/JRF-2018/jrf_blog_find
- ブランチ: master（ソース）/ gh-pages（デプロイ先）

## 要件

  * データ取得: 私のブログ(複数)をログに取り、その複数のブログを一つのテキストファイルにダンプしたものが http://jrockford.s1010.xrea.com/jrf_cocolog_backup/jrf_cocolog_public.zip に full_dump.txt として入っています。今後この zip ファイルを「上の zip」として言及します。

  * 記事分割: full_dump.txt をパースし、記事ごとに独立した HTML ファイルを作成する (articles/YYYY/MM/DD_ID.html のような階層) 。また月ごとのインデックスページも作成します。

  * 検索機能: Pagefind を実行してインデックスを生成します。(Pagefind というツールに特にこだわりはないです。)

  * 自動化: これらを毎期ボタン一つ（workflow_dispatch）で実行し、GitHub Pages にデプロイする GitHub Actions を作成します。
  
  * 私が文字列で検索できること、cocolog id (cocolog:〜 または aboutme:〜 という形式です)で検索できることを重視します。特に元の記事への URL が検索できることを重視します。ですから表示にはこだわらず、各ページはテキストベタ書き (pre で囲う？) でいいです。URL はクリックできるようにするぐらいはしていただけるとうれしいです。

  * \[image:タイトル:http://jrf.cocolog-nifty.com/.../XXX.png\] みたいなものは、上の zip の images/ に入っていれば、そのイメージを表示したいです。そのとき XXX が thumbnail-YYYY.png という形式で YYYY.png みたいなのが images/ にあれば、それはそのイメージをクリックしたときに表示されるようにしたいです。

  * ちなみに上の zip は三ヶ月ごとに更新されます。元のメインブログサイトは http://jrf.cocolog-nifty.com/ 下です。ここにさらに はてなブックマークと「グローバル共有メモ」(http://jrockford.s1010.xrea.com/demo/shared_memo.cgi?cmd=log) のログがあります。

## データ構成

zip URL: http://jrockford.s1010.xrea.com/jrf_cocolog_backup/jrf_cocolog_public.zip  
三ヶ月ごとに更新される。GitHub Actions から curl で直接取得する（Releases 経由不要）。

zip の内容:

  * `full_dump.txt` (32MB) — 全ログのテキスト連結。パース対象はこれ。
  * `*.blog_dump` — ブログ別 XML バックアップ
  * `jrf-bookmark.atom.xml` — はてなブックマーク
  * `SharedMemo.txt` — グローバル共有メモ（別フォーマット、現在未突合）
  * `images/` — ブログ画像（760 ファイル）
  * `post-info.log` — 投稿メタ情報

元のメインブログ: http://jrf.cocolog-nifty.com/  
共有メモ: http://jrockford.s1010.xrea.com/demo/shared_memo.cgi?cmd=log  
ブックマーク: https://b.hatena.ne.jp/jrf/

## full_dump.txt のフォーマット

セクション区切り:

```
XXXXXXXXXXXXXXXX
セクション名
XXXXXXXXXXXXXXXX
```

セクション 8 種（記事タイプ）:

| タイプ | セクション名 | 件数 | ヘッダー形式 |
|--------|------------|------|------------|
| `column` | JRF の私見：雑記 | 227 | `[column] [cocolog:ID]` |
| `religion` | JRF の私見：宗教と動機付け | 38 | `[religion] [cocolog:ID]` |
| `society` | JRF の私見：税・経済・法 | 37 | `[society] [cocolog:ID]` |
| `software` | JRF のソフトウェア Tips | 82 | `[software] [cocolog:ID]` |
| `pr` | JRF の勝手に PR | 4 | `[pr] [cocolog:ID]` |
| `statuses` | JRF のひとこと | 5423 | `[statuses] [cocolog:ID]` または `[statuses] [aboutme:ID]` の**両形式**あり |
| `hbm` | JRF の公開ブックマーク | 2047 | `[hbm]`（IDなし、連番管理） |
| `gsm` | グローバル共有メモ | 8635 | `[gsm]` のあと `○ YYYY-MM-DDTHH:MM:SSZ ランダム文字列` |

通常ブログ記事（column 等）の構造:
```
[column] [cocolog:9644812]
《タイトル》
http://jrf.cocolog-nifty.com/column/YYYY/MM/post_N.html
YYYY年M月D日 HH:MM:SS [タグ1][タグ2]

本文...

更新：YY/MM/DD
初公開：YYYY年MM月DD日 HH:MM:SS

Trackbacks:

《トラックバック先タイトル》 from 送信元
http://...

本文抜粋

受信： YYYY-MM-DD HH:MM:SS (JST)

Links:

リンク名: http://...
```

  * Trackbacks は省略されることがある。Links も省略されることがある。
  * Links は Trackbacks の後、または Trackbacks がない場合は本文の後に直接来る。
  * body の切り出し終端に `\nTrackbacks?:` と `\nLinks:` の両方を含めること。

statuses（ひとこと）の構造:
```
[statuses] [cocolog:ID]  ← または [aboutme:ID]
http://jrf.cocolog-nifty.com/statuses/YYYY/MM/post-HASH.html

本文...
JRF YYYY年M月D日
```

gsm（グローバル共有メモ）の構造:
```
[gsm]
○ 2026-03-07T09:36:01Z ランダム文字列

本文...
```

gsm のタイムスタンプは初期 16 件だけ `T11:1633Z` のような不規則フォーマット（分秒連結）。  
それ以外は正規の `THH:MM:SSZ` 形式。

## 本文中の特殊記法と変換ルール

  * `[image:タイトル:URL]` — 画像埋め込み。`thumbnail-XXX.jpg` なら `images/XXX.jpg` がフル画像（クリックで拡大、`a.thumb-link` で枠あり）。フル画像なし（単体）は `img.thumb-plain` で枠なし。ローカルにない場合は元 URL にテキストリンク。

  * `[cocolog:9999]` / `[aboutme:9999]` — アーカイブ内に対応記事があれば**内部リンク**（緑＋薄緑背景、`a.int-link.cocolog-id`）。なければ `<span class="cocolog-id">` のみ。Pagefind 検索対象。

  * `>>2026-03-07T09:36:01Z` または `>> 2026-03-07T09:36:01Z` — gsm 記事へのタイムスタンプ参照。`normalize_gsm_ts()` で正規化して `%gsm_ts_to_art` と照合。対応あれば内部リンク（`a.int-link.gsm-tsref`、薄青紫背景）。なければ `<span class="gsm-tsref">`（薄灰）。

  * `http://jrf.cocolog-nifty.com/...` — 本文中URL。アーカイブ内収録記事なら内部リンク（緑）。外部URLは `a.ext-link`（青）。

  * `[google:クエリ]` — Google 検索リンク（`span.extref-google`、薄青背景）。別タブ。

  * `[wikipedia:項目名]` — Wikipedia 日本語版リンク（`span.extref-wiki`、薄緑背景）。別タブ。

  * `keyword: キーワード`（行頭） — `search.html?q=キーワード` へのリンク（`span.keyword-ref`、薄黄背景）。

  * **meta 欄の「元 URL」は常に外部リンク**。内部リンクに変えない。

  * **Links: セクションの URL 処理（重要）**:
    - 対応する通常ブログ記事（column 等）→ 内部リンク（緑）
    - 対応する hbm のみ → 外部リンク＋右に `(hbm)` 内部リンクを小さく添える（`span.hbm-ref`）
    - 対応なし → 外部リンク（青）
    - 理由: hbm は「ブックマーク記事」であり Links の意図（外部リソース参照）とは異なるため、URL 自体は外部リンクとして表示する。

## 生成物（parse_and_gen.pl）

```
docs/
├── index.html                        トップページ（検索UI + タイプ別リンク + 月別一覧）
├── search.html                       検索専用ページ（?q=クエリ でURL直接指定可）
├── blogparts.html                    ブログパーツ（元ブログのサイドバーに貼るHTML）
├── style.css                         スタイルシート
├── articles/YYYY/MM/TYPE_ID.html    各記事
├── index/YYYY/MM.html               月別インデックス
├── index/TYPE.html                  タイプ別インデックス（gsm/statuses は月ごと折りたたみ）
├── index/tags.html                  タグ一覧（件数順タグクラウド、アコーディオン）
└── index/tag/tag_NNNN.html          タグ個別ページ（175件）
```

**重要: タグ個別ページのファイル名は連番 ID（`tag_0001.html` 等）**  
日本語タグを URLエンコードしたファイル名は GitHub Pages で動作しない。  
`%tag_id` テーブル（タグ名→連番ID）を**パース後かつ HTML生成前**に構築すること（処理順が重要）。

ファイル命名規則:
  * `column_9644812.html` — `TYPE_COCOLOGID`
  * `statuses_cocolog_95790410.html` — statuses の cocolog 形式
  * `statuses_aboutme_4032.html` — statuses の aboutme 形式
  * `hbm_00001.html` — hbm は連番
  * `gsm_000001.html` — gsm は連番

各記事ページの構成:
  * **meta テーブル**（種別・セクション・日時・元 URL・タグ） — Pagefind 検索対象
    * 日時セル → 月別インデックスへのリンク
    * 元 URL → 常に元記事（外部）へのリンク。内部リンクにしない。
    * タグ → タグ個別ページへのリンク（`a.tag-link`）
  * **本文**（`<pre class="body">`） — 各種変換・リンク化済み
  * **Trackbacks**（`<pre class="trackbacks">`） — Pagefind 除外
  * **Links**（`<pre class="links">`、薄青背景） — Trackbacks の後または本文直後
  * **後方参照セクション**（`section.backrefs`） — この記事を参照している他記事一覧（日付新しい順）。Pagefind 除外。
  * **前後記事ナビ**（`nav.prevnext`） — 同タイプ内の時系列順で前後記事へのリンク

各インデックスページの構成:
  * 月別・タイプ別インデックスの各行にサブブログバッジ（`span.type-badge`、タイプ別色分け）を表示
  * statuses・gsm は本文冒頭 40 文字を疑似タイトルとして使用（`art_display_title()`）
  * gsm/statuses のタイプ別インデックスは月ごとに `<details>` 折りたたみ
  * タグ一覧は件数順タグクラウド＋アコーディオン（1つ開いたら他は閉じる JS）

## Pagefind 検索対応

  * `<article data-pagefind-body>` で記事全体をインデックス対象
  * meta テーブル全体も検索対象（Trackbacks・後方参照・ナビは `data-pagefind-ignore`）
  * `cocolog:ID` / `aboutme:ID` は `<span class="cocolog-id">` でマーク
  * 元記事 URL は `<span class="original-url">` でマーク
  * `search.html?q=クエリ` で URL パラメータ直接指定の検索が可能（Pagefind の `triggerSearch()` 使用）
  * `blogparts.html` に元ブログのサイドバー用検索フォームを生成

## スクリプト使い方

```bash
perl parse_and_gen.pl [--dump full_dump.txt] [--outdir docs] [--imgdir images]
```

デフォルト: `--dump full_dump.txt` / `--outdir docs` / `--imgdir images`

## 内部実装メモ（parse_and_gen.pl）

### 処理順序（変えてはいけない）

1. full_dump.txt 読み込み・セクション分割
2. タイプ別パーサで `@all_articles` を構築
3. **後方参照インデックス構築**（`%back_refs`）— 全本文を走査
4. **内部リンクテーブル構築**（`%url_to_art`・`%cocolog_to_art`・`%aboutme_to_art`・`%gsm_ts_to_art`）
5. **パス1**: 全記事の `html_path` を確定
6. **パス1b**: `prev_art`・`next_art` を設定（同タイプ時系列順）
7. **パス1.5**: `%tag_id` テーブルを構築 ← **パス2より前であること（タグリンクに必須）**
8. **パス2**: HTML生成 + インデックス収集（`%month_index`・`%type_index`・`%tag_index`）
9. 各種インデックス・CSS・ブログパーツを生成

### タイプ別パーサの注意点

  * **statuses** の区切り正規表現は `\[(?:aboutme|cocolog):\d+\]`（両形式対応）
  * **gsm** のタイムスタンプは `normalize_gsm_ts()` で正規化（初期 16 件の不規則フォーマット対応）
  * **Links:** セクションは `parse_blog` でのみパース（`$art->{links_text}` に格納）

### body_to_html の変換順序

`[image:]` 退避 → `[google/wikipedia:]` 退避 → `[cocolog/aboutme:]` 退避 → `>>timestamp` 退避 → `keyword:` 退避 → HTMLエスケープ → URL リンク化 → 各退避を内部/外部リンクに展開 → `[image:]` を `<img>` に展開

## GitHub Actions（build.yml）

```yaml
on:
  workflow_dispatch:  # 手動実行

steps:
  - checkout
  - curl で zip をダウンロード・展開（xrea.com から直接取得）
  - perl scripts/parse_and_gen.pl
  - cp -r cocolog_data/images docs/images && touch docs/.nojekyll
  - npx -y pagefind --site docs --output-path docs/pagefind
  - peaceiris/actions-gh-pages@v4 でデプロイ（publish_branch: gh-pages）
```

**重要な注意点:**
  * `touch docs/.nojekyll` が必須。ないと `%エンコード` URL が GitHub Pages で 404 になる。
  * Actions 実行は「Re-run all jobs」ではなく「Run workflow」を使うこと。Re-run は最新コードを checkout しない。
  * `permissions: contents: write` が必要（gh-pages ブランチへの push のため）。

## 環境・制約

  * Claude Code は使えない。アーティファクト（ファイル出力）にコードを示してもらい手動実行する形式。
  * ローカルは Cygwin (Perl)。Pagefind は GitHub Actions 上で実行。
  * Claude のネットワーク制限: xrea.com・GitHub CDN・主要クラウドストレージには Claude から直接アクセス不可。zip の確認は `git clone` でリポジトリをクローンして行う。

## 未実装・今後の課題

  * はてなブックマーク (`hbm`) と グローバル共有メモ (`gsm`) の `SharedMemo.txt` との突合
  * 定期実行（build.yml の schedule をコメントアウト中。現状は三ヶ月ごとに手動 Run workflow）
