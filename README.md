# JRF ブログ退避所

<!-- Time-stamp: "2026-10-21T23:55:38Z" -->

私のブログ等を検索するための退避所です。

https://jrf-2018.github.io/jrf_blog_find/index.html

…からアクセスできます。

私のブログ検索用ブログパーツは↓にあります。

https://jrf-2018.github.io/jrf_blog_find/blogparts.html


## 仕組み

三ヶ月ごとに更新されるブログ等のバックアップ (zip) を GitHub Actions で取得し、`scripts/parse_and_gen.pl` で記事ごとの HTML を生成、Pagefind で検索インデックスを作って GitHub Pages にデプロイしています。詳しい仕様は PURPOSE.md にまとめてあります。

各記事ページには次の機能があります。

  * 原文をコピー … その記事の原文（バックアップ上のテキスト）をクリップボードにコピーします。

  * 数式表示 (MathJax) … 数式を使っている記事でのみ表示されます。「ひとこと」では `[mathjax-on]` または `<mathjax-on/>` と書かれた記事、雑記などでは `\begin{math}` 〜 `\end{math}` または `\begin{displaymath}` 〜 `\end{displaymath}` を使った記事が対象です。数式表示中はテキストとしてのコピーがうまくできないので、off にするか「原文をコピー」をお使いください。

  * pre 連結 … 「ひとこと」は 300字ずつ区切って投稿しているため、ソースなどを `<pre>` で分割して示していることがあります。それを一つにつなげて表示します（デフォルトで on）。


## 作成について

Claude さんに作ってもらいました。

  * v0.0.1 は Claude Projects (Web 版) を使い、Claude Sonnet 4.6 さんに作ってもらいました。出した指示は PURPOSE.md にまとめてあります。

  * v0.0.2 は Claude Code (Claude Opus 5.5 さん) に作ってもらいました。


## 変更履歴

  * v0.0.1 (2026-05-07)
    * 最初の公開。記事ごとの HTML、月別・タイプ別・タグ別インデックス、Pagefind による検索、ブログパーツ。

  * v0.0.2 (2026-10-22)
    * 記事ページに「原文をコピー」ボタンを追加。
    * MathJax による数式表示に対応（on/off 切替可）。
    * 「ひとこと」で `<pre>` で分割されたものを連結表示する機能を追加（on/off 切替可）。


## Author

JRF ( http://jrf.cocolog-nifty.com/statuses , Twitter (X): @jion_rockford )


## License

基本的に「簡単なプログラムなので Public Domain でいいです。ただし、それだと使いにくいという場合は MIT License で。」でよいのですが、私が作った部分についてはそれでよいとしても、問題は、AI さんが作った部分をどう評価するか…です。

プログラムはほぼすべて Claude さんが作ってます。細かい指示を私は出しましたが…。

----
(This document is mainly written in Japanese/UTF8.)
