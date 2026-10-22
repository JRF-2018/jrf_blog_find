// JRF ブログ退避所: 記事ページ用（MathJax 切替・pre 連結切替・原文コピー）
(function() {
  'use strict';
  var MATHJAX_SRC = 'https://cdn.jsdelivr.net/npm/mathjax@3.2.2/es5/tex-chtml.js';
  var TEX_CONFIG = {
    // ひとこと: [mathjax-on] / <mathjax-on/> のある記事のみ（元ブログと同じ区切り）
    dollar: {
      inlineMath:  [['$', '$'], ['\\(', '\\)']],
      displayMath: [['$$', '$$'], ['\\[', '\\]']],
      processEscapes: true
    },
    // 雑記など: \begin{math} / \begin{displaymath} のみ
    latex: {
      inlineMath:  [['\\begin{math}', '\\end{math}']],
      displayMath: [['\\begin{displaymath}', '\\end{displaymath}']],
      processEnvironments: false
    }
  };

  var art  = document.querySelector('article');
  var body = document.querySelector('pre.body');
  var msg  = document.getElementById('tools-msg');
  if (!art || !body) return;

  var msgTimer = null;
  function showMsg(text, isError) {
    if (!msg) return;
    msg.textContent = text;
    msg.className = 'tools-msg' + (isError ? ' error' : '');
    clearTimeout(msgTimer);
    if (!isError) msgTimer = setTimeout(function() { msg.textContent = ''; }, 2000);
  }

  // --- pre 連結 ---
  var preJoin = document.getElementById('opt-prejoin');
  if (preJoin) {
    var applyPreJoin = function() { art.classList.toggle('pre-joined', preJoin.checked); };
    preJoin.addEventListener('change', applyPreJoin);
    applyPreJoin();  // 「戻る」でチェック状態が復元された場合に合わせる
  }

  // --- MathJax ---
  var mathOpt = document.getElementById('opt-mathjax');
  var mode = art.getAttribute('data-mathjax');
  if (mathOpt && TEX_CONFIG[mode]) {
    var origHTML = body.innerHTML;
    var loading = null;
    var chain = Promise.resolve();
    var loadMathJax = function() {
      if (loading) return loading;
      loading = new Promise(function(resolve, reject) {
        window.MathJax = {
          startup: { typeset: false },
          tex: TEX_CONFIG[mode],
          options: {
            // 本文自体が pre.body なので pre は除外しない。
            // 本文中に文字列として書かれた <pre> 部分 (span.src-pre) は除外する。
            skipHtmlTags: ['script', 'noscript', 'style', 'textarea', 'code'],
            ignoreHtmlClass: 'src-pre'
          }
        };
        var s = document.createElement('script');
        s.src = MATHJAX_SRC;
        s.async = true;
        s.onload = function() { window.MathJax.startup.promise.then(resolve, reject); };
        s.onerror = function() { reject(new Error('MathJax を読み込めませんでした')); };
        document.head.appendChild(s);
      });
      return loading;
    };
    var applyMathJax = function() {
      chain = chain.then(function() {
        if (window.MathJax && window.MathJax.typesetClear) window.MathJax.typesetClear([body]);
        body.innerHTML = origHTML;
        if (!mathOpt.checked) return;
        return loadMathJax().then(function() {
          return window.MathJax.typesetPromise([body]);
        });
      }).catch(function(e) {
        console.error('mathjax:', e);
        loading = null;
        mathOpt.checked = false;
        body.innerHTML = origHTML;
        showMsg('数式表示に失敗しました: ' + (e && e.message ? e.message : e), true);
      });
    };
    mathOpt.addEventListener('change', applyMathJax);
    if (mathOpt.checked) applyMathJax();
  }

  // --- 原文コピー ---
  var copyBtn = document.getElementById('btn-copy');
  var rawEl   = document.getElementById('raw-text');
  function copyByExecCommand(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.top = '0';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }
  if (copyBtn && rawEl) {
    copyBtn.addEventListener('click', function() {
      var text = JSON.parse(rawEl.textContent);
      var done = function() { showMsg('コピーしました'); };
      var fallback = function() {
        if (copyByExecCommand(text)) done();
        else showMsg('コピーできませんでした', true);
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, fallback);
      } else {
        fallback();
      }
    });
  }
})();
