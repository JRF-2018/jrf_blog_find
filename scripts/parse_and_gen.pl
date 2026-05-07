#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use open ':std', ':encoding(UTF-8)';
use File::Path qw(make_path);
use File::Basename;

# ============================================================
# parse_and_gen.pl  (v3)
#   full_dump.txt をパースし、記事ごとの HTML を生成する。
#
# 使い方:
#   perl parse_and_gen.pl [--dump full_dump.txt] [--outdir docs] [--imgdir images]
#
# 生成物:
#   docs/articles/YYYY/MM/TYPE_ID.html   各記事（後方参照付き）
#   docs/index/YYYY/MM.html              月別インデックス
#   docs/index/TYPE.html                 タイプ別インデックス（gsm/statusesは月折りたたみ）
#   docs/index/tags.html                 タグ一覧
#   docs/index.html                      トップページ
#   docs/style.css                       スタイルシート
#
# 検索(Pagefind)対応:
#   - <article data-pagefind-body> で本文全体をインデックス対象
#   - cocolog:ID / aboutme:ID を <span class="cocolog-id"> でマーク
#   - 元記事URLを <span class="original-url"> でマーク
#   - meta欄(日時・URL・ID・タグ)も検索対象（Trackbackのみ除外）
# ============================================================

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

# ---------- オプション解析 ----------
my $dump_file = 'full_dump.txt';
my $out_dir   = 'docs';
my $img_dir   = 'images';

while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--dump')   { $dump_file = shift @ARGV }
    elsif ($a eq '--outdir') { $out_dir   = shift @ARGV }
    elsif ($a eq '--imgdir') { $img_dir   = shift @ARGV }
    else  { die "Unknown option: $a\n" }
}

# ---------- images/ ファイルセット ----------
my %img_exists;
if (-d $img_dir) {
    opendir(my $dh, $img_dir) or die "Cannot opendir $img_dir: $!";
    while (my $f = readdir($dh)) { next if $f =~ /^\./; $img_exists{$f} = 1 }
    closedir($dh);
}
printf STDERR "images/ から %d ファイルをロード\n", scalar keys %img_exists;

# ---------- full_dump.txt を読み込む ----------
open(my $fh, '<:encoding(UTF-8)', $dump_file) or die "Cannot open $dump_file: $!";
my $content = do { local $/; <$fh> };
close($fh);

# ---------- セクションに分割 ----------
my @raw_sections = split /XXXXXXXXXXXXXXXX\n[^\n]+\nXXXXXXXXXXXXXXXX\n/, $content;
my @section_names;
while ($content =~ /XXXXXXXXXXXXXXXX\n([^\n]+)\nXXXXXXXXXXXXXXXX/g) {
    push @section_names, $1;
}
shift @raw_sections;
printf STDERR "セクション数: %d\n", scalar @section_names;

