# ブログ退避計画

## 大目的

私のブログの逃避先（静的アーカイブサイト）を構築したいです。以下の要件で GitHub Actions (YAML) を作成してください。主要言語は Perl で作っていただけると後日の私がわかりやすいでしょう。

## 要件

  * データ取得: 私のブログ(複数)をログに取り、その複数のブログを一つのテキストファイルにダンプしたものが http://jrockford.s1010.xrea.com/jrf_cocolog_backup/jrf_cocolog_public.zip に full_dump.txt として入っています。今後この zip ファイルを「上の zip」として言及します。

  * 記事分割: full_dump.txt をパースし、記事ごとに独立した HTML ファイルを作成する (articles/YYYY/MM/DD_ID.html のような階層) 。また月ごとのインデックスページも作成します。

  * 検索機能: Pagefind を実行してインデックスを生成します。(Pagefind というツールに特にこだわりはないです。)

  * 自動化: これらを毎期ボタン一つ（workflow_dispatch）で実行し、GitHub Pages にデプロイする GitHub Actions を作成します。
  
  * 私が文字列で検索できること、cocolog id (cocolog:〜 または aboutme:〜 という形式です)で検索できることを重視します。特に元の記事への URL が検索できることを重視します。ですから表示にはこだわらず、各ページはテキストベタ書き (pre で囲う？) でいいです。URL はクリックできるようにするぐらいはしていただけるとうれしいです。

  * \[image:タイトル:http://jrf.cocolog-nifty.com/.../XXX.png\] みたいなものは、上の zip の images/ に入っていれば、そのイメージを表示したいです。そのとき XXX が thumbnail-YYYY.png という形式で YYYY.png みたいなのが images/ にあれば、それはそのイメージをクリックしたときに表示されるようにしたいです。

  * ちなみに上の zip は三ヶ月ごとに更新されます。元のメインブログサイトは http://jrf.cocolog-nifty.com/ 下です。ここにさらに はてなブックマークと「グローバル共有メモ」(http://jrockford.s1010.xrea.com/demo/shared_memo.cgi?cmd=log) のログがあります。

  * Claude Code は使えません。アーチファクトにコードを示してもらって実行するという形式で作っていきます。

  * こちらのローカルテスト環境は Cygwin (の Perl)です。Perl スクリプトを full_dump.txt に適用するぐらいならできます。Pagefind はインストールされていません。テストはできれば Google Colab のターミナルなどでできるとありがたいです。もちろん、Actions (YAML) のためのリポジトリ構造を作っていただければ、それを GitHub にアップロードするぐらいはできます。

  * GitHub のレポジトリは jrf_blog_find にします。(https://github.com/JRF-2018/jrf_blog_find に置きます。)
