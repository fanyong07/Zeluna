"""Kazumi 规则库适配器测试(全部离线,不联网)。

覆盖四层:

1. **规则加载与过滤** —— 读仓库内自带的规则快照(真实 86 条 JSON),
   验证 deprecated 过滤、字段模型、能力判定;
2. **容错改写层** —— 逐类覆盖并断言**幂等**;
3. **XPath / JSONPath 提取** —— 用内联 HTML 与内联 JSON,不发请求;
4. **失败隔离** —— 用 ``httpx.MockTransport`` 造"一条规则炸、其余正常"的
   场景,断言 ``search()`` 不抛异常且返回可用部分。

风格对齐仓库既有测试(``unittest.IsolatedAsyncioTestCase``),不引入
pytest-asyncio 依赖。
"""

from __future__ import annotations

import asyncio
import json
import unittest
from html import escape
from pathlib import Path

import httpx
import pytest

from server.scrapers.anime.kazumi import (
    KazumiPageError,
    KazumiRuleEngine,
    KazumiScraper,
    absolute_url,
    build_source_id,
    episode_number_from_label,
    is_fetchable_url,
    parse_document,
    rule_diagnostics,
    split_source_id,
    xpath_all,
)
from server.scrapers.anime.kazumi_rules import (
    FIX_DROP_BARE_PATH,
    FIX_REGEX_NAMED_GROUP,
    FIX_XPATH_ATTR_OPERATOR,
    FIX_XPATH_ATTR_QUOTE,
    KazumiRuleError,
    jsonpath_scalar,
    jsonpath_tokens,
    jsonpath_values,
    load_rules,
    parse_rule,
    rewrite_attr_operator,
    rewrite_attr_quote,
    rewrite_bare_path,
    rewrite_regex,
    rewrite_residual,
    rewrite_selector,
    substitute_placeholders,
    xpath_literal,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
RULES_DIR = REPO_ROOT / "server" / "scrapers" / "anime" / "kazumi_rules_data"
RULES_PRESENT = RULES_DIR.is_dir()
requires_rules = unittest.skipUnless(RULES_PRESENT, "bundled rules snapshot absent")


# ── 1. 规则加载与过滤 ────────────────────────────────────────────
@requires_rules
def test_bundled_snapshot_counts_match_upstream_inventory():
    """规则快照的规模与字段清单是这套实现的前提,先把它钉住。"""
    files = [p for p in RULES_DIR.glob("*.json") if p.name != "index.json"]
    assert len(files) == 86, f"expected 86 rule files, got {len(files)}"

    all_rules = load_rules(RULES_DIR, include_deprecated=True)
    active = load_rules(RULES_DIR)
    assert len(all_rules) == 86
    assert len(active) == 18, f"expected 18 active rules, got {len(active)}"
    assert len(all_rules) - len(active) == 68

    for rule in active:
        assert rule.deprecated is False
        assert rule.name
        assert rule.base_url.startswith("http")


@requires_rules
def test_active_rules_declare_usable_search_and_chapters():
    """18 条活跃规则都能搜索;aafun 的 chapterRoads 判坏是**已知**的。"""
    rules = {rule.name: rule for rule in load_rules(RULES_DIR)}
    assert "aafun" in rules

    assert rules["aafun"].can_search is True
    assert rules["aafun"].can_list_chapters is False
    assert rules["aafun"].chapter_roads == ""
    assert FIX_DROP_BARE_PATH in rules["aafun"].codes

    assert len([r for r in rules.values() if r.can_search]) == 18
    assert len([r for r in rules.values() if r.can_list_chapters]) == 17


@requires_rules
def test_tvtfun_class_star_operator_is_rewritten_into_contains():
    """``@class*=`` 不是 XPath 1.0 运算符,必须在编译前折成 contains()。"""
    rules = {rule.name: rule for rule in load_rules(RULES_DIR)}
    tvtfun = rules["TvTFun"]
    assert FIX_XPATH_ATTR_OPERATOR in tvtfun.codes
    assert "*=" not in tvtfun.chapter_roads
    assert "contains(@class" in tvtfun.chapter_roads
    # 折完之后 lxml 必须真的能编译并求值(不是"字符串看着对")。
    page = parse_document(
        b"<html><body><ol class='tvt-watch-episodes x'><li>"
        b"<a href='/w/1/1'>01</a></li></ol></body></html>"
    )
    assert xpath_all(page, tvtfun.chapter_roads)


@requires_rules
def test_api_level_nine_rules_do_not_depend_on_dead_webview_fields():
    """``useWebview`` / ``useNativePlayer`` 在客户端零引用,模型不得依据它们。"""
    import dataclasses

    from server.scrapers.anime.kazumi_rules import KazumiRule

    names = {field.name for field in dataclasses.fields(KazumiRule)}
    assert "use_webview" not in names
    assert "use_native_player" not in names

    rule = parse_rule(
        {
            "name": "dead-fields",
            "baseURL": "https://x.example/",
            "useWebview": True,
            "useNativePlayer": True,
        }
    )
    assert rule.name == "dead-fields"
    assert not hasattr(rule, "use_webview")


def test_parse_rule_requires_a_name():
    with pytest.raises(KazumiRuleError):
        parse_rule({"baseURL": "https://x.example/"})


def test_load_rules_skips_broken_files(tmp_path: Path):
    """坏 JSON / 缺 name 的规则被跳过,不拖垮整轮加载。"""
    (tmp_path / "ok.json").write_text(
        json.dumps(
            {
                "name": "ok",
                "baseURL": "https://ok.example/",
                "searchURL": "https://ok.example/s?wd=@keyword",
                "searchList": "//li",
                "searchName": "//a",
                "searchResult": "//a",
                "chapterRoads": "//ul",
                "chapterResult": "//li/a",
            }
        ),
        encoding="utf-8",
    )
    (tmp_path / "broken.json").write_text("{not json", encoding="utf-8")
    (tmp_path / "nameless.json").write_text(
        json.dumps({"baseURL": "https://x.example/"}), encoding="utf-8"
    )
    (tmp_path / "index.json").write_text('[{"name":"aggregate"}]', encoding="utf-8")

    assert [rule.name for rule in load_rules(tmp_path)] == ["ok"]


def test_provider_id_is_crawler_kazumi():
    """provider 命名规则:``crawler.<name>``,不加 maccms 之类的旧前缀。"""
    from server.provider_activation import provider_id_for_scraper

    assert provider_id_for_scraper("kazumi") == "crawler.kazumi"


def test_aggregator_accepts_crawler_kazumi_provider_id():
    """注册必须落在 aggregator 上,否则 ``crawler.kazumi`` 会直接把启动打挂。

    ``ContentAggregator.__init__`` 拿 ``PLAYBACK_PROVIDER_IDS`` 与它自算的
    ``available_provider_ids`` 比对,不认识的 id 抛
    ``ValueError("Unknown playback provider ids: ...")``。所以"注册"这件事
    不只是列表里多一行 —— 这个测试就是那条启动路径的最小复现。
    """
    from server.aggregator import ContentAggregator

    aggregator = ContentAggregator(enabled_provider_ids={"crawler.kazumi"})
    assert "kazumi" in aggregator.active_crawler_scrapers
    scraper = aggregator.active_crawler_scrapers["kazumi"]
    assert scraper.name == "kazumi"
    assert scraper.content_types == ["anime"]
    # provider 默认关闭:聚合器把它装配好,但 enabled 仍由 config 决定。
    assert scraper.enabled is False
    assert scraper.rules, "规则快照必须能从仓库内目录加载"


def test_aggregator_serializes_provider_metadata_for_kazumi():
    """provider 元信息能被注册表吐出来(前端/inventory 依赖这条)。"""
    from server.aggregator import ContentAggregator

    aggregator = ContentAggregator(enabled_provider_ids={"crawler.kazumi"})
    # ``provider_metadata`` 是 property,不是方法。
    ids = {meta.provider_id for meta in aggregator.provider_metadata}
    assert "crawler.kazumi" in ids


class KazumiEnableGateTests(unittest.IsolatedAsyncioTestCase):
    """``KAZUMI_ENABLED`` 默认关闭:关掉时三个入口都返回空/None,且不发请求。"""

    async def test_disabled_scraper_makes_no_network_calls(self):
        calls: list[str] = []

        def handler(request: httpx.Request) -> httpx.Response:
            calls.append(str(request.url))
            return httpx.Response(200, content=_SEARCH_PAGE)

        scraper = KazumiScraper(
            enabled=False,
            rules=[_GOOD_RULE],
            transport=httpx.MockTransport(handler),
            min_interval=0.0,
        )
        try:
            self.assertEqual(await scraper.search("frieren"), [])
            self.assertIsNone(await scraper.get_detail("good::https://x.example/1"))
            self.assertEqual(await scraper.get_video_urls("good::1", 1), [])
        finally:
            await scraper.aclose()
        self.assertEqual(calls, [], "关闭状态下不允许发出任何请求")

    async def test_enabled_scraper_does_fetch(self):
        scraper = KazumiScraper(
            enabled=True,
            rules=[_GOOD_RULE],
            transport=_mock_transport(),
            min_interval=0.0,
        )
        try:
            self.assertTrue(await scraper.search("frieren"))
        finally:
            await scraper.aclose()


# ── 2. 容错改写层 ────────────────────────────────────────────────
def test_rewrite_dotnet_named_group_to_python():
    """``(?<v>...)`` 是 .NET 语法,Python re 只认 ``(?P<v>...)``。"""
    rewritten, notes = rewrite_regex(r"https://x/(?<v>[\w-]+)/play")
    assert rewritten == r"https://x/(?P<v>[\w-]+)/play"
    assert [note.code for note in notes] == [FIX_REGEX_NAMED_GROUP]
    # 环视断言必须原样保留 —— 它们长得像命名组,语义完全不同。
    lookaround = r"(?<=a)(?<!b)(?=c)(?!d)"
    assert rewrite_regex(lookaround) == (lookaround, [])


def test_rewrite_unquoted_attribute_value():
    """``[href^=#playlist]`` 的值没加引号 → 补引号 + 折成 starts-with()。"""
    result = rewrite_selector("//a[href^=#playlist]")
    assert result.ok
    assert result.value == "//a[starts-with(@href, '#playlist')]"
    assert FIX_XPATH_ATTR_OPERATOR in result.codes

    # playlistbox 是合法 child 路径,只有明确无效的 @attr 裸值才补引号。
    assert rewrite_selector("//div[@id=playlistbox]").value == "//div[@id=playlistbox]"
    simple = rewrite_selector("//div[@id=#playlistbox]")
    assert simple.value == "//div[@id='#playlistbox']"
    assert FIX_XPATH_ATTR_QUOTE in simple.codes


def test_rewrite_bare_slash_is_dropped():
    """``chapterRoads: "//"`` 补不出合法步进 → 判坏。"""
    for bad in ("//", "/", "  //  ", ""):
        assert rewrite_selector(bad).ok is False, bad
    dropped, notes = rewrite_bare_path("//")
    assert dropped == ""
    assert [note.code for note in notes] == [FIX_DROP_BARE_PATH]


def test_rewrite_lxml_rejects_raw_operators_but_accepts_rewritten():
    """证明改写是真的必要:原样交给 lxml 会抛,改完能求值。"""
    page = parse_document(
        b"<html><body><div id='playlist1' class='lists-box'>"
        b"<a href='/p/1'>1</a></div></body></html>"
    )
    with pytest.raises(Exception):
        page.xpath("//ol[@class*='x']")

    result = rewrite_selector("//div[starts-with(@id, 'playlist')]")
    assert result.ok
    assert page.xpath(result.value)

    folded = rewrite_selector("//ol[@class*='lists-box']")
    assert folded.value == "//ol[contains(@class, 'lists-box')]"
    assert page.xpath("//div[contains(@class, 'lists-box')]")


@pytest.mark.parametrize(
    "raw",
    [
        "//div[2]/div[2]/div/ul/li",
        "//ol[@class*='tvt-watch-episodes']",
        "//a[href^=#playlist]",
        "//div[@id=playlistbox]",
        "//a[@data-x$='.m3u8']",
        "//a[@rel~='noopener']",
        "//",
        "/",
        "",
        r"https://www.x.com/(?<v>\d+)/play",
    ],
)
def test_rewrite_is_idempotent(raw: str):
    """改写必须幂等:第二次跑不产生新变更(可组合、可重放)。"""
    first = rewrite_selector(raw)
    second = rewrite_selector(first.value or "")
    assert second.value == first.value
    assert second.codes == ()

    regex_first, _ = rewrite_regex(raw)
    regex_second, second_notes = rewrite_regex(regex_first)
    assert regex_second == regex_first
    assert second_notes == []


def test_rewrite_pipeline_composes_independently():
    """单条改写规则可独立调用:顺序有语义,但每步都能单独测。"""
    assert rewrite_attr_quote("//a[@href=x]")[0] == "//a[@href=x]"
    assert rewrite_attr_quote("//a[@href=#x]")[0] == "//a[@href='#x']"
    # 运算符形态不能被"补引号"拆坏:必须原样交给运算符折叠那一步。
    assert rewrite_attr_quote("//ol[@class*='a b']")[0] == "//ol[@class*='a b']"
    assert rewrite_attr_quote("//a[href^=#x]")[0] == "//a[href^=#x]"

    folded, notes = rewrite_attr_operator("//ol[@class*='a b']")
    assert folded == "//ol[contains(@class, 'a b')]"
    assert len(notes) == 1
    # 谓词边界:已经在 [] 里的不重复包一层。
    assert rewrite_attr_operator("//ol[@class*='x']")[0] == (
        "//ol[contains(@class, 'x')]"
    )
    # 折不动(取不到值)才判坏。
    assert rewrite_residual("//a[@href^=]")[0] == ""


def test_rewrite_attr_operator_forms():
    assert rewrite_attr_operator("//a[@href^='#playlist']")[0] == (
        "//a[starts-with(@href, '#playlist')]"
    )
    endswith = rewrite_attr_operator("//a[@src$='.m3u8']")[0]
    assert endswith.startswith("//a[substring(@src, string-length(@src)")
    word = rewrite_attr_operator("//a[@rel~='x']")[0]
    assert "normalize-space(@rel)" in word


@pytest.mark.parametrize("value", ["", "a b", "O'Reilly", 'say "hi"', '''O'Reilly says "hi"'''])
def test_xpath_literal_roundtrips(value):
    document = parse_document(f'<div><a id="match" title="{escape(value, quote=True)}"/><a/></div>'.encode())
    literal = xpath_literal(value)
    assert document.xpath(literal) == value
    if "'" in value and '"' in value:
        assert literal.startswith("concat(")
    selector = f"//a[@title={literal}]"
    assert [node.get("id") for node in document.xpath(selector)] == ["match"]
    result = rewrite_selector(selector)
    assert result.value == selector and result.codes == ()
    assert rewrite_selector(result.value) == result


@pytest.mark.parametrize("operator", ["*=", "^=", "$=", "~="])
@pytest.mark.parametrize("attribute", ["@title", "title"])
@pytest.mark.parametrize("value", ["O'Reilly", 'say "hi"', "a b"])
def test_rewritten_operators_select_exact_nodes(operator, attribute, value):
    if operator == "~=":
        matching = f"prefix {value} suffix"
        expected = [] if " " in value else ["match"]
    elif operator == "^=":
        matching, expected = value + " suffix", ["match"]
    elif operator == "$=":
        matching, expected = "prefix " + value, ["match"]
    else:
        matching, expected = "prefix " + value + " suffix", ["match"]
    quote = '"' if "'" in value else "'"
    raw = f"//a[ {attribute} {operator} {quote}{value}{quote} ]"
    document = parse_document((
        f'<div><a id="match" title="{escape(matching, quote=True)}"/>'
        '<a id="other" title="unrelated"/><a id="missing"/></div>'
    ).encode())
    result = rewrite_selector(raw)
    assert result.ok and FIX_XPATH_ATTR_OPERATOR in result.codes
    assert [node.get("id") for node in document.xpath(result.value)] == expected
    second = rewrite_selector(result.value)
    assert second.value == result.value and second.codes == ()


@pytest.mark.parametrize("operator", ["*=", "^=", "$=", "~="])
def test_empty_css_attribute_values_do_not_match_missing_attributes(operator):
    document = parse_document(b'<div><a title=""/><a/></div>')
    result = rewrite_selector(f"//a[@title{operator}'']")
    assert document.xpath(result.value) == []


@pytest.mark.parametrize("raw", [
    "//item[price=10]", "//item[name='x']", "//item[name = 'x']",
    "//item[@id=other]", "//item[@id=10]", "//item[child::name='x']",
    "//item[@title=\"@id=x [href^='y']\"]",
    "//item[contains(@title, \"href^='x'\")]",
])
def test_valid_xpath_predicates_keep_child_and_string_semantics(raw):
    document = parse_document(b'<root><item id="10"><price>10</price><name>x</name>'
                              b'<other>10</other></item><item id="other"/></root>')
    result = rewrite_selector(raw)
    assert result.value == raw and result.codes == ()
    assert document.xpath(result.value) == document.xpath(raw)


@pytest.mark.parametrize("raw", [
    "//a[@href^='x' and @id='y']", "//a[child::href^='x']",
    "//a@href^='x'", "//a[href='x']", "//a[@href^='unterminated]",
    "//a[@href^=concat('x', 'y')]",
])
def test_uncertain_xpath_is_not_guessed_into_an_attribute(raw):
    result = rewrite_selector(raw)
    assert result.value == raw and result.codes == ()


# ── 3. XPath 提取 ────────────────────────────────────────────────
def test_xpath_all_swallows_bad_selector():
    document = parse_document(b"<html><body><a href='/x'>t</a></body></html>")
    assert len(xpath_all(document, "//a")) == 1
    assert xpath_all(document, "//a[@class*='x']") == []
    assert xpath_all(document, "///") == []
    assert xpath_all(None, "//a") == []


def test_parse_document_rejects_empty_body():
    with pytest.raises(KazumiPageError):
        parse_document(b"   ")
    with pytest.raises(KazumiPageError):
        parse_document(b"")


@pytest.mark.parametrize("meta,encoding", [
    ('<meta charset="utf-8">', "utf-8"),
    ('<meta charset="gbk">', "gbk"),
    ("<META CHARSET='GB2312'>", "gb2312"),
    ('<meta http-equiv="Content-Type" content="text/html; charset=gbk">', "gbk"),
    ('<meta charset="big5">', "big5"),
    ('<meta charset="unknown-charset">', "utf-8"),
    ("", "utf-8"),
])
def test_parse_document_declared_charset_preserves_exact_chinese(meta, encoding):
    title, label = "葬送的芙莉莲", "第25集"
    if encoding == "big5":
        title = "葬送的芙莉蓮"
    body = f"<html><head>{meta}</head><body><h1>{title}</h1><a>{label}</a></body></html>"
    document = parse_document(body.encode(encoding))
    assert document.xpath("string(//h1)") == title
    assert document.xpath("string(//a)") == label


@pytest.mark.parametrize("encoding,bom", [
    ("utf-8", b"\xef\xbb\xbf"), ("utf-16-le", b"\xff\xfe"),
    ("utf-16-be", b"\xfe\xff"), ("utf-32-le", b"\xff\xfe\x00\x00"),
])
def test_parse_document_bom_wins_over_conflicting_meta(encoding, bom):
    body = '<html><head><meta charset="gbk"></head><body><h1>葬送的芙莉莲</h1></body></html>'
    assert parse_document(bom + body.encode(encoding)).xpath("string(//h1)") == "葬送的芙莉莲"


def test_parse_document_ignores_charset_text_outside_meta():
    body = '<html><body><p>charset=gbk</p><h1>葬送的芙莉莲</h1></body></html>'.encode()
    assert parse_document(body).xpath("string(//h1)") == "葬送的芙莉莲"


def test_absolute_url_and_fetchable_url_guards():
    assert absolute_url("https://a.example/x/y", "/b") == "https://a.example/b"
    for bad in ("javascript:alert(1)", "#", "mailto:a@b.c", "", "data:text/html,x"):
        assert absolute_url("https://a.example/", bad) == ""
    assert is_fetchable_url("https://a.example/x") is True
    assert is_fetchable_url("file:///etc/passwd") is False
    assert is_fetchable_url("gopher://127.0.0.1:6379/") is False


def test_episode_number_prefers_explicit_label_over_position():
    """分季站点的集号是全局的,用位置序号会把第 25 集记成第 1 集。"""
    assert episode_number_from_label("第25集", 1) == 25
    assert episode_number_from_label("第01话", 1) == 1
    assert episode_number_from_label("03", 9) == 3
    assert episode_number_from_label("OAD", 7) == 7
    assert episode_number_from_label("", 0) == 1


def test_source_id_roundtrip_and_validation():
    assert build_source_id("kazumi", "26879") == "kazumi::26879"
    assert split_source_id("kazumi::26879") == ("kazumi", "26879")
    for bad in ("", "no-separator", "::", "::x", "x::", "   "):
        assert split_source_id(bad) == ("", "")


# ── 3b. JSONPath ─────────────────────────────────────────────────
def test_jsonpath_subset_supports_rule_library_expressions():
    payload = {
        "info": {"rows": [{"vod_name": "a", "vod_id": 1}]},
        "data": {"items": [{"name": "b", "slug": "s"}], "records": [{"id": 7}]},
    }
    assert jsonpath_values(payload, "$.info.rows[*]") == [payload["info"]["rows"][0]]
    assert jsonpath_values(payload, "$.data.items[*]")[0]["slug"] == "s"
    assert jsonpath_values(payload, "$.data.records[*]")[0]["id"] == 7
    assert jsonpath_values([{"id": 1}, {"id": 2}], "$[*]") == [{"id": 1}, {"id": 2}]
    assert jsonpath_values(payload, "$.missing") == []
    assert jsonpath_scalar({"a": {"b": "x"}}, "$.a.b") == "x"
    assert jsonpath_scalar({"a": {}}, "$.a.b", default="d") == "d"


def test_jsonpath_out_of_subset_raises_for_graceful_degradation():
    for bad in ("", "info.rows", "$.a[?(@.x)]", "$..rows"):
        with pytest.raises(KazumiRuleError):
            jsonpath_tokens(bad)


def test_substitute_placeholders_longest_key_first():
    """``@source`` 不能把 ``@sourceId`` 的头部吃掉。"""
    assert (
        substitute_placeholders(
            "https://x/@sourceId/@source", source="a", sourceId="b"
        )
        == "https://x/b/a"
    )


# ── 4. 引擎提取(内联 HTML / JSON,不联网) ────────────────────
class _StubFetcher:
    """按 URL 返回预置内容;并记录收到的请求参数(验证 Referer / 无 Cookie)。"""

    def __init__(self, pages: dict[str, tuple[int, bytes]], base_url: str = "") -> None:
        self.base_url = base_url
        self.pages = pages
        self.requests: list[dict] = []

    async def __call__(self, method: str, url: str, **kwargs: object) -> bytes:
        self.requests.append({"method": method, "url": url, **kwargs})
        entry = self.pages.get(url)
        if entry is None:
            raise KazumiPageError(f"no stub for {url}")
        status, body = entry
        if status >= 400:
            raise KazumiPageError(f"http {status} for {url}")
        return body


def _xpath_rule(**overrides: object):
    raw = {
        "name": "stub",
        "baseURL": "https://site.example/",
        "searchURL": "https://site.example/search?wd=@keyword",
        "searchList": "//ul[@class='results']/li",
        "searchName": "//a",
        "searchResult": "//a",
        "chapterRoads": "//ul[@class='playlist']",
        "chapterResult": "//li/a",
    }
    raw.update(overrides)
    return parse_rule(raw)


_SEARCH_PAGE = (
    b"<html><body><ul class='results'>"
    b"<li><a href='/anime/1.html'><img data-src='/c1.jpg'>Frieren</a></li>"
    b"<li><a href='/anime/2.html'>Bocchi</a></li>"
    b"</ul></body></html>"
)
_DETAIL_PAGE = (
    b"<html><body><ul class='playlist'>"
    b"<li><a href='/play/1-1'>\xe7\xac\xac01\xe8\xaf\x9d</a></li>"
    b"<li><a href='/play/1-2'>\xe7\xac\xac02\xe8\xaf\x9d</a></li>"
    b"</ul></body></html>"
)


class KazumiEngineTests(unittest.IsolatedAsyncioTestCase):
    async def test_engine_search_and_chapters_xpath_mode(self):
        rule = _xpath_rule()
        engine = KazumiRuleEngine(rule, max_results=10)
        fetcher = _StubFetcher(
            {
                "https://site.example/search?wd=%E8%91%AC%E9%80%81": (
                    200,
                    _SEARCH_PAGE,
                ),
                "https://site.example/anime/1.html": (200, _DETAIL_PAGE),
            },
            base_url="https://site.example/",
        )

        pairs = await engine.search(fetcher, "葬送")
        self.assertEqual([s.title for s, _ in pairs], ["Frieren", "Bocchi"])
        self.assertEqual(pairs[0][1], "https://site.example/anime/1.html")
        self.assertEqual(pairs[0][0].cover_url, "https://site.example/c1.jpg")
        self.assertEqual(
            pairs[0][0].source_id, "stub::https://site.example/anime/1.html"
        )

        # 搜索请求必须带 Referer: {baseURL}/
        self.assertEqual(
            fetcher.requests[0]["referer"], "https://site.example/"
        )

        episodes = await engine.chapters(
            fetcher, detail_url="https://site.example/anime/1.html"
        )
        self.assertEqual([item.number for item in episodes], [1, 2])
        self.assertEqual(episodes[0].title, "第01话")
        self.assertEqual(
            episodes[0].source_episode_id, "https://site.example/play/1-1"
        )

        # 章节请求带 Referer,且**不得**带 Cookie 头(实测隐藏语义)。
        chapter_request = fetcher.requests[-1]
        headers = chapter_request.get("headers") or {}
        self.assertEqual(chapter_request["referer"], "https://site.example/")
        self.assertNotIn("Cookie", headers)

    async def test_engine_search_post_mode_puts_keyword_in_form_body(self):
        engine = KazumiRuleEngine(_xpath_rule(usePost=True))
        fetcher = _StubFetcher(
            {
                "https://site.example/search?wd=%E8%91%AC%E9%80%81": (
                    200,
                    _SEARCH_PAGE,
                )
            },
            base_url="https://site.example/",
        )
        await engine.search(fetcher, "葬送")
        self.assertEqual(fetcher.requests[0]["method"], "POST")
        self.assertEqual(fetcher.requests[0]["form"]["wd"], "葬送")

    async def test_engine_api_mode_uses_raw_keyword_not_percent_encoded(self):
        """双重编码会让上游按字面量匹配 → 0 命中(实测 4 条规则栽在这里)。"""
        rule = parse_rule(_API_RULE_RAW)
        engine = KazumiRuleEngine(rule)
        fetcher = _StubFetcher(
            {
                "https://api.example/list": (
                    200,
                    json.dumps(
                        {
                            "list": [
                                {
                                    "name": "Frieren",
                                    "id": 11,
                                    "vod_pic": "https://img.example/a.jpg",
                                }
                            ]
                        }
                    ).encode("utf-8"),
                ),
                "https://api.example/detail": (
                    200,
                    json.dumps(
                        {
                            "info": {
                                "from": "cht$$$chs",
                                "url": (
                                    "01$https://m/cht/01.mp4#02$https://m/cht/02.mp4"
                                    "$$$01$https://m/chs/01.mp4#02$https://m/chs/02.mp4"
                                ),
                            }
                        }
                    ).encode("utf-8"),
                ),
            }
        )

        pairs = await engine.search(fetcher, "葬送のフリーレン")
        self.assertEqual([s.title for s, _ in pairs], ["Frieren"])
        self.assertEqual(pairs[0][0].cover_url, "https://img.example/a.jpg")
        # 查询串里的关键词是原文,不是 %E8...
        self.assertEqual(
            fetcher.requests[0]["params"]["wd"], "葬送のフリーレン"
        )

        episodes = await engine.chapters(fetcher, detail_url="", source_key="11")
        # 两条线路 × 两集 = 4 条:去重键带线路名,不许把 chs 整条吞掉。
        self.assertEqual(
            [item.title for item in episodes],
            ["cht 01", "cht 02", "chs 01", "chs 02"],
        )
        self.assertEqual(episodes[0].source_episode_id, "https://m/cht/01.mp4")
        self.assertEqual(fetcher.requests[-1]["params"]["vod_id"], "11")

    async def test_engine_nested_chapter_format(self):
        rule = parse_rule(_NESTED_RULE_RAW)
        engine = KazumiRuleEngine(rule)
        fetcher = _StubFetcher(
            {
                "https://api.n.example/rpc/search": (
                    200,
                    json.dumps([{"id": 3252, "title": "Frieren"}]).encode("utf-8"),
                ),
                "https://api.n.example/rpc/detail": (
                    200,
                    json.dumps(
                        {
                            "anime": {
                                "sources": [
                                    {
                                        "name": "main",
                                        "episodes": [
                                            {"id": 47463, "title": "那我们走吧"},
                                            {"id": 47464, "title": "南方勇者"},
                                        ],
                                    }
                                ]
                            }
                        }
                    ).encode("utf-8"),
                ),
            }
        )
        pairs = await engine.search(fetcher, "frieren")
        self.assertEqual([s.source_id for s, _ in pairs], ["nested::3252"])
        self.assertEqual(fetcher.requests[0]["json_body"], {"term": "frieren"})

        episodes = await engine.chapters(fetcher, detail_url="", source_key="3252")
        self.assertEqual(
            [item.title for item in episodes], ["main 那我们走吧", "main 南方勇者"]
        )
        self.assertEqual(
            episodes[0].source_episode_id, "https://n.example/anime/3252/play/47463"
        )
        self.assertEqual(fetcher.requests[-1]["json_body"], {"p_id": "3252"})


_API_RULE_RAW = {
    "name": "api-rule",
    "baseURL": "https://api.example/",
    "searchMode": "api",
    "chapterMode": "api",
    "searchApiConfig": {
        "request": {
            "method": "GET",
            "url": "https://api.example/list",
            "query": {"wd": "@keyword"},
        },
        "listPath": "$.list[*]",
        "namePath": "$.name",
        "sourcePath": "$.id",
    },
    "chapterApiConfig": {
        "request": {
            "method": "GET",
            "url": "https://api.example/detail",
            "query": {"vod_id": "@source"},
        },
        "format": "delimited",
        "roadNamesPath": "$.info.from",
        "roadEpisodesPath": "$.info.url",
        "roadSeparator": "$$$",
        "episodeSeparator": "#",
        "fieldSeparator": "$",
    },
}

_NESTED_RULE_RAW = {
    "name": "nested",
    "baseURL": "https://n.example/",
    "searchMode": "api",
    "chapterMode": "api",
    "searchApiConfig": {
        "request": {
            "method": "POST",
            "url": "https://api.n.example/rpc/search",
            "bodyType": "json",
            "body": {"term": "@keyword"},
        },
        "listPath": "$[*]",
        "namePath": "$.title",
        "sourcePath": "$.id",
    },
    "chapterApiConfig": {
        "request": {
            "method": "POST",
            "url": "https://api.n.example/rpc/detail",
            "bodyType": "json",
            "body": {"p_id": "@source"},
        },
        "format": "nested",
        "roadsPath": "$.anime.sources[*]",
        "roadNamePath": "$.name",
        "episodesPath": "$.episodes[*]",
        "episodeNamePath": "$.title",
        "episodeUrlPath": "$.id",
        "episodePage": {
            "url": "https://n.example/anime/@source/play/@episodeUrl",
            "query": {},
        },
    },
}


# ── 5. 失败隔离 ─────────────────────────────────────────────────
def _mock_transport() -> httpx.MockTransport:
    """一条规则炸(超时)、一条返回 403、一条正常,验证互不影响。"""

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "bad.example":
            raise httpx.ConnectTimeout("boom", request=request)
        if request.url.host == "forbidden.example":
            return httpx.Response(403, text="waf")
        if request.url.host == "good.example":
            body = _SEARCH_PAGE if request.url.path == "/search" else _DETAIL_PAGE
            return httpx.Response(200, content=body)
        return httpx.Response(404)

    return httpx.MockTransport(handler)


_GOOD_RULE = _xpath_rule(
    name="good",
    baseURL="https://good.example/",
    searchURL="https://good.example/search?wd=@keyword",
)
_BAD_RULE = _xpath_rule(
    name="bad",
    baseURL="https://bad.example/",
    searchURL="https://bad.example/search?wd=@keyword",
)
_FORBIDDEN_RULE = _xpath_rule(
    name="forbidden",
    baseURL="https://forbidden.example/",
    searchURL="https://forbidden.example/search?wd=@keyword",
)


class KazumiScraperIsolationTests(unittest.IsolatedAsyncioTestCase):
    async def test_search_isolates_rule_failures_and_returns_partial_results(self):
        scraper = KazumiScraper(
            enabled=True,
            rules=[_GOOD_RULE, _BAD_RULE, _FORBIDDEN_RULE],
            transport=_mock_transport(),
            min_interval=0.0,
            attempts=2,
            retry_backoff=0.0,
        )
        try:
            results = await scraper.search("frieren")
        finally:
            await scraper.aclose()

        self.assertTrue(results, "至少那条好规则的结果必须留下")
        self.assertTrue(
            all(subject.source_id.startswith("good::") for subject in results)
        )
        self.assertEqual([s.title for s in results], ["Frieren", "Bocchi"])

    async def test_search_returns_empty_when_every_rule_fails(self):
        scraper = KazumiScraper(
            enabled=True,
            rules=[_BAD_RULE, _FORBIDDEN_RULE],
            transport=_mock_transport(),
            min_interval=0.0,
            attempts=1,
        )
        try:
            self.assertEqual(await scraper.search("frieren"), [])
        finally:
            await scraper.aclose()

    async def test_search_enforces_overall_deadline_and_keeps_finished_rules(self):
        """慢规则被总时限砍掉,已完成的规则结果照常返回(不是整轮失败)。"""

        async def handler(request: httpx.Request) -> httpx.Response:
            if request.url.host == "slow.example":
                await asyncio.sleep(5)
            return httpx.Response(200, content=_SEARCH_PAGE)

        scraper = KazumiScraper(
            enabled=True,
            rules=[
                _GOOD_RULE,
                _xpath_rule(
                    name="slow",
                    baseURL="https://slow.example/",
                    searchURL="https://slow.example/search?wd=@keyword",
                ),
            ],
            transport=httpx.MockTransport(handler),
            min_interval=0.0,
            search_deadline=0.35,
            attempts=1,
        )
        try:
            results = await scraper.search("frieren")
        finally:
            await scraper.aclose()
        self.assertEqual([s.title for s in results], ["Frieren", "Bocchi"])

    async def test_get_detail_returns_chapters_and_empty_video_urls(self):
        scraper = KazumiScraper(
            enabled=True,
            rules=[_GOOD_RULE],
            transport=_mock_transport(),
            min_interval=0.0,
            attempts=1,
        )
        try:
            results = await scraper.search("frieren")
            self.assertTrue(results)
            subject_id = results[0].source_id

            detail = await scraper.get_detail(subject_id)
            self.assertIsNotNone(detail)
            self.assertEqual(detail.title, "Frieren")
            self.assertEqual(detail.type, "anime")
            self.assertEqual([item.number for item in detail.episodes], [1, 2])
            self.assertEqual([item.title for item in detail.episodes], ["第01话", "第02话"])
            self.assertEqual(detail.extra["kazumi_rule"], "good")
            self.assertEqual(detail.extra["playback_capability"], "chapters-only")

            # 规则库没有视频地址字段 → 恒为空,且不得抛异常。
            self.assertEqual(await scraper.get_video_urls(subject_id, 1), [])
            self.assertEqual(await scraper.get_latest(), [])
        finally:
            await scraper.aclose()

    async def test_http_charset_reaches_search_chapters_and_title_without_api_change(self):
        requests = []

        def handler(request):
            requests.append(request)
            if request.url.path == "/search":
                body = '<ul class="results"><li><a href="/anime/1.html">葬送的芙莉莲</a></li></ul>'
            else:
                body = '<meta charset="utf-8"><h1>葬送的芙莉莲</h1><ul class="playlist"><li><a href="/play/25">第25集</a></li></ul>'
            return httpx.Response(200, headers={"Content-Type": "text/html; charset=gbk"},
                                  content=body.encode("gbk"))

        scraper = KazumiScraper(enabled=True, rules=[_GOOD_RULE],
                                transport=httpx.MockTransport(handler), min_interval=0)
        try:
            results = await scraper.search("葬送")
            self.assertEqual([item.title for item in results], ["葬送的芙莉莲"])
            detail = await scraper.get_detail(results[0].source_id)
            self.assertEqual([item.title for item in detail.episodes], ["第25集"])
            self.assertEqual([item.number for item in detail.episodes], [25])
            self.assertEqual(len(requests), 2)
            self.assertEqual(await scraper.get_video_urls(results[0].source_id, 25), [])
            self.assertEqual(len(requests), 2, "播放入口不请求章节页或媒体")
            content = await scraper._fetch_as("GET", "https://good.example/anime/1.html")
            self.assertIsInstance(content, bytes)
            self.assertEqual(content.charset, "gbk")
            self.assertEqual(await scraper._title_from_detail_page("https://good.example/anime/1.html"), "葬送的芙莉莲")
        finally:
            await scraper.aclose()

    async def test_cookies_are_not_stored_or_sent_including_redirects(self):
        requests = []

        def handler(request):
            requests.append(request)
            if request.url.path == "/start":
                return httpx.Response(302, headers={"Location": "/next", "Set-Cookie": "session=secret; Path=/"})
            return httpx.Response(200, headers={"Set-Cookie": "later=secret; Path=/"}, content=_DETAIL_PAGE)

        scraper = KazumiScraper(enabled=True, rules=[_GOOD_RULE],
                                transport=httpx.MockTransport(handler), min_interval=0)
        try:
            await scraper._fetch_as("GET", "https://good.example/start", headers={"cOoKiE": "explicit=secret"})
            await scraper._fetch_as("GET", "https://good.example/again")
            self.assertEqual(len(scraper._client.cookies), 0)
            self.assertEqual([request.url.path for request in requests], ["/start", "/next", "/again"])
            self.assertTrue(all("cookie" not in request.headers for request in requests))
        finally:
            await scraper.aclose()

    async def test_cache_is_scoped_to_rule_even_when_api_ids_overlap(self):
        from server.scrapers.base import SubjectResult

        first = parse_rule(_API_RULE_RAW)
        second = parse_rule({**_API_RULE_RAW, "name": "second"})
        scraper = KazumiScraper(enabled=True, rules=[first, second],
                                transport=httpx.MockTransport(lambda _: httpx.Response(200, json={"info": {"url": "01$ep1"}})),
                                min_interval=0)
        scraper._remember_results("keyword", first.name, [SubjectResult(source_id="api-rule::11", title="第一规则")])
        scraper._remember_results("keyword", second.name, [SubjectResult(source_id="second::11", title="第二规则")])
        try:
            self.assertEqual((await scraper.get_detail("api-rule::11")).title, "第一规则")
            self.assertEqual((await scraper.get_detail("second::11")).title, "第二规则")
        finally:
            await scraper.aclose()

    async def test_get_detail_rejects_foreign_and_malformed_ids(self):
        scraper = KazumiScraper(
            enabled=True,
            rules=[_GOOD_RULE], transport=_mock_transport(), min_interval=0.0
        )
        try:
            self.assertIsNone(await scraper.get_detail("nope"))
            self.assertIsNone(await scraper.get_detail("unknown_rule::1"))
            self.assertIsNone(await scraper.get_detail("good::"))
        finally:
            await scraper.aclose()

    async def test_non_http_urls_are_never_fetched(self):
        scraper = KazumiScraper(
            enabled=True,
            rules=[_GOOD_RULE], transport=_mock_transport(), min_interval=0.0
        )
        try:
            with self.assertRaises(KazumiPageError):
                await scraper._fetch_as("GET", "file:///etc/passwd")
            with self.assertRaises(KazumiPageError):
                await scraper._fetch_as("GET", "gopher://127.0.0.1:6379/_x")
        finally:
            await scraper.aclose()

    async def test_403_response_becomes_page_error_not_partial_content(self):
        scraper = KazumiScraper(
            enabled=True,
            rules=[_FORBIDDEN_RULE],
            transport=_mock_transport(),
            min_interval=0.0,
            attempts=1,
        )
        try:
            with self.assertRaises(KazumiPageError):
                await scraper._fetch_as("GET", "https://forbidden.example/x")
        finally:
            await scraper.aclose()

    async def test_same_host_requests_are_throttled(self):
        """按主机名串行 + 保底间隔:同一站被抓两次必须排队。"""
        seen: list[float] = []
        loop = asyncio.get_running_loop()

        async def handler(request: httpx.Request) -> httpx.Response:
            seen.append(loop.time())
            return httpx.Response(200, content=b"<html><body/></html>")

        scraper = KazumiScraper(
            enabled=True,
            rules=[_GOOD_RULE],
            transport=httpx.MockTransport(handler),
            min_interval=0.2,
            attempts=1,
        )
        try:
            await scraper._fetch_as("GET", "https://good.example/a")
            await scraper._fetch_as("GET", "https://good.example/b")
        finally:
            await scraper.aclose()
        self.assertEqual(len(seen), 2)
        self.assertGreaterEqual(seen[1] - seen[0], 0.18)

    async def test_transient_error_is_retried_then_gives_up(self):
        """瞬时传输错误重试;上限用尽后抛出,而不是静默返回空内容。"""
        attempts: list[int] = []

        async def handler(request: httpx.Request) -> httpx.Response:
            attempts.append(1)
            raise httpx.ReadTimeout("slow", request=request)

        scraper = KazumiScraper(
            enabled=True,
            rules=[_GOOD_RULE],
            transport=httpx.MockTransport(handler),
            min_interval=0.0,
            attempts=3,
            retry_backoff=0.0,
        )
        try:
            with self.assertRaises(httpx.ReadTimeout):
                await scraper._fetch_as("GET", "https://good.example/x")
        finally:
            await scraper.aclose()
        self.assertEqual(len(attempts), 3)

    async def test_http_error_is_not_retried(self):
        seen: list[int] = []

        def handler(request: httpx.Request) -> httpx.Response:
            seen.append(1)
            return httpx.Response(503, text="down")

        scraper = KazumiScraper(
            enabled=True,
            rules=[_GOOD_RULE],
            transport=httpx.MockTransport(handler),
            min_interval=0.0,
            attempts=3,
        )
        try:
            with self.assertRaises(KazumiPageError):
                await scraper._fetch_as("GET", "https://good.example/x")
        finally:
            await scraper.aclose()
        self.assertEqual(len(seen), 1)


def test_rule_diagnostics_reports_per_rule_capability():
    rules = [_GOOD_RULE, _xpath_rule(name="noroads", chapterRoads="//")]
    table = rule_diagnostics(rules)
    assert [row["name"] for row in table] == ["good", "noroads"]
    assert table[0]["can_search"] is True
    assert table[0]["can_list_chapters"] is True
    assert table[1]["can_list_chapters"] is False
    assert table[1]["rewrites"][0]["code"] == FIX_DROP_BARE_PATH


if __name__ == "__main__":
    unittest.main()