# ---------- 全記事をパース ----------
my @all_articles;
for my $si (0 .. $#section_names) {
    my @arts = parse_section($section_names[$si], $raw_sections[$si] // '');
    push @all_articles, @arts;
    printf STDERR "  [%s] %d 件\n", $section_names[$si], scalar @arts;
}
printf STDERR "総記事数: %d\n", scalar @all_articles;

# ---------- 後方参照インデックスを構築 ----------
# %back_refs{"cocolog:NNN"} = [ $art_ref, ... ]
# %back_refs{"aboutme:NNN"} = [ $art_ref, ... ]
# %back_refs{"url:http://..."} = [ $art_ref, ... ]
my %back_refs;
print STDERR "後方参照インデックス構築中...\n";
for my $art (@all_articles) {
    my $body = $art->{body} // '';
    while ($body =~ /\[cocolog:(\d+)\]/g) {
        push @{ $back_refs{"cocolog:$1"} }, $art;
    }
    while ($body =~ /\[aboutme:(\d+)\]/g) {
        push @{ $back_refs{"aboutme:$1"} }, $art;
    }
    while ($body =~ m{(https?://jrf\.cocolog-nifty\.com/\S+?\.html)}g) {
        my $u = $1; $u =~ s/[)\]'"]+$//;
        push @{ $back_refs{"url:$u"} }, $art;
    }
}
printf STDERR "後方参照キー数: %d\n", scalar keys %back_refs;

# ---------- 内部リンクテーブルを構築 ----------
# %url_to_art    : "http://jrf.cocolog-nifty.com/..." => $art
# %cocolog_to_art: "9644812" => $art
# %aboutme_to_art: "4032"    => $art
# %gsm_ts_to_art : "2026-03-07T09:36:01Z" (正規化済み) => $art
my (%url_to_art, %cocolog_to_art, %aboutme_to_art, %gsm_ts_to_art);
for my $art (@all_articles) {
    $url_to_art{ $art->{url} } = $art if $art->{url};
    $cocolog_to_art{ $art->{cocolog_id} } = $art if $art->{cocolog_id};
    $aboutme_to_art{ $art->{aboutme_id} } = $art if $art->{aboutme_id};
    # gsm: ts_raw を正規形式に正規化してテーブルに登録
    if ($art->{type} eq 'gsm' && $art->{ts_raw}) {
        my $nts = normalize_gsm_ts($art->{ts_raw});
        $gsm_ts_to_art{$nts} = $art if $nts;
    }
}
printf STDERR "内部リンクテーブル: URL=%d, cocolog=%d, aboutme=%d, gsm_ts=%d\n",
    scalar keys %url_to_art, scalar keys %cocolog_to_art,
    scalar keys %aboutme_to_art, scalar keys %gsm_ts_to_art;

# ---------- HTML 生成（html_path を art に書き込む）----------
my %month_index;
my %type_index;
my %tag_index;

# パス1: 全記事の html_path を先に確定（後方参照リンクのため）
for my $art (@all_articles) {
    my ($year,$month) = ($art->{year}||0, $art->{month}||0);
    $art->{html_path} = ($year && $month)
        ? sprintf("articles/%04d/%02d/%s.html", $year, $month, $art->{id})
        : "articles/undated/$art->{id}.html";
}

# パス1b: 前後記事リンク用インデックスを構築
# タイプごとに時系列順で並べ、各記事に prev/next を設定
{
    my %type_arts;
    push @{ $type_arts{$_->{type}} }, $_ for @all_articles;
    for my $type (keys %type_arts) {
        my @sorted = sort {
            ($a->{year}||0)     <=> ($b->{year}||0)
            || ($a->{month}||0) <=> ($b->{month}||0)
            || ($a->{day}||0)   <=> ($b->{day}||0)
            || ($a->{time_str}||'') cmp ($b->{time_str}||'')
            || ($a->{ts_raw}||'')   cmp ($b->{ts_raw}||'')
        } @{ $type_arts{$type} };
        for my $i (0 .. $#sorted) {
            $sorted[$i]{prev_art} = $i > 0       ? $sorted[$i-1] : undef;
            $sorted[$i]{next_art} = $i < $#sorted ? $sorted[$i+1] : undef;
        }
    }
}

# パス2: HTML生成 & インデックス収集
for my $art (@all_articles) {
    gen_article_html($art, $out_dir, $img_dir);
    if ($art->{year} && $art->{month}) {
        my $ym = sprintf "%04d/%02d", $art->{year}, $art->{month};
        push @{ $month_index{$ym} }, $art;
    }
    push @{ $type_index{ $art->{type} } }, $art;
    push @{ $tag_index{$_} }, $art for @{ $art->{tags} };
}

# ---------- 各種インデックス ----------
# タグIDテーブルを先に構築（ファイル名に使う）
my %tag_id;  # tag => "tag_0001" のような連番ID
{
    my $seq = 0;
    for my $tag (sort keys %tag_index) {
        $tag_id{$tag} = sprintf("tag_%04d", ++$seq);
    }
}
printf STDERR "タグIDテーブル: %d種\n", scalar keys %tag_id;
gen_month_index($_, $month_index{$_}, $out_dir) for sort keys %month_index;
gen_type_index($_, $type_index{$_},   $out_dir) for keys %type_index;
gen_tag_index(\%tag_index, $out_dir);
gen_tag_pages(\%tag_index, $out_dir);
gen_top_index(\%month_index, \%type_index, \%tag_index, $out_dir);
gen_blogparts($out_dir);
gen_css($out_dir);
print STDERR "完了。\n";

# ============================================================
# パース
# ============================================================

sub parse_section {
    my ($sec_name, $text) = @_;
    my $type =
        $sec_name =~ /雑記/         ? 'column'   :
        $sec_name =~ /宗教/         ? 'religion' :
        $sec_name =~ /税・経済/     ? 'society'  :
        $sec_name =~ /ソフト/       ? 'software' :
        $sec_name =~ /勝手に PR/    ? 'pr'       :
        $sec_name =~ /ひとこと/     ? 'statuses' :
        $sec_name =~ /ブックマーク/ ? 'hbm'      :
        $sec_name =~ /共有メモ/     ? 'gsm'      : 'unknown';
    return
        $type eq 'gsm'      ? parse_gsm($text, $sec_name)     :
        $type eq 'statuses' ? parse_statuses($text, $sec_name) :
        $type eq 'hbm'      ? parse_hbm($text, $sec_name)      :
                              parse_blog($text, $sec_name, $type);
}

sub parse_blog {
    my ($text, $sec_name, $type) = @_;
    my @arts;
    for my $chunk (split /\n(?=\[$type\] \[cocolog:)/, $text) {
        next unless $chunk =~ /\[$type\] \[cocolog:(\d+)\]/;
        my $cid   = $1;
        my $title = ($chunk =~ /《([^》]*)》/) ? $1 : '';
        my $url   = ($chunk =~ m{(https?://jrf\.cocolog-nifty\.com/\S+\.html)}) ? $1 : '';
        my ($year,$month,$day,$time_str) = (0,0,0,'');
        my @tags;
        if ($chunk =~ /(\d{4})年(\d{1,2})月(\d{1,2})日 (\d{2}:\d{2}:\d{2}) (.*)/) {
            ($year,$month,$day,$time_str) = ($1+0,$2+0,$3+0,$4);
            @tags = ($5 =~ /\[([^\]]+)\]/g);
        } elsif ($url =~ m{/(\d{4})/(\d{2})/}) { ($year,$month) = ($1+0,$2+0) }
        my $body = '';
        $body = $1 if $chunk =~ /\d{2}:\d{2}:\d{2}[^\n]*\n+(.*?)(?=\nTrackbacks?:|\z)/s;
        $body =~ s/\s+$//;
        my @tbs;
        if ($chunk =~ /Trackbacks?:\n+(.*)\z/s) {
            my $tb = $1;
            while ($tb =~ /《([^》]*)》 from ([^\n]*)\n(https?:\/\/\S+)\n\n(.*?)(?=\n《|\z)/gs) {
                push @tbs, {title=>$1, from=>$2, url=>$3, excerpt=>$4};
            }
        }
        push @arts, {
            type=>$type, cocolog_id=>$cid, id=>"${type}_${cid}",
            title=>$title, url=>$url,
            year=>$year, month=>$month, day=>$day, time_str=>$time_str,
            tags=>\@tags, body=>$body, trackbacks=>\@tbs, section=>$sec_name,
            html_path=>'',
        };
    }
    return @arts;
}

sub parse_statuses {
    my ($text, $sec_name) = @_;
    my @arts;
    for my $chunk (split /\n(?=\[statuses\] \[(?:aboutme|cocolog):)/, $text) {
        next unless $chunk =~ /\[statuses\] \[(aboutme|cocolog):(\d+)\]/;
        my ($id_type, $num_id) = ($1, $2);
        my $url = ($chunk =~ m{(https?://jrf\.cocolog-nifty\.com/statuses/\S+\.html)}) ? $1 : '';
        my ($year,$month,$day) = (0,0,0);
        ($year,$month) = ($1+0,$2+0) if $url =~ m{/(\d{4})/(\d{2})/};
        my $body = '';
        $body = $1 if $chunk =~ /https?:\/\/\S+\.html\n+(.*)/s;
        $body =~ s/\s+$//;
        ($year,$month,$day) = ($1+0,$2+0,$3+0)
            if $body =~ /JRF\s+(\d{4})年(\d{1,2})月(\d{1,2})日\s*$/m;
        my %art = (
            type=>'statuses', id=>"statuses_${id_type}_${num_id}",
            title=>'', url=>$url,
            year=>$year, month=>$month, day=>$day, time_str=>'',
            tags=>[], body=>$body, trackbacks=>[], section=>$sec_name,
            html_path=>'',
        );
        $id_type eq 'cocolog' ? ($art{cocolog_id}=$num_id) : ($art{aboutme_id}=$num_id);
        push @arts, \%art;
    }
    return @arts;
}

sub parse_hbm {
    my ($text, $sec_name) = @_;
    my @arts;
    my $seq = 0;
    for my $chunk (split /\n(?=\[hbm\]\n)/, $text) {
        next unless $chunk =~ /^\[hbm\]/;
        $seq++;
        my $title = ($chunk =~ /《([^》]*)》/) ? $1 : '';
        my $url   = ($chunk =~ m{(https?://\S+)}) ? $1 : '';
        my ($year,$month,$day,$time_str) = (0,0,0,'');
        my @tags;
        if ($chunk =~ /(\d{4})年(\d{1,2})月(\d{1,2})日 (\d{2}:\d{2}:\d{2}) (.*)/) {
            ($year,$month,$day,$time_str) = ($1+0,$2+0,$3+0,$4);
            @tags = ($5 =~ /\[([^\]]+)\]/g);
        }
        my $body = '';
        $body = $1 if $chunk =~ /\d{2}:\d{2}:\d{2}[^\n]*\n(.+)/s;
        $body =~ s/\s+$//;
        push @arts, {
            type=>'hbm', id=>sprintf("hbm_%05d",$seq),
            title=>$title, url=>$url,
            year=>$year, month=>$month, day=>$day, time_str=>$time_str,
            tags=>\@tags, body=>$body, trackbacks=>[], section=>$sec_name,
            html_path=>'',
        };
    }
    return @arts;
}

sub parse_gsm {
    my ($text, $sec_name) = @_;
    my @arts;
    my $seq = 0;
    for my $chunk (split /\n(?=\[gsm\]\n)/, $text) {
        next unless $chunk =~ /^\[gsm\]/;
        $seq++;
        my ($year,$month,$day,$time_str,$ts_raw) = (0,0,0,'','');
        if ($chunk =~ /○ (\S+)/) {
            $ts_raw = $1;
            if    ($ts_raw =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):?(\d{2}):?(\d{2})/) {
                ($year,$month,$day,$time_str) = ($1+0,$2+0,$3+0,"$4:$5:$6");
            } elsif ($ts_raw =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):?(\d{2})/) {
                ($year,$month,$day,$time_str) = ($1+0,$2+0,$3+0,"$4:$5");
            }
        }
        my $body = '';
        $body = $1 if $chunk =~ /○ [^\n]+\n+(.*)/s;
        $body =~ s/\s+$//;
        push @arts, {
            type=>'gsm', id=>sprintf("gsm_%06d",$seq), ts_raw=>$ts_raw,
            title=>'', url=>'',
            year=>$year, month=>$month, day=>$day, time_str=>$time_str,
            tags=>[], body=>$body, trackbacks=>[], section=>$sec_name,
            html_path=>'',
        };
    }
    return @arts;
}

# ============================================================
# HTML 生成
# ============================================================

sub gen_article_html {
    my ($art, $out_dir, $img_dir) = @_;
    # html_path はパス1で確定済み
    my $rel_path  = $art->{html_path};
    my $full_path = "$out_dir/$rel_path";
    make_path(dirname($full_path));
    my $depth = ($rel_path =~ tr|/||);
    my $root  = '../' x $depth;

    open(my $out, '>:encoding(UTF-8)', $full_path)
        or do { warn "Cannot write $full_path: $!"; return '' };
    print $out html_article($art, $root, $img_dir);
    close($out);
    return $full_path;
}

sub html_article {
    my ($art, $root, $img_dir) = @_;
    my $type       = $art->{type};
    my $title      = $art->{title} || '';
    my $url        = $art->{url}   || '';
    my $body       = $art->{body}  || '';
    my $section    = $art->{section} || '';
    my $disp_title = art_display_title($art);

    # --- ID (Pagefind span) ---
    my ($id_str, $id_cell) = ('', '');
    if ($art->{cocolog_id}) {
        $id_str  = "cocolog:$art->{cocolog_id}";
        $id_cell = qq(<span class="cocolog-id">cocolog:$art->{cocolog_id}</span>);
    } elsif ($art->{aboutme_id}) {
        $id_str  = "aboutme:$art->{aboutme_id}";
        $id_cell = qq(<span class="cocolog-id">aboutme:$art->{aboutme_id}</span>);
    } elsif ($art->{ts_raw}) {
        $id_str = $art->{ts_raw};
        $id_cell = h($art->{ts_raw});
    }

    # --- タグ（個別タグページへのリンク）---
    my $tags_html = join(' ', map {
        my $t = $_;
        sprintf('<a href="%sindex/tag/%s.html" class="tag-link">[%s]</a>',
                $root, tag_to_filename($t), h($t))
    } @{ $art->{tags} });

    # --- 日付（月別インデックスへリンク）---
    my $date_str = date_str($art);
    my $date_html = ($art->{year} && $art->{month})
        ? sprintf('<a href="%sindex/%04d/%02d.html">%s</a>',
                  $root, $art->{year}, $art->{month}, h($date_str))
        : h($date_str);

    # --- 元URL（常に元記事への外部リンク。内部リンクには変えない）---
    my $url_cell = $url
        ? sprintf('<a href="%s" class="ext-link"><span class="original-url">%s</span></a>', h($url), h($url))
        : '(URLなし)';

    # --- ナビ ---
    my $month_link = '';
    if ($art->{year} && $art->{month}) {
        $month_link = sprintf ' | <a href="%sindex/%04d/%02d.html">%04d年%02d月</a>',
            $root, $art->{year}, $art->{month}, $art->{year}, $art->{month};
    }
    my $type_link = sprintf ' | <a href="%sindex/%s.html">%s</a>',
        $root, $type, h(label_for_type($type));

    # --- 本文 ---
    my $body_html = body_to_html($body, $root, $img_dir);

    # --- Trackback（折りたたみ廃止・直出し）---
    my $tb_html = '';
    if ($art->{trackbacks} && @{ $art->{trackbacks} }) {
        $tb_html .= "\nTrackbacks:\n\n";
        for my $tb (@{ $art->{trackbacks} }) {
            $tb_html .= sprintf '《<a href="%s">%s</a>》 from %s'."\n",
                h($tb->{url}), h($tb->{title}), h($tb->{from});
            $tb_html .= h($tb->{excerpt})."\n" if $tb->{excerpt};
            $tb_html .= "\n";
        }
    }

    # --- 前後記事リンク ---
    my $prevnext_html = '';
    {
        my $prev = $art->{prev_art};
        my $next = $art->{next_art};
        if ($prev || $next) {
            $prevnext_html = qq(<nav class="prevnext" data-pagefind-ignore>);
            if ($prev) {
                my $ph   = $prev->{html_path} ? "${root}$prev->{html_path}" : '#';
                my $ptit = art_display_title($prev);
                $prevnext_html .= sprintf qq(<span class="prev-art">← <a href="%s">%s</a> <span class="pn-date">%s</span></span>),
                    h($ph), h($ptit), h(date_str($prev));
            }
            if ($next) {
                my $nh   = $next->{html_path} ? "${root}$next->{html_path}" : '#';
                my $ntit = art_display_title($next);
                $prevnext_html .= sprintf qq(<span class="next-art"><a href="%s">%s</a> <span class="pn-date">%s</span> →</span>),
                    h($nh), h($ntit), h(date_str($next));
            }
            $prevnext_html .= "</nav>\n";
        }
    }

    # --- 後方参照 ---
    my $backref_html = build_backref_html($art, $root);

    return <<"HTML";
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>${\h($disp_title)} - JRF Blog Archive</title>
<link rel="stylesheet" href="${root}style.css">
</head>
<body>
<nav><a href="${root}index.html">TOP</a>$month_link$type_link</nav>
<article data-pagefind-body>
<div class="meta">
<table class="meta-table">
<tr><th>種別</th><td>[$type]${\ ($id_cell ? " $id_cell" : '')}</td></tr>
<tr><th>セクション</th><td>${\h($section)}</td></tr>
<tr><th>日時</th><td>$date_html</td></tr>
<tr><th>元URL</th><td>$url_cell</td></tr>
${\ ($tags_html ? "<tr><th>タグ</th><td>$tags_html</td></tr>" : '')}
</table>
</div>
<h1>${\h($disp_title)}</h1>
<pre class="body">$body_html</pre>
${\($tb_html ? "<pre class=\"trackbacks\">$tb_html</pre>" : '')}
$backref_html
</article>
$prevnext_html
<nav class="bottom" data-pagefind-ignore><a href="${root}index.html">TOP</a>$month_link$type_link</nav>
</body>
</html>
HTML
}

sub build_backref_html {
    my ($art, $root) = @_;
    my @found;
    my %seen;

    my @keys;
    push @keys, ["cocolog:$art->{cocolog_id}", "[cocolog:$art->{cocolog_id}]参照"]
        if $art->{cocolog_id};
    push @keys, ["aboutme:$art->{aboutme_id}", "[aboutme:$art->{aboutme_id}]参照"]
        if $art->{aboutme_id};
    push @keys, ["url:$art->{url}", "URL参照"]
        if $art->{url};

    for my $kv (@keys) {
        my ($key, $label) = @$kv;
        for my $ref (@{ $back_refs{$key} // [] }) {
            next if $seen{ $ref->{id} }++;
            next if $ref->{id} eq $art->{id};
            push @found, { art=>$ref, label=>$label };
        }
    }
    return '' unless @found;

    # 日付の新しい順にソート
    @found = sort {
        ($b->{art}{year}||0)  <=> ($a->{art}{year}||0)
        || ($b->{art}{month}||0) <=> ($a->{art}{month}||0)
        || ($b->{art}{day}||0)   <=> ($a->{art}{day}||0)
    } @found;

    my $html = qq(\n<section class="backrefs" data-pagefind-ignore>\n)
             . qq(<h2>後方参照 (${\scalar @found} 件)</h2>\n<ul>\n);
    for my $item (@found) {
        my $ref   = $item->{art};
        my $href  = $ref->{html_path} ? "${root}$ref->{html_path}" : '#';
        my $title = art_display_title($ref);
        $html .= sprintf qq(<li><span class="backref-label">%s</span> <a href="%s">%s</a> <span class="backref-date">%s</span></li>\n),
            h($item->{label}), h($href), h($title), h(date_str($ref));
    }
    $html .= "</ul>\n</section>\n";
    return $html;
}

sub body_to_html {
    my ($body, $root, $img_dir) = @_;

    # [image:...] を退避
    my @images;
    $body =~ s/\[image:([^:]*):([^\]]*)\]/
        push @images, {alt=>$1, url=>$2};
        "\x00IMG".$#images."\x00"
    /ge;

    # [cocolog:NNN] / [aboutme:NNN] を退避
    my @idrefs;
    $body =~ s/\[(cocolog|aboutme):(\d+)\]/
        push @idrefs, {type=>$1, num=>$2};
        "\x00IDREF".$#idrefs."\x00"
    /ge;

    # >>TIMESTAMP を退避
    my @tsrefs;
    $body =~ s/>>(\s*)(\d{4}-\d{2}-\d{2}T[\d:]+Z)/
        push @tsrefs, {space=>$1, ts=>$2};
        "\x00TSREF".$#tsrefs."\x00"
    /ge;

    # [google:クエリ] / [wikipedia:項目名] を退避
    my @extrefs;
    $body =~ s/\[(google|wikipedia):[ \t]*([^\]]+)\]/
        my ($svc, $q) = ($1, $2); $q =~ s!\s+$!!;
        push @extrefs, {svc=>$svc, q=>$q};
        "\x00EXTREF".$#extrefs."\x00"
    /ge;

    # keyword: キーワード（行頭）を退避
    my @kw_list;
    $body =~ s/^keyword:[ \t]*([^\n\]]+)/
        my $kw = $1; $kw =~ s!\s+$!!;
        push @kw_list, $kw;
        "\x00KW".($#kw_list)."\x00"
    /gme;

    # HTMLエスケープ
    $body = h($body);

    # URL リンク化（内部/外部判定）
    $body =~ s{(https?://[^\s<>"]+)}{url_to_link_escaped($1, $root)}ge;

    # [cocolog:NNN] / [aboutme:NNN] プレースホルダを内部リンクに変換
    $body =~ s/\x00IDREF(\d+)\x00/idref_to_link($idrefs[$1]{type}, $idrefs[$1]{num}, $root)/ge;

    # >>TIMESTAMP プレースホルダを内部リンクに変換
    $body =~ s/\x00TSREF(\d+)\x00/tsref_to_link($tsrefs[$1]{space}, $tsrefs[$1]{ts}, $root)/ge;

    # [google:] / [wikipedia:] プレースホルダを展開
    $body =~ s/\x00EXTREF(\d+)\x00/extref_to_link($extrefs[$1]{svc}, $extrefs[$1]{q}, $root)/ge;

    # keyword: プレースホルダをリンクに変換
    $body =~ s/\x00KW(\d+)\x00/keyword_to_link($kw_list[$1], $root)/ge;

    # [image:] を戻す
    $body =~ s/\x00IMG(\d+)\x00/image_html($images[$1], $root)/ge;

    return $body;
}

# --- URL→内部/外部リンク（エスケープ済みテキスト中のURL用）---
sub url_to_link_escaped {
    my ($url_esc, $root) = @_;
    # URLはほぼそのままマッチするが念のため & → & に戻す（URLに&ampは出ない）
    my $url = $url_esc;
    $url =~ s/&amp;/&/g;
    $url =~ s/[)\]'".,]+$//;   # 末尾ゴミ除去
    my $url_esc_clean = h($url);

    if (my $art = $url_to_art{$url}) {
        my $path  = $art->{html_path} or return qq(<a href="$url_esc_clean" class="ext-link">$url_esc_clean</a>);
        my $ihref = h($root . $path);
        my $label = h($art->{title} || label_for_type($art->{type}));
        return qq(<a href="$ihref" class="int-link" title="$label">$url_esc_clean</a>);
    }
    return qq(<a href="$url_esc_clean" class="ext-link">$url_esc_clean</a>);
}

# --- URL→内部/外部リンク（生テキスト用、span.original-url オプション）---
sub url_to_link {
    my ($url, $root, $wrap_span) = @_;
    return '' unless $url;
    my $url_h  = h($url);
    my $label  = $wrap_span
        ? qq(<span class="original-url">$url_h</span>)
        : $url_h;

    if (my $art = $url_to_art{$url}) {
        my $path = $art->{html_path} or return qq(<a href="$url_h" class="ext-link">$label</a>);
        my $ihref = h($root . $path);
        my $title = h($art->{title} || label_for_type($art->{type}));
        return qq(<a href="$ihref" class="int-link" title="$title">$label</a>);
    }
    return qq(<a href="$url_h" class="ext-link">$label</a>);
}

# --- [cocolog:NNN] / [aboutme:NNN] → 内部リンク ---
sub idref_to_link {
    my ($type, $num, $root) = @_;
    my $tag_h = h("[$type:$num]");
    my $art = ($type eq 'cocolog') ? $cocolog_to_art{$num} : $aboutme_to_art{$num};
    unless ($art && $art->{html_path}) {
        return qq(<span class="cocolog-id">$tag_h</span>);
    }
    my $ihref = h($root . $art->{html_path});
    my $title = h($art->{title} || label_for_type($art->{type}));
    return qq(<a href="$ihref" class="int-link cocolog-id" title="$title">$tag_h</a>);
}

# --- [google:クエリ] / [wikipedia:項目名] → 外部リンク ---
sub extref_to_link {
    my ($svc, $q, $root) = @_;
    my $q_h = h($q);
    if ($svc eq 'google') {
        my $q_enc = $q;
        utf8::encode($q_enc);
        $q_enc =~ s/([^A-Za-z0-9_\-.])/sprintf('%%%02X',ord($1))/ge;
        my $url = "https://www.google.com/search?q=$q_enc";
        return qq(<span class="extref-google">\[google: <a href="$url" class="ext-link" target="_blank" rel="noopener">$q_h</a>\]</span>);
    } elsif ($svc eq 'wikipedia') {
        my $q_enc = $q; $q_enc =~ s/ /_/g;
        utf8::encode($q_enc);
        $q_enc =~ s/([^A-Za-z0-9_\-])/sprintf('%%%02X',ord($1))/ge;
        my $url = "https://ja.wikipedia.org/wiki/$q_enc";
        return qq(<span class="extref-wiki">\[wikipedia: <a href="$url" class="ext-link" target="_blank" rel="noopener">$q_h</a>\]</span>);
    }
    return h("[$svc:$q]");
}

# --- keyword: キーワード → search.html?q= リンク ---
sub keyword_to_link {
    my ($kw, $root) = @_;
    my $kw_h   = h($kw);
    my $kw_enc = $kw;
    utf8::encode($kw_enc);
    $kw_enc =~ s/([^A-Za-z0-9_\-.])/sprintf('%%%02X',ord($1))/ge;
    my $search_url = h($root . "search.html?q=$kw_enc");
    return qq(<span class="keyword-ref">keyword: <a href="$search_url" class="keyword-link">$kw_h</a></span>);
}

# --- タグ名をファイル名に変換（連番ID方式、日本語でも安全）---
sub tag_to_filename {
    my ($tag) = @_;
    return $tag_id{$tag} // do {
        # 万一テーブルにない場合はASCII安全なフォールバック
        my $enc = $tag;
        utf8::encode($enc);
        $enc =~ s/([^A-Za-z0-9_\-])/sprintf('_%02X', ord($1))/ge;
        $enc;
    };
}

# --- >>TIMESTAMP → gsm 記事への内部リンク ---
sub tsref_to_link {
    my ($space, $ts, $root) = @_;
    my $ts_h  = h($ts);
    my $tag_h = ">>" . h($space) . $ts_h;  # >> そのままHTMLに
    my $nts   = normalize_gsm_ts($ts);
    my $art   = $nts ? $gsm_ts_to_art{$nts} : undef;
    unless ($art && $art->{html_path}) {
        # マッチしない場合はspanだけ付けてそのまま表示
        return qq(<span class="gsm-tsref">$tag_h</span>);
    }
    my $ihref = h($root . $art->{html_path});
    # タイトルは本文冒頭20文字
    my $preview = substr($art->{body} // '', 0, 40);
    $preview =~ s/\s+/ /g;
    my $title = h($preview || '共有メモ');
    return qq(<a href="$ihref" class="int-link gsm-tsref" title="$title">>>${\h($space)}$ts_h</a>);
}

# --- gsmタイムスタンプを正規形式 YYYY-MM-DDTHH:MM:SSZ に正規化 ---
sub normalize_gsm_ts {
    my ($ts) = @_;
    # 正規: 2026-03-07T09:36:01Z
    return $ts if $ts =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
    # T後の数字列が6桁(HHMMSS): 2020-05-17T111633Z → 2020-05-17T11:16:33Z
    if ($ts =~ /^(\d{4}-\d{2}-\d{2})T(\d{2})(\d{2})(\d{2})Z$/) {
        return "$1T$2:$3:$4Z";
    }
    # T後 HH:MMSS (コロン混在): 2020-05-17T11:1633Z → 2020-05-17T11:16:33Z
    if ($ts =~ /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})(\d{2})Z$/) {
        return "$1T$2:$3:$4Z";
    }
    # T後4桁(HHMM): 2020-05-17T1116Z → 2020-05-17T11:16:00Z
    if ($ts =~ /^(\d{4}-\d{2}-\d{2})T(\d{2})(\d{2})Z$/) {
        return "$1T$2:$3:00Z";
    }
    return '';  # 解釈不能
}

sub image_html {
    my ($img, $root) = @_;
    my $alt     = h($img->{alt});
    my $url     = $img->{url};
    my $fn      = basename($url);
    my $full_fn = ($fn =~ /^thumbnail-(.+)$/) ? $1 : '';
    my ($ts, $fs) = ('', '');
    $ts = "${root}images/$fn"      if $img_exists{$fn};
    $fs = "${root}images/$full_fn" if $full_fn && $img_exists{$full_fn};
    return $ts && $fs
        # サムネイル→フル: a タグに thumb-link クラス → CSS で枠
        ? qq(<a href="$fs" class="thumb-link"><img src="$ts" alt="$alt" class="thumb"></a>)
        # サムネイルのみ: 枠なし
        : $ts
        ? qq(<img src="$ts" alt="$alt" class="thumb-plain">)
        # ローカルなし: テキストリンク
        : qq(<a href=") . h($url) . qq(">[$alt]</a>);
}

# ============================================================
# インデックス生成
# ============================================================

sub gen_month_index {
    my ($ym, $arts_ref, $out_dir) = @_;
    my ($year, $month) = split '/', $ym;
    my $path = "$out_dir/index/$ym.html";
    make_path(dirname($path));
    my @sorted = sort {
        ($a->{day}||0)      <=> ($b->{day}||0)
        || ($a->{time_str}||'') cmp ($b->{time_str}||'')
        || ($a->{ts_raw}||'')   cmp ($b->{ts_raw}||'')
    } @$arts_ref;
    open(my $out, '>:encoding(UTF-8)', $path) or return;
    my $root = '../../';
    print $out <<"HTML";
<!DOCTYPE html>
<html lang="ja">
<head><meta charset="UTF-8"><title>${year}年${month}月 - JRF Blog Archive</title>
<link rel="stylesheet" href="${root}style.css"></head>
<body>
<nav><a href="${root}index.html">TOP</a></nav>
<h1>${year}年${month}月の記事 (${\scalar @sorted} 件)</h1>
<ul class="month-index">
HTML
    for my $art (@sorted) {
        my $title = art_display_title($art);
        my $href  = $art->{html_path} ? "${root}$art->{html_path}" : '#';
        my $date  = date_str($art);
        my $id_d  = $art->{cocolog_id} ? " [cocolog:$art->{cocolog_id}]"
                  : $art->{aboutme_id} ? " [aboutme:$art->{aboutme_id}]"
                  : '';   # gsm は date_str が ts_raw を兼ねるので省略
        my $tags  = @{$art->{tags}} ? ' '.join(' ',map{"[$_]"}@{$art->{tags}}) : '';
        my $badge = type_badge($art->{type});
        printf $out qq(<li>%s<a href="%s">%s</a>%s %s%s</li>\n),
            $badge, h($href), h($title), h($id_d), h($date), h($tags);
    }
    print $out "</ul>\n<nav class=\"bottom\"><a href=\"${root}index.html\">TOP</a></nav>\n</body></html>\n";
    close($out);
}

sub gen_type_index {
    my ($type, $arts_ref, $out_dir) = @_;
    my $path = "$out_dir/index/${type}.html";
    make_path(dirname($path));
    my @sorted = sort {
        ($b->{year}||0)     <=> ($a->{year}||0)
        || ($b->{month}||0) <=> ($a->{month}||0)
        || ($b->{day}||0)   <=> ($a->{day}||0)
        || ($b->{time_str}||'') cmp ($a->{time_str}||'')
        || ($b->{ts_raw}||'')   cmp ($a->{ts_raw}||'')
    } @$arts_ref;
    open(my $out, '>:encoding(UTF-8)', $path) or return;
    my $root  = '../';
    my $label = label_for_type($type);
    my $total = scalar @sorted;
    # gsm/statuses は月ごとに <details> 折りたたみ
    my $use_details = ($type eq 'gsm' || $type eq 'statuses') ? 1 : 0;

    print $out <<"HTML";
<!DOCTYPE html>
<html lang="ja">
<head><meta charset="UTF-8"><title>${\h($label)} - JRF Blog Archive</title>
<link rel="stylesheet" href="${root}style.css"></head>
<body>
<nav><a href="${root}index.html">TOP</a></nav>
<h1>${\h($label)} (${total} 件)</h1>
HTML
    if ($use_details) {
        my %by_ym;
        for my $art (@sorted) {
            my $ym = ($art->{year} && $art->{month})
                ? sprintf("%04d/%02d", $art->{year}, $art->{month}) : 'undated';
            push @{ $by_ym{$ym} }, $art;
        }
        for my $ym (sort { $b cmp $a } keys %by_ym) {
            my @ms = @{ $by_ym{$ym} };
            my ($y,$m) = $ym eq 'undated' ? ('?','?') : split '/', $ym;
            my $mp = $ym ne 'undated' ? "${root}index/${ym}.html" : '#';
            printf $out qq(<details class="month-block">\n<summary><a href="%s">%s年%s月</a> (%d件)</summary>\n<ul class="month-index">\n),
                $mp, $y, $m, scalar @ms;
            for my $art (@ms) {
                my $title = art_display_title($art);
                my $href  = $art->{html_path} ? "${root}$art->{html_path}" : '#';
                my $id_d  = $art->{cocolog_id} ? " [cocolog:$art->{cocolog_id}]"
                          : $art->{aboutme_id} ? " [aboutme:$art->{aboutme_id}]"
                          : '';
                my $date  = date_str($art);
                printf $out qq(<li><a href="%s">%s</a>%s %s</li>\n),
                    h($href), h($title), h($id_d), h($date);
            }
            print $out "</ul>\n</details>\n";
        }
    } else {
        print $out qq(<ul class="month-index">\n);
        my $prev_ym = '';
        for my $art (@sorted) {
            if ($art->{year} && $art->{month}) {
                my $ym = sprintf "%04d/%02d", $art->{year}, $art->{month};
                if ($ym ne $prev_ym) {
                    printf $out qq(<li class="year-header"><a href="%sindex/%s.html">%d年%d月</a></li>\n),
                        $root, $ym, $art->{year}, $art->{month};
                    $prev_ym = $ym;
                }
            }
            my $title = art_display_title($art);
            my $href  = $art->{html_path} ? "${root}$art->{html_path}" : '#';
            my $id_d  = $art->{cocolog_id} ? " [cocolog:$art->{cocolog_id}]"
                      : $art->{aboutme_id} ? " [aboutme:$art->{aboutme_id}]" : '';
            my $tags  = @{$art->{tags}} ? ' '.join(' ',map{"[$_]"}@{$art->{tags}}) : '';
            my $badge = type_badge($art->{type});
            printf $out qq(<li>%s<a href="%s">%s</a>%s %s%s</li>\n),
                $badge, h($href), h($title), h($id_d), h(date_str($art)), h($tags);
        }
        print $out "</ul>\n";
    }
    print $out "<nav class=\"bottom\"><a href=\"${root}index.html\">TOP</a></nav>\n</body></html>\n";
    close($out);
    printf STDERR "  タイプ別: %s (%d件)\n", $type, $total;
}

sub gen_tag_index {
    my ($tag_index, $out_dir) = @_;
    my $path = "$out_dir/index/tags.html";
    make_path(dirname($path));
    open(my $out, '>:encoding(UTF-8)', $path) or return;
    my $root = '../';
    my @tags = sort { scalar(@{$tag_index->{$b}}) <=> scalar(@{$tag_index->{$a}}) || $a cmp $b }
               keys %$tag_index;
    print $out <<"HTML";
<!DOCTYPE html>
<html lang="ja">
<head><meta charset="UTF-8"><title>タグ一覧 - JRF ブログ退避所</title>
<link rel="stylesheet" href="${root}style.css"></head>
<body>
<nav><a href="${root}index.html">TOP</a></nav>
<h1>タグ一覧 (${\scalar @tags} 種)</h1>
<ul class="tag-cloud">
HTML
    for my $tag (@tags) {
        my $cnt  = scalar @{ $tag_index->{$tag} };
        my $fn   = tag_to_filename($tag);
        my @arts = sort {
            ($b->{year}||0) <=> ($a->{year}||0) || ($b->{month}||0) <=> ($a->{month}||0)
        } @{ $tag_index->{$tag} };
        my $size = $cnt>=50 ? 'xl' : $cnt>=20 ? 'lg' : $cnt>=5 ? 'md' : 'sm';
        # summary はタグ個別ページへのリンク＋件数
        printf $out qq(<li class="tag-%s"><details class="tag-details">).
                    qq(<summary><a href="%sindex/tag/%s.html" class="tag-page-link">[%s]</a>（%d件）</summary><ul>\n),
            $size, $root, $fn, h($tag), $cnt;
        for my $art (@arts) {
            my $title = art_display_title($art);
            my $href  = $art->{html_path} ? "${root}$art->{html_path}" : '#';
            my $badge = type_badge($art->{type});
            printf $out qq(<li>%s<a href="%s">%s</a> %s</li>\n),
                $badge, h($href), h($title), h(date_str($art));
        }
        print $out "</ul></details></li>\n";
    }
    print $out <<'HTML';
</ul>
<nav class="bottom"><a href="../index.html">TOP</a></nav>
<script>
// アコーディオン: 1つ開いたら他を閉じる
document.querySelectorAll('details.tag-details').forEach(function(d) {
  d.addEventListener('toggle', function() {
    if (d.open) {
      document.querySelectorAll('details.tag-details').forEach(function(other) {
        if (other !== d) other.open = false;
      });
    }
  });
});
</script>
</body></html>
HTML
    close($out);
    printf STDERR "タグ一覧: %d種\n", scalar @tags;
}

sub gen_tag_pages {
    my ($tag_index, $out_dir) = @_;
    my $dir = "$out_dir/index/tag";
    make_path($dir);
    my $root = '../../';  # index/tag/XXX.html -> docs/
    my $count = 0;
    for my $tag (keys %$tag_index) {
        my $fn   = tag_to_filename($tag);
        my $path = "$dir/$fn.html";
        my @arts = sort {
            ($b->{year}||0) <=> ($a->{year}||0) || ($b->{month}||0) <=> ($a->{month}||0)
            || ($b->{day}||0) <=> ($a->{day}||0)
        } @{ $tag_index->{$tag} };
        open(my $out, '>:encoding(UTF-8)', $path) or next;
        my $tag_h = h($tag);
        my $cnt   = scalar @arts;
        print $out <<"HTML";
<!DOCTYPE html>
<html lang="ja">
<head><meta charset="UTF-8"><title>[$tag_h] - JRF Blog Archive</title>
<link rel="stylesheet" href="${root}style.css"></head>
<body>
<nav><a href="${root}index.html">TOP</a> | <a href="${root}index/tags.html">タグ一覧</a></nav>
<h1>[$tag_h] (${cnt}件)</h1>
<ul class="month-index">
HTML
        my $prev_ym = '';
        for my $art (@arts) {
            if ($art->{year} && $art->{month}) {
                my $ym = sprintf "%04d/%02d", $art->{year}, $art->{month};
                if ($ym ne $prev_ym) {
                    my $mp = sprintf "${root}index/%s.html", $ym;
                    printf $out qq(<li class="year-header"><a href="%s">%d年%d月</a></li>\n),
                        $mp, $art->{year}, $art->{month};
                    $prev_ym = $ym;
                }
            }
            my $title = art_display_title($art);
            my $href  = $art->{html_path} ? "${root}$art->{html_path}" : '#';
            my $badge = type_badge($art->{type});
            printf $out qq(<li>%s<a href="%s">%s</a> %s</li>\n),
                $badge, h($href), h($title), h(date_str($art));
        }
        print $out "</ul>\n<nav class=\"bottom\"><a href=\"${root}index.html\">TOP</a> | <a href=\"${root}index/tags.html\">タグ一覧</a></nav>\n</body></html>\n";
        close($out);
        $count++;
    }
    printf STDERR "タグ個別ページ: %d件\n", $count;
}

sub gen_top_index {
    my ($month_index, $type_index, $tag_index, $out_dir) = @_;
    my $path = "$out_dir/index.html";
    make_path($out_dir);
    open(my $out, '>:encoding(UTF-8)', $path) or return;
    my @yms = sort { $b cmp $a } keys %$month_index;
    my @type_order = qw(column religion society software pr statuses hbm gsm);
    my $type_links = join(' &nbsp;|&nbsp; ', map {
        my $t = $_; my $cnt = scalar @{ $type_index->{$t} // [] };
        $cnt ? sprintf('<a href="index/%s.html">%s</a>（%d件）',$t,h(label_for_type($t)),$cnt) : ()
    } @type_order);
    my $tag_cnt = scalar keys %$tag_index;
    print $out <<"HTML";
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>JRF ブログ退避所</title>
<link rel="stylesheet" href="style.css">
<link href="pagefind/pagefind-ui.css" rel="stylesheet">
</head>
<body>
<div class="site-header">
<a href="https://github.com/JRF-2018" class="gh-icon-link">
<img src="https://github.com/JRF-2018.png" alt="JRF-2018 on GitHub" class="gh-icon">
</a>
<h1>JRF ブログ退避所</h1>
</div>
<p class="site-desc">ここは JRF のブログ等を検索するためのサイトです。
元のブログは <a href="http://jrf.cocolog-nifty.com/">http://jrf.cocolog-nifty.com/</a> にあります。
共有メモは <a href="http://jrockford.s1010.xrea.com/demo/shared_memo.cgi?cmd=log">http://jrockford.s1010.xrea.com/demo/shared_memo.cgi?cmd=log</a> にあります。
ブックマークは <a href="https://b.hatena.ne.jp/jrf/">https://b.hatena.ne.jp/jrf/</a> にあります。
GitHub は <a href="https://github.com/JRF-2018">https://github.com/JRF-2018</a> です。</p>

<div class="search-box" id="search-box">
<div id="search"></div>
</div>

<p class="type-links">$type_links &nbsp;|&nbsp; <a href="index/tags.html">タグ一覧（${tag_cnt}種）</a></p>
<p>月別インデックス (${\scalar @yms} ヶ月分)</p>
<ul class="top-index">
HTML
    my $prev_year = '';
    for my $ym (@yms) {
        my ($year,$month) = split '/', $ym;
        if ($year ne $prev_year) { print $out qq(<li class="year-header">$year 年</li>\n); $prev_year=$year }
        printf $out qq(<li><a href="index/%s.html">%d年%d月</a>（%d件）</li>\n),
            $ym, $year, $month, scalar @{ $month_index->{$ym} };
    }
    print $out <<"HTML";
</ul>
<hr>
<p><small>このアーカイブは <a href="https://github.com/JRF-2018/jrf_blog_find">jrf_blog_find</a> により自動生成。</small></p>
<script src="pagefind/pagefind-ui.js"></script>
<script>
if (typeof PagefindUI !== 'undefined') {
  new PagefindUI({
    element: "#search",
    showSubResults: true,
    resetStyles: false,
    translations: {
      placeholder: "検索 (例: cocolog:9644812、aboutme:4032、URL の一部など)",
      zero_results: "「[SEARCH_TERM]」に一致する記事がありません。"
    }
  });
} else {
  document.getElementById('search').innerHTML =
    '<p style="color:#888;font-size:.9em">（検索インデックス未生成。GitHub Actions 実行後に利用可能になります。）</p>';
}
</script>
</body></html>
HTML
    close($out);

    # search.html: URLパラメータ ?q= 対応の独立検索ページ
    my $spath = "$out_dir/search.html";
    open(my $sout, '>:encoding(UTF-8)', $spath) or return;
    print $sout <<'HTML';
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>検索 - JRF Blog Archive</title>
<link rel="stylesheet" href="style.css">
<link href="pagefind/pagefind-ui.css" rel="stylesheet">
</head>
<body>
<nav><a href="index.html">TOP</a></nav>
<h1>検索</h1>
<div class="search-box"><div id="search"></div></div>
<script src="pagefind/pagefind-ui.js"></script>
<script>
var pfUI;
if (typeof PagefindUI !== 'undefined') {
  pfUI = new PagefindUI({
    element: "#search",
    showSubResults: true,
    resetStyles: false,
    translations: {
      placeholder: "検索 (例: cocolog:9644812、keyword、URL の一部など)",
      zero_results: "「[SEARCH_TERM]」に一致する記事がありません。"
    }
  });
  // URLパラメータ ?q=xxx から検索語を取得して即検索
  var params = new URLSearchParams(location.search);
  var q = params.get('q');
  if (q) {
    pfUI.triggerSearch(q);
  }
} else {
  document.getElementById('search').innerHTML =
    '<p style="color:#888">（検索インデックス未生成。GitHub Actions 実行後に利用可能です。）</p>';
}
</script>
</body>
</html>
HTML
    close($sout);
}

sub gen_blogparts {
    my ($out_dir) = @_;
    my $path = "$out_dir/blogparts.html";
    open(my $out, '>:encoding(UTF-8)', $path) or return;
    # ブログのサイドバーに貼り付けるためのサイト内検索パーツ
    print $out <<'HTML';
<!DOCTYPE html>
<html lang="ja">
<head><meta charset="UTF-8"><title>ブログパーツ - JRF ブログ退避所</title>
<style>
body { font-family: sans-serif; font-size:14px; padding:1em; }
pre { background:#f5f5f5; border:1px solid #ddd; padding:.5em; overflow-x:auto; font-size:12px; }
</style></head>
<body>
<h1>サイト内検索ブログパーツ</h1>
<p>以下のコードをブログのサイドバーに貼り付けると、JRF ブログ退避所の記事を検索できます。</p>

<h2>シンプル版（推奨）</h2>
<pre id="code-simple"></pre>

<h2>横並びコンパクト版</h2>
<pre id="code-compact"></pre>

<script>
var BASE = 'https://jrf-2018.github.io/jrf_blog_find/';

var simple = [
  '<form action="' + BASE + 'search.html" method="get" target="_blank">',
  '  <div style="border:1px solid #ccc; border-radius:4px; padding:6px 8px; background:#f8f8ff; display:inline-block;">',
  '    <div style="font-size:11px; color:#666; margin-bottom:4px;">JRF ブログ退避所 検索</div>',
  '    <input type="text" name="q" placeholder="キーワードを入力" style="width:180px; padding:4px 6px; border:1px solid #aaa; border-radius:3px; font-size:13px;">',
  '    <button type="submit" style="padding:4px 10px; background:#007744; color:#fff; border:none; border-radius:3px; cursor:pointer; font-size:13px;">検索</button>',
  '  </div>',
  '</form>'
].join('\n');

var compact = [
  '<form action="' + BASE + 'search.html" method="get" target="_blank" style="display:flex; gap:4px; align-items:center;">',
  '  <input type="text" name="q" placeholder="JRF ブログ退避所を検索" style="flex:1; padding:4px 6px; border:1px solid #aaa; border-radius:3px; font-size:13px; min-width:120px;">',
  '  <button type="submit" style="padding:4px 8px; background:#007744; color:#fff; border:none; border-radius:3px; cursor:pointer; font-size:13px;">検索</button>',
  '</form>'
].join('\n');

document.getElementById('code-simple').textContent = simple;
document.getElementById('code-compact').textContent = compact;
</script>

<h2>プレビュー</h2>
<h3>シンプル版</h3>
<form action="https://jrf-2018.github.io/jrf_blog_find/search.html" method="get" target="_blank">
  <div style="border:1px solid #ccc; border-radius:4px; padding:6px 8px; background:#f8f8ff; display:inline-block;">
    <div style="font-size:11px; color:#666; margin-bottom:4px;">JRF ブログ退避所 検索</div>
    <input type="text" name="q" placeholder="キーワードを入力" style="width:180px; padding:4px 6px; border:1px solid #aaa; border-radius:3px; font-size:13px;">
    <button type="submit" style="padding:4px 10px; background:#007744; color:#fff; border:none; border-radius:3px; cursor:pointer; font-size:13px;">検索</button>
  </div>
</form>

<h3>横並びコンパクト版</h3>
<form action="https://jrf-2018.github.io/jrf_blog_find/search.html" method="get" target="_blank" style="display:flex; gap:4px; align-items:center; max-width:300px;">
  <input type="text" name="q" placeholder="JRF ブログ退避所を検索" style="flex:1; padding:4px 6px; border:1px solid #aaa; border-radius:3px; font-size:13px;">
  <button type="submit" style="padding:4px 8px; background:#007744; color:#fff; border:none; border-radius:3px; cursor:pointer; font-size:13px;">検索</button>
</form>
</body></html>
HTML
    close($out);
    print STDERR "ブログパーツ: blogparts.html\n";
}

sub gen_css {
    my ($out_dir) = @_;
    open(my $out, '>:encoding(UTF-8)', "$out_dir/style.css") or return;
    print $out <<'CSS';
/* JRF Blog Archive */
body { font-family:'Noto Sans JP','Hiragino Kaku Gothic ProN',Meiryo,sans-serif;
  font-size:15px; line-height:1.7; max-width:920px; margin:0 auto;
  padding:1em 1.5em; color:#222; background:#fafafa; }
nav { margin:.4em 0 .8em; font-size:.9em; }
nav a { margin-right:.8em; }
h1 { font-size:1.3em; border-bottom:1px solid #ccc; padding-bottom:.3em; }
h2 { font-size:1.1em; margin-top:1.5em; border-left:3px solid #888; padding-left:.5em; }
/* サイトヘッダー */
div.site-header { display:flex; align-items:center; gap:.8em; margin-bottom:.3em; }
div.site-header h1 { border:none; margin:0; padding:0; }
a.gh-icon-link { flex-shrink:0; }
img.gh-icon { width:48px; height:48px; border-radius:50%; border:2px solid #ccc; display:block; }
/* 説明文 */
p.site-desc { font-size:.88em; color:#555; background:#f5f5f5;
  border-left:3px solid #bbb; padding:.5em .8em; margin:.5em 0 1em; line-height:1.6; }
/* 検索ボックス */
div.search-box { margin:1em 0 1.5em; padding:1em 1.2em;
  background:#f0f4ff; border:1px solid #c0d0ee; border-radius:6px; }
.pagefind-ui__search-input { font-family:inherit; font-size:1em; }
.pagefind-ui__result-title a { color:#007744; }
.pagefind-ui__result-excerpt mark { background:#ffe080; color:#222; border-radius:2px; }
/* meta テーブル */
div.meta { margin-bottom:.8em; }
table.meta-table { border-collapse:collapse; font-size:.85em; width:100%; }
table.meta-table th { background:#eee; padding:.2em .6em; text-align:left;
  white-space:nowrap; border:1px solid #ccc; width:5em; vertical-align:top; }
table.meta-table td { padding:.2em .6em; border:1px solid #ccc; word-break:break-all; }
/* 本文 */
pre.body { background:#fff; border:1px solid #ddd; padding:1em;
  white-space:pre-wrap; word-break:break-all; line-height:1.8; margin:0; }
/* Trackback */
pre.trackbacks { background:#f8f8f8; border:1px dashed #bbb; margin-top:.5em;
  padding:.5em 1em; white-space:pre-wrap; word-break:break-all; font-size:.9em; }
/* 後方参照 */
section.backrefs { margin-top:1.2em; padding:.6em 1em;
  background:#f0f4ff; border:1px solid #c0d0ee; border-radius:4px; }
section.backrefs h2 { margin-top:.3em; font-size:1em; border-left:3px solid #88a; }
section.backrefs ul { list-style:none; padding:0; margin:.3em 0 0; }
section.backrefs li { padding:.25em 0; border-bottom:1px solid #d8e4f4; font-size:.9em; }
section.backrefs li:last-child { border-bottom:none; }
.backref-label { font-size:.78em; color:#446; background:#dde;
  padding:.1em .35em; border-radius:3px; margin-right:.4em; white-space:nowrap; }
.backref-date  { font-size:.78em; color:#888; margin-left:.4em; }
/* 前後記事ナビ */
nav.prevnext { display:flex; justify-content:space-between; flex-wrap:wrap;
  gap:.5em; margin:1em 0 .5em; padding:.6em .8em;
  background:#f8f8f8; border:1px solid #ddd; border-radius:4px; font-size:.88em; }
.prev-art { flex:1; text-align:left; }
.next-art { flex:1; text-align:right; }
.pn-date  { font-size:.85em; color:#888; }
/* ID / URL */
span.cocolog-id { font-family:monospace; background:#eef; padding:.1em .4em;
  border-radius:3px; font-size:.9em; }
span.original-url { word-break:break-all; }
/* 画像: クリック可（サムネイル→フル）は枠・ポインタ */
a.thumb-link { display:inline-block; }
a.thumb-link img.thumb { border:2px solid #aaa; border-radius:3px;
  cursor:pointer; transition:border-color .15s; }
a.thumb-link:hover img.thumb { border-color:#007744; }
/* 画像: 単体（クリック不可）は枠なし */
img.thumb-plain { max-width:300px; max-height:300px; vertical-align:middle; }
img.thumb { max-width:300px; max-height:300px; vertical-align:middle; }
/* タグリンク */
a.tag-link { color:#333; text-decoration:none; font-size:.9em;
  background:#f0f0f8; border:1px solid #c8c8e0; border-radius:3px;
  padding:.05em .3em; margin:.1em; display:inline-block; }
a.tag-link:hover { background:#e0e8ff; border-color:#88a; }
/* keyword リンク */
span.keyword-ref { display:inline-block; background:#fff8e8;
  border:1px solid #e8d890; border-radius:3px; padding:.1em .4em;
  font-size:.9em; margin:.1em 0; }
a.keyword-link { color:#885500; font-weight:500; }
a.keyword-link:hover { color:#cc7700; }
/* サブブログバッジ */
span.type-badge { display:inline-block; font-size:.72em; padding:.05em .35em;
  border-radius:3px; margin-right:.3em; vertical-align:middle;
  white-space:nowrap; font-weight:500; }
.badge-column   { background:#ddeeff; color:#224477; }
.badge-religion { background:#ffe8dd; color:#773322; }
.badge-society  { background:#ddffd8; color:#225522; }
.badge-software { background:#eeddff; color:#442277; }
.badge-pr       { background:#fff0cc; color:#664400; }
.badge-statuses { background:#ffeeff; color:#553355; }
.badge-hbm      { background:#e8f5e9; color:#2e7d32; }
.badge-gsm      { background:#e3f2fd; color:#1565c0; }
.badge-other    { background:#eee;    color:#555; }
/* インデックス共通 */
ul.month-index { list-style:none; padding:0; }
ul.month-index li { border-bottom:1px solid #eee; padding:.25em 0; }
li.year-header { font-weight:bold; margin-top:.8em; color:#555; }
li.year-header a { color:#555; }
ul.top-index { list-style:none; padding:0; }
ul.top-index li { display:inline-block; margin:.2em .4em; }
p.type-links { margin:.5em 0; line-height:2; }
/* タイプ別インデックス: 月折りたたみ */
details.month-block { margin:.3em 0; }
details.month-block > summary { cursor:pointer; font-weight:bold;
  padding:.25em .5em; background:#f0f0f0; border-radius:3px; list-style:none; }
details.month-block > summary::-webkit-details-marker { display:none; }
details.month-block > summary::before { content:"▶ "; font-size:.8em; }
details.month-block[open] > summary::before { content:"▼ "; }
details.month-block > summary:hover { background:#e0e8ff; }
details.month-block > summary a { color:#333; }
/* タグ一覧 */
ul.tag-cloud { list-style:none; padding:0; }
ul.tag-cloud > li { display:inline-block; margin:.2em .3em; vertical-align:middle; position:relative; }
ul.tag-cloud details > summary { cursor:pointer; }
ul.tag-cloud details > summary::-webkit-details-marker { display:none; }
.tag-xl > details > summary { font-size:1.3em; font-weight:bold; }
.tag-lg > details > summary { font-size:1.1em; }
.tag-md > details > summary { font-size:1.0em; }
.tag-sm > details > summary { font-size:.85em; color:#666; }
ul.tag-cloud details ul { list-style:none; padding:.3em 0 .3em 1em; margin:.2em 0 0;
  background:#f8f8ff; border:1px solid #ddf; border-radius:3px; min-width:220px;
  position:absolute; z-index:10; box-shadow:2px 2px 6px rgba(0,0,0,.15); }
/* リンク色 */
a { color:#0066cc; } a:visited { color:#6600cc; }
a.int-link         { color:#007744; font-weight:500; }
a.int-link:visited { color:#005533; }
a.int-link:hover   { color:#00aa55; text-decoration:underline; }
a.int-link.cocolog-id { background:#e8f5ee; padding:.05em .3em; border-radius:3px; }
a.int-link.gsm-tsref  { background:#e8f0ff; padding:.05em .3em; border-radius:3px; }
span.gsm-tsref { background:#f4f4f4; padding:.05em .3em; border-radius:3px; color:#888; }
a.ext-link { color:#0066cc; } a.ext-link:visited { color:#6600cc; }
/* タグリンク（meta欄） */
a.tag-link { color:#333; text-decoration:none; font-size:.9em;
  background:#f0f0f8; border:1px solid #c8c8e0; border-radius:3px;
  padding:.05em .3em; margin:.05em; display:inline-block; }
a.tag-link:hover { background:#e0e8ff; border-color:#88a; }
a.tag-page-link { color:#224; font-weight:500; text-decoration:none; }
a.tag-page-link:hover { text-decoration:underline; }
/* google/wikipedia 外部参照 */
span.extref-google { background:#e8f0fe; border:1px solid #aac; border-radius:3px; padding:.05em .3em; font-size:.9em; }
span.extref-wiki   { background:#eaf3ea; border:1px solid #aca; border-radius:3px; padding:.05em .3em; font-size:.9em; }
/* keyword: リンク */
span.keyword-ref { display:inline-block; background:#fff8e8;
  border:1px solid #e8d890; border-radius:3px; padding:.1em .4em;
  font-size:.9em; margin:.1em 0; }
a.keyword-link { color:#885500; font-weight:500; }
a.keyword-link:hover { color:#cc7700; }
.bottom { margin-top:2em; border-top:1px solid #ccc; padding-top:.5em; font-size:.9em; }
CSS
    close($out);
}

# ============================================================
# ユーティリティ
# ============================================================

sub h {
    my ($s) = @_; $s //= '';
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
}

sub date_str {
    my ($art) = @_;
    return $art->{ts_raw} if $art->{ts_raw};
    my ($y,$m,$d) = ($art->{year}||0,$art->{month}||0,$art->{day}||0);
    return '' unless $y;
    my $s = sprintf "%04d年%02d月%02d日", $y, $m, $d;
    $s .= " $art->{time_str}" if $art->{time_str};
    return $s;
}

sub label_for_type {
    my ($type) = @_;
    my %L = ( column=>'雑記', religion=>'宗教と動機付け', society=>'税・経済・法',
              software=>'ソフトウェア Tips', pr=>'勝手に PR',
              statuses=>'ひとこと', hbm=>'ブックマーク', gsm=>'共有メモ' );
    return $L{$type} // $type;
}

# インデックス行の先頭に付けるサブブログバッジ
sub type_badge {
    my ($type) = @_;
    my %colors = (
        column   => 'badge-column',
        religion => 'badge-religion',
        society  => 'badge-society',
        software => 'badge-software',
        pr       => 'badge-pr',
        statuses => 'badge-statuses',
        hbm      => 'badge-hbm',
        gsm      => 'badge-gsm',
    );
    my $cls  = $colors{$type} // 'badge-other';
    my $label = label_for_type($type);
    return qq(<span class="type-badge $cls">${\h($label)}</span> );
}

# タイトルなし記事（statuses・gsm）は本文冒頭をタイトル代わりに使う
sub art_display_title {
    my ($art, $maxlen) = @_;
    $maxlen //= 40;
    return $art->{title} if $art->{title};
    # statuses・gsm：本文冒頭から末尾の「JRF YYYY年...」「○ timestamp」を除いた部分
    if ($art->{type} eq 'statuses' || $art->{type} eq 'gsm') {
        my $body = $art->{body} // '';
        # 末尾の日付行・署名行を除去
        $body =~ s/\nJRF\s+\d{4}年.*$//s;
        $body =~ s/^\s*jrf>\s*//;       # "jrf> " 書き出しを除去
        $body =~ s/^\s*//;
        # 改行・連続空白を1スペースに
        $body =~ s/\s+/ /g;
        $body =~ s/^\s+|\s+$//g;
        if (length($body) > $maxlen) {
            $body = substr($body, 0, $maxlen);
            $body =~ s/\s+\S*$//;  # 単語境界で切る
            $body .= '…';
        }
        return $body || label_for_type($art->{type});
    }
    return label_for_type($art->{type});
}
