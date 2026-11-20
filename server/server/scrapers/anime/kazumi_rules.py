"""Kazumi 规则库(apiLevel 9)的加载、字段模型与**容错改写层**。

为什么需要本模块
----------------
Kazumi 是 Flutter 客户端,规则在客户端里由 WebView + JS 引擎解释执行,
因此上游规则里混着几种"只在那个环境里成立"的写法:

* ``(?<v>...)`` 是 .NET 正则命名组语法,Python ``re`` 只认 ``(?P<v>...)``;
* 属性选择器里混着 CSS 运算符(``*=`` / ``^=`` / ``$=`` / ``~=``),XPath 1.0
  没有这些运算符。**规则快照里实测只有一处**:``TvTFun`` 的
  ``//ol[@class*='tvt-watch-episodes']``;不带 ``@`` 的裸名形态
  (``[href^=...]``)是 CSS 的写法,这里做防御性兼容,但快照里**没有实例** ——
  别把它当成已观测到的需求;
* ``//`` 这类残片不是合法 XPath,``lxml`` 会直接抛 ``XPathSyntaxError``。

本项目的定位是**机械修复 + 明确降级**,不是猜规则作者本意:

* 能机械改写的(XPath 属性运算符、未加引号的属性值、.NET 命名组)就地改写;
* 改不了或改了也没意义的(裸 ``//``、空表达式)判为坏选择器并返回 ``None``,
  让上层把该字段降级掉,而不是让整条规则或整轮搜索炸掉。

设计约束
--------
:func:`rewrite_selector` / :func:`rewrite_regex` 是**纯函数**且**幂等** ——
对已改写过的输入再跑一次不产生新变更,这条由 ``tests/test_kazumi.py`` 用
幂等断言锁住。所有改写通过 :data:`REWRITE_PIPELINE` 组合,单条改写规则可以
独立测试,顺序调整有测试兜底。
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

from lxml import etree

# ── 改写类别 ──────────────────────────────────────────────────────
#: XPath 属性子串运算符 → ``contains()`` 谓词
FIX_XPATH_ATTR_OPERATOR: Final = "xpath-attr-operator"
#: 明确的属性裸值 → XPath 字符串字面量
FIX_XPATH_ATTR_QUOTE: Final = "xpath-attr-quote"
#: XPath 属性等号左侧/右侧空白不规范 → 归一
FIX_XPATH_ATTR_SPACING: Final = "xpath-attr-spacing"
#: .NET 正则命名组 ``(?<name>`` → Python ``(?P<name>``
FIX_REGEX_NAMED_GROUP: Final = "regex-named-group"
#: 整条选择器是裸 ``//`` / ``/`` 之类残片 → 判坏
FIX_DROP_BARE_PATH: Final = "drop-bare-path"
#: 简单属性运算符缺少取值 → 判坏
FIX_DROP_STILL_INVALID: Final = "drop-still-invalid"
#: 选择器为空
FIX_DROP_EMPTY: Final = "drop-empty"

DROP_CODES: Final = frozenset(
    {FIX_DROP_BARE_PATH, FIX_DROP_STILL_INVALID, FIX_DROP_EMPTY}
)

# 只识别完整的简单属性谓词,不在字符串、轴或复合表达式内猜测属性。
_ATTR_SUBSTRING_OPERATORS: Final = {
    "*=": "contains({attr}, {value})",
    "^=": "starts-with({attr}, {value})",
    "$=": "substring({attr}, string-length({attr}) - string-length({value}) + 1)"
          " = {value}",
    "~=": "contains(concat(' ', normalize-space({attr}), ' '), "
          "concat(' ', {value}, ' '))",
}
_ATTR_NAME_BARE_RE: Final = r"[A-Za-z_][\w.-]*(?::[A-Za-z_][\w.-]*)?"
_ATTR_NAME_RE: Final = rf"@{_ATTR_NAME_BARE_RE}"
_ATTR_REF_RE: Final = rf"@?{_ATTR_NAME_BARE_RE}"
_BARE_VALUE_RE: Final = r"[\w#./:%?&=+~-]+"
_ATTR_SUBSTRING_RE: Final = re.compile(
    rf"(?P<attr>{_ATTR_REF_RE})\s*(?P<op>\*=|\^=|\$=|~=)\s*"
    rf"(?:'(?P<sq>[^']*)'|\"(?P<dq>[^\"]*)\"|(?P<bare>{_BARE_VALUE_RE}))"
)
_ATTR_VALUE_QUOTE_RE: Final = re.compile(
    rf"(?P<attr>{_ATTR_NAME_RE})\s*=\s*(?P<value>{_BARE_VALUE_RE})"
)
_ATTR_SPACING_RE: Final = re.compile(rf"({_ATTR_NAME_RE})\s*=\s*(['\"])")
_DOTNET_NAMED_GROUP_RE: Final = re.compile(r"\(\?<(?![=!])([A-Za-z_][A-Za-z0-9_]*)>")
_BARE_PATH_RE: Final = re.compile(r"^[./\s|()]*$")
_RESIDUAL_OPERATOR_RE: Final = re.compile(rf"{_ATTR_REF_RE}\s*(\*=|\^=|\$=|~=)\s*")


def _attr_ref(name: str) -> str:
    """把属性引用补成 XPath 形态(``href`` → ``@href``)。"""
    return name if name.startswith("@") else f"@{name}"


def _substring_value(match: re.Match[str]) -> str:
    """取运算符右侧的值(已去引号)。"""
    for group in ("sq", "dq", "bare"):
        value = match.group(group)
        if value is not None:
            return value
    return ""


def xpath_literal(value: str) -> str:
    """生成 XPath 1.0 字符串;同时含两种引号时用 ``concat()``。"""
    if "'" not in value:
        return f"'{value}'"
    if '"' not in value:
        return f'"{value}"'
    return "concat(" + ', "\'", '.join(f"'{part}'" for part in value.split("'")) + ")"


def _valid_xpath(expression: str) -> bool:
    try:
        etree.XPath(expression)
    except etree.XPathError:
        return False
    return True


def _simple_predicates(selector: str) -> list[tuple[int, int]]:
    """定位引号外、无嵌套的完整谓词;括号不平衡时放弃改写。"""
    quote = ""
    stack: list[list[int | bool]] = []
    spans: list[tuple[int, int]] = []
    for index, char in enumerate(selector):
        if quote:
            if char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
        elif char == "[":
            if stack:
                stack[-1][1] = True
            stack.append([index, False])
        elif char == "]":
            if not stack:
                return []
            start, nested = stack.pop()
            if not nested:
                spans.append((int(start) + 1, index))
    return [] if quote or stack else spans


def _rewrite_predicates(
    selector: str, rewrite: Callable[[str], tuple[str, list[RewriteNote]]]
) -> tuple[str, list[RewriteNote]]:
    notes: list[RewriteNote] = []
    parts: list[str] = []
    position = 0
    for start, end in _simple_predicates(selector):
        replacement, step_notes = rewrite(selector[start:end].strip())
        if not step_notes:
            continue
        parts.extend((selector[position:start], replacement))
        position = end
        notes.extend(step_notes)
    parts.append(selector[position:])
    return "".join(parts), notes


@dataclass(frozen=True)
class RewriteNote:
    """一次改写的记录(用于测试断言与运行期诊断)。"""

    code: str
    original: str
    rewritten: str
    detail: str = ""

    @property
    def dropped(self) -> bool:
        return self.code in DROP_CODES

    def __str__(self) -> str:  # pragma: no cover - 仅诊断输出
        return f"{self.code}: {self.original!r} -> {self.rewritten!r}"


@dataclass(frozen=True)
class SelectorRewrite:
    """单个选择器/正则字段的改写结果(``value is None`` = 判坏)。"""

    original: str
    value: str | None
    notes: tuple[RewriteNote, ...] = ()

    @property
    def ok(self) -> bool:
        return self.value is not None

    @property
    def changed(self) -> bool:
        return bool(self.notes)

    @property
    def codes(self) -> tuple[str, ...]:
        return tuple(note.code for note in self.notes)


# ── 单条改写规则(纯函数,可组合、可测) ──────────────────────────
def rewrite_bare_path(selector: str) -> tuple[str, list[RewriteNote]]:
    """裸 ``//`` / ``/`` 判坏。

    ``chapterRoads: "//"`` 在上游客户端里等价于"取整篇文档",落到 lxml 就是
    一条把所有节点都当章节容器的路径 —— 不但没有意义,还会让章节抽取退化成
    "抓全页链接"。这类残片无法机械补全,统一判坏并让上层降级。
    """
    stripped = selector.strip()
    if not stripped:
        return "", [RewriteNote(FIX_DROP_EMPTY, selector, "", "选择器为空")]
    if not _BARE_PATH_RE.match(stripped):
        return selector, []
    if stripped.startswith("//") or stripped.startswith("/"):
        return "", [
            RewriteNote(
                FIX_DROP_BARE_PATH,
                selector,
                "",
                "纯斜杠残片不构成合法 XPath 步进",
            )
        ]
    return selector, []


def rewrite_attr_quote(selector: str) -> tuple[str, list[RewriteNote]]:
    """只补语法无效且显式 ``@attr`` 的简单裸值,保留合法路径/数值比较。"""
    if _valid_xpath(selector):
        return selector, []

    def _replace(predicate: str) -> tuple[str, list[RewriteNote]]:
        match = _ATTR_VALUE_QUOTE_RE.fullmatch(predicate)
        if match is None or _valid_xpath(f"self::*[{predicate}]"):
            return predicate, []
        rewritten = f"{match.group('attr')}={xpath_literal(match.group('value'))}"
        return rewritten, [
            RewriteNote(FIX_XPATH_ATTR_QUOTE, predicate, rewritten, "明确的属性裸值")
        ]

    return _rewrite_predicates(selector, _replace)


def rewrite_attr_operator(selector: str) -> tuple[str, list[RewriteNote]]:
    """折算简单 CSS 属性运算符;复合/轴表达式与引号内文本保持原样。"""
    def _replace(predicate: str) -> tuple[str, list[RewriteNote]]:
        match = _ATTR_SUBSTRING_RE.fullmatch(predicate)
        if match is None:
            return predicate, []
        operator = match.group("op")
        value = _substring_value(match)
        # CSS 空值不匹配元素;~= 的值必须是单个空白分隔词。
        if not value or (operator == "~=" and any(char.isspace() for char in value)):
            rewritten = "false()"
        else:
            rewritten = _ATTR_SUBSTRING_OPERATORS[operator].format(
                attr=_attr_ref(match.group("attr")), value=xpath_literal(value)
            )
        return rewritten, [
            RewriteNote(
                FIX_XPATH_ATTR_OPERATOR, predicate, rewritten,
                f"{operator} 不是 XPath 1.0 运算符",
            )
        ]

    return _rewrite_predicates(selector, _replace)


def rewrite_attr_spacing(selector: str) -> tuple[str, list[RewriteNote]]:
    """只归一完整简单属性比较的等号空白,不改引号内文本。"""
    def _replace(predicate: str) -> tuple[str, list[RewriteNote]]:
        match = _ATTR_SPACING_RE.match(predicate)
        if match is None:
            return predicate, []
        quote = match.group(2)
        value = predicate[match.end():]
        if not value.endswith(quote) or quote in value[:-1]:
            return predicate, []
        rewritten = f"{match.group(1)}={quote}{value}"
        if rewritten == predicate:
            return predicate, []
        return rewritten, [
            RewriteNote(FIX_XPATH_ATTR_SPACING, predicate, rewritten, "等号周围空白")
        ]

    return _rewrite_predicates(selector, _replace)


def rewrite_regex(regex_text: str) -> tuple[str, list[RewriteNote]]:
    """把 .NET 正则命名组 ``(?<v>`` 改写成 Python 的 ``(?P<v>``。

    ``(?<=`` / ``(?<!`` 是合法的环视断言,必须原样保留 —— 这正是本改写用
    负向先行 ``(?![=!])`` 排除它们的原因。
    """
    notes: list[RewriteNote] = []

    def _replace(match: re.Match[str]) -> str:
        rewritten = f"(?P<{match.group(1)}>"
        notes.append(
            RewriteNote(
                FIX_REGEX_NAMED_GROUP,
                match.group(0),
                rewritten,
                ".NET 命名组语法",
            )
        )
        return rewritten

    rewritten = _DOTNET_NAMED_GROUP_RE.sub(_replace, regex_text)
    return rewritten, notes


def rewrite_residual(selector: str) -> tuple[str, list[RewriteNote]]:
    """补折简单运算符;只将明确缺值的属性谓词判坏,不猜复杂语义。"""
    rewritten, notes = rewrite_attr_operator(selector)
    for start, end in _simple_predicates(rewritten):
        predicate = rewritten[start:end].strip()
        if _RESIDUAL_OPERATOR_RE.fullmatch(predicate):
            return "", notes + [
                RewriteNote(
                    FIX_DROP_STILL_INVALID, predicate, "", "属性运算符缺少取值",
                )
            ]
    return rewritten, notes


#: 先排除裸路径,再修明确裸值和简单属性运算符,最后归一空白/检查缺值。
#: 合法 child/数值比较及含义不明的表达式保留,由运行期 XPath 求值隔离失败。
REWRITE_PIPELINE: Final[tuple[Any, ...]] = (
    rewrite_bare_path,
    rewrite_attr_quote,
    rewrite_attr_operator,
    rewrite_attr_spacing,
    rewrite_residual,
)


def _run_pipeline(text: str) -> tuple[str | None, tuple[RewriteNote, ...]]:
    """顺序跑管线;某一步判坏就短路返回 ``None``。"""
    if not text.strip():
        return None, ()
    notes: list[RewriteNote] = []
    work = text
    for step in REWRITE_PIPELINE:
        work, step_notes = step(work)
        notes.extend(step_notes)
        if not work:
            return None, tuple(notes)
    return work, tuple(notes)


def rewrite_selector(selector: object) -> SelectorRewrite:
    """改写一个 XPath 选择器字段,返回 :class:`SelectorRewrite`。

    ``None`` 与非字符串按"字段本来就空"处理,不产生任何 note —— 接口式规则
    (``searchMode: api``)的 ``searchList`` 全是空串,给它们记一堆 ``drop-empty``
    只会淹没真正需要关注的改写记录。
    """
    if not isinstance(selector, str):
        return SelectorRewrite(original="", value=None, notes=())
    if not selector.strip():
        return SelectorRewrite(original=selector, value=None, notes=())
    value, notes = _run_pipeline(selector)
    return SelectorRewrite(original=selector, value=value, notes=notes)


def rewrite_regex_field(value: object) -> SelectorRewrite:
    """改写一个正则字段(命名组),不做 XPath 相关处理。"""
    original = value if isinstance(value, str) else ""
    rewritten, notes = rewrite_regex(original)
    return SelectorRewrite(original=original, value=rewritten, notes=tuple(notes))


# ── 极简 JSONPath(规则里只用到 ``$.a.b[*].c`` 这一族) ───────────
_TOKEN_RE: Final = re.compile(r"\.?([A-Za-z_][A-Za-z0-9_-]*)|\[\s*(\d+|\*)\s*\]")


class KazumiRuleError(ValueError):
    """规则字段不合法或超出支持子集。"""


def jsonpath_tokens(expression: str) -> tuple[tuple[str, str], ...]:
    """把 JSONPath 拆成 ``(field, index)`` token 序列。

    只支持规则库实际出现过的子集:``$`` 起头、字段访问、``[*]``、``[n]``。
    出现过滤器 ``[?(...)]``、递归 ``..``、通配字段等超出子集的写法直接抛
    :class:`KazumiRuleError` —— 上层把它当作"该规则此模式不可用"降级,而不是
    静默返回错误数据。
    """
    text = (expression or "").strip()
    if not text:
        raise KazumiRuleError("empty jsonpath")
    if not text.startswith("$"):
        raise KazumiRuleError(f"jsonpath must start with '$': {expression!r}")
    body = text[1:]
    if ".." in body or "?" in body or "(" in body:
        raise KazumiRuleError(f"unsupported jsonpath feature: {expression!r}")

    tokens: list[tuple[str, str]] = []
    position = 0
    while position < len(body):
        match = _TOKEN_RE.match(body, position)
        if match is None:
            raise KazumiRuleError(f"unsupported jsonpath token: {expression!r}")
        field, index = match.group(1), match.group(2)
        if field is not None:
            tokens.append(("field", field))
        elif index == "*":
            tokens.append(("all", ""))
        else:
            assert index is not None
            tokens.append(("index", index))
        position = match.end()
    if not tokens:
        raise KazumiRuleError(f"jsonpath has no steps: {expression!r}")
    return tuple(tokens)


def jsonpath_values(payload: Any, expression: str) -> list[Any]:
    """按 JSONPath 取值,返回命中列表(可能为空,永不返回 ``None``)。"""
    nodes: list[Any] = [payload]
    for kind, value in jsonpath_tokens(expression):
        nxt: list[Any] = []
        for node in nodes:
            if kind == "field":
                if isinstance(node, dict) and value in node:
                    nxt.append(node[value])
            elif kind == "index":
                if isinstance(node, list) and int(value) < len(node):
                    nxt.append(node[int(value)])
            else:  # all
                if isinstance(node, list):
                    nxt.extend(node)
        nodes = nxt
        if not nodes:
            break
    return nodes


def jsonpath_scalar(payload: Any, expression: str, default: Any = None) -> Any:
    """取第一个命中值;命中是标量时直接返回,是容器时返回 ``default``。"""
    for value in jsonpath_values(payload, expression):
        if isinstance(value, (str, int, float, bool)):
            return value
        return default
    return default


def substitute_placeholders(text: str, **values: object) -> str:
    """把规则模板里的 ``@name`` 占位符替换成实参。

    长键先替换,避免 ``@source`` 把 ``@sourceId`` 的头部吃掉。
    """
    result = text
    for key in sorted(values, key=len, reverse=True):
        result = result.replace(f"@{key}", str(values[key]))
    return result


# ── 字段模型 ─────────────────────────────────────────────────────
@dataclass(frozen=True)
class KazumiRequest:
    """规则里一段 HTTP 请求描述(``searchApiConfig.request`` 等)。"""

    method: str = "GET"
    url: str = ""
    query: dict[str, Any] = None  # type: ignore[assignment]
    headers: dict[str, str] = None  # type: ignore[assignment]
    body_type: str = ""
    body: dict[str, Any] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        # frozen dataclass 里放可变默认值要手工归一,避免跨实例共享。
        object.__setattr__(self, "query", dict(self.query or {}))
        object.__setattr__(self, "headers", dict(self.headers or {}))
        object.__setattr__(self, "body", dict(self.body or {}))

    @property
    def usable(self) -> bool:
        return bool(self.method and self.url)


@dataclass(frozen=True)
class KazumiSearchApi:
    """``searchApiConfig``:JSON 接口式搜索。"""

    request: KazumiRequest
    list_path: str = ""
    name_path: str = ""
    source_path: str = ""
    source_template: str = ""

    @property
    def usable(self) -> bool:
        return bool(
            self.request.usable and self.list_path and self.name_path and self.source_path
        )


@dataclass(frozen=True)
class KazumiEpisodePage:
    """``chapterApiConfig.episodePage``:章节 → 详情页 URL 模板。"""

    url: str = ""
    query: dict[str, Any] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        object.__setattr__(self, "query", dict(self.query or {}))


@dataclass(frozen=True)
class KazumiChapterApi:
    """``chapterApiConfig``。``format`` 为 ``delimited`` 或 ``nested``。"""

    request: KazumiRequest = None  # type: ignore[assignment]
    format: str = ""
    road_names_path: str = ""
    road_episodes_path: str = ""
    road_separator: str = "$$$"
    episode_separator: str = "#"
    field_separator: str = "$"
    roads_path: str = ""
    road_name_path: str = ""
    episodes_path: str = ""
    episode_name_path: str = ""
    episode_url_path: str = ""
    episode_page: KazumiEpisodePage | None = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "request", self.request or KazumiRequest())

    @property
    def usable(self) -> bool:
        if not self.request.usable:
            return False
        if self.format == "delimited":
            return bool(self.road_episodes_path)
        if self.format == "nested":
            return bool(self.roads_path and self.episodes_path)
        return False


def _as_str(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _parse_request(raw: Any) -> KazumiRequest:
    data = _as_dict(raw)
    return KazumiRequest(
        method=_as_str(data.get("method") or "GET").upper(),
        url=_as_str(data.get("url")),
        query=_as_dict(data.get("query")),
        headers={
            str(key): str(value)
            for key, value in _as_dict(data.get("headers")).items()
            if isinstance(value, (str, int, float))
        },
        body_type=_as_str(data.get("bodyType")),
        body=_as_dict(data.get("body")),
    )


@dataclass(frozen=True)
class KazumiRule:
    """一条 Kazumi 规则(flat JSON,字段在顶层)。

    ``useWebview`` / ``useNativePlayer`` 在客户端 ``lib/`` 里是零引用的僵尸
    字段,本模块**不解析、不依据**它们做任何判断。
    """

    name: str
    api_level: str = ""
    type: str = "anime"
    version: str = ""
    base_url: str = ""
    user_agent: str = ""
    referer: str = ""
    deprecated: bool = False
    use_post: bool = False
    use_legacy_parser: bool = False

    search_mode: str = "xpath"
    search_url: str = ""
    search_list: str = ""
    search_name: str = ""
    search_result: str = ""
    search_api: KazumiSearchApi | None = None

    chapter_mode: str = "xpath"
    chapter_roads: str = ""
    chapter_result: str = ""
    chapter_api: KazumiChapterApi | None = None

    source_path: str = ""
    rewritten: tuple[RewriteNote, ...] = ()

    # ── 能力判定(供上层决定调哪条路径) ──────────────────────
    @property
    def search_via_api(self) -> bool:
        return self.search_mode == "api" and self.search_api is not None

    @property
    def chapter_via_api(self) -> bool:
        return self.chapter_mode == "api" and self.chapter_api is not None

    @property
    def can_search(self) -> bool:
        if self.search_via_api:
            return True
        return bool(self.search_url and self.search_list and self.search_result)

    @property
    def can_list_chapters(self) -> bool:
        if self.chapter_via_api:
            return True
        return bool(self.chapter_roads and self.chapter_result)

    @property
    def search_needs_post(self) -> bool:
        """``usePost`` 为真且未走接口模式时,搜索词应放进 form body。"""
        return self.use_post and not self.search_via_api

    def notes_for(self, code: str) -> tuple[RewriteNote, ...]:
        return tuple(note for note in self.rewritten if note.code == code)

    @property
    def notes(self) -> tuple[RewriteNote, ...]:
        """本规则命中的全部改写记录。"""
        return self.rewritten

    @property
    def codes(self) -> tuple[str, ...]:
        """命中的改写类别(去重、保持首次出现顺序),便于诊断与断言。"""
        seen: dict[str, None] = {}
        for note in self.rewritten:
            seen.setdefault(note.code, None)
        return tuple(seen)


def _select(value: Any) -> SelectorRewrite:
    return rewrite_selector(value)


def parse_rule(raw: Any) -> KazumiRule:
    """把一条 flat JSON 规则解析成 :class:`KazumiRule`,内联容错改写。

    解析过程不抛异常:任何超集写法的字段降级成空串,由 ``can_search`` /
    ``can_list_chapters`` 决定上层是否跳过。唯一例外是 ``name`` 缺失 ——
    没有名字的规则无法做失败隔离与报数,直接抛 :class:`KazumiRuleError`。
    """
    data = _as_dict(raw)
    name = _as_str(data.get("name")).strip()
    if not name:
        raise KazumiRuleError("rule has no name")

    notes: list[RewriteNote] = []
    selectors: dict[str, SelectorRewrite] = {}
    for field in (
        "search_list",
        "search_name",
        "search_result",
        "chapter_roads",
        "chapter_result",
        "source_path",
    ):
        key = {
            "search_list": "searchList",
            "search_name": "searchName",
            "search_result": "searchResult",
            "chapter_roads": "chapterRoads",
            "chapter_result": "chapterResult",
            "source_path": "sourcePath",
        }[field]
        selectors[field] = _select(data.get(key))
        # 空字段不记账(接口式规则的选择器字段本来就是空的),只留真实改写。
        notes.extend(
            note for note in selectors[field].notes if note.original.strip()
        )

    search_api_raw = data.get("searchApiConfig")
    search_api: KazumiSearchApi | None = None
    if isinstance(search_api_raw, dict):
        search_api = KazumiSearchApi(
            request=_parse_request(search_api_raw.get("request")),
            list_path=_as_str(search_api_raw.get("listPath")),
            name_path=_as_str(search_api_raw.get("namePath")),
            source_path=_as_str(search_api_raw.get("sourcePath")),
            source_template=_as_str(search_api_raw.get("sourceTemplate")),
        )

    chapter_api_raw = data.get("chapterApiConfig")
    chapter_api: KazumiChapterApi | None = None
    if isinstance(chapter_api_raw, dict):
        episode_page_raw = chapter_api_raw.get("episodePage")
        chapter_api = KazumiChapterApi(
            request=_parse_request(chapter_api_raw.get("request")),
            format=_as_str(chapter_api_raw.get("format")).lower(),
            road_names_path=_as_str(chapter_api_raw.get("roadNamesPath")),
            road_episodes_path=_as_str(chapter_api_raw.get("roadEpisodesPath")),
            road_separator=_as_str(chapter_api_raw.get("roadSeparator")) or "$$$",
            episode_separator=_as_str(chapter_api_raw.get("episodeSeparator")) or "#",
            field_separator=_as_str(chapter_api_raw.get("fieldSeparator")) or "$",
            roads_path=_as_str(chapter_api_raw.get("roadsPath")),
            road_name_path=_as_str(chapter_api_raw.get("roadNamePath")),
            episodes_path=_as_str(chapter_api_raw.get("episodesPath")),
            episode_name_path=_as_str(chapter_api_raw.get("episodeNamePath")),
            episode_url_path=_as_str(chapter_api_raw.get("episodeUrlPath")),
            episode_page=(
                KazumiEpisodePage(
                    url=_as_str(_as_dict(episode_page_raw).get("url")),
                    query=_as_dict(_as_dict(episode_page_raw).get("query")),
                )
                if isinstance(episode_page_raw, dict)
                else None
            ),
        )

    search_mode = _as_str(data.get("searchMode")).lower() or (
        "api" if search_api is not None else "xpath"
    )
    chapter_mode = _as_str(data.get("chapterMode")).lower() or (
        "api" if chapter_api is not None else "xpath"
    )

    return KazumiRule(
        name=name,
        api_level=str(data.get("api") or ""),
        type=_as_str(data.get("type")) or "anime",
        version=str(data.get("version") or ""),
        base_url=_as_str(data.get("baseURL")).strip(),
        user_agent=_as_str(data.get("userAgent")).strip(),
        referer=_as_str(data.get("referer")).strip(),
        deprecated=data.get("deprecated") is True,
        use_post=data.get("usePost") is True,
        use_legacy_parser=data.get("useLegacyParser") is True,
        search_mode=search_mode,
        search_url=_as_str(data.get("searchURL")).strip(),
        search_list=selectors["search_list"].value or "",
        search_name=selectors["search_name"].value or "",
        search_result=selectors["search_result"].value or "",
        search_api=search_api,
        chapter_mode=chapter_mode,
        chapter_roads=selectors["chapter_roads"].value or "",
        chapter_result=selectors["chapter_result"].value or "",
        chapter_api=chapter_api,
        source_path=selectors["source_path"].value or "",
        rewritten=tuple(notes),
    )


def iter_rule_files(directory: Path) -> Iterator[Path]:
    """列出规则目录下的 JSON(跳过聚合索引 ``index.json``)。"""
    if not directory.is_dir():
        return
    for path in sorted(directory.glob("*.json")):
        if path.name.lower() == "index.json":
            continue
        yield path


def load_rules(
    directory: Path | str,
    *,
    include_deprecated: bool = False,
) -> list[KazumiRule]:
    """加载规则目录。

    坏文件(JSON 语法错 / 缺 name)被跳过而不是中断整轮加载 —— 上游仓库由
    社区 PR 维护,单条坏规则不该拖垮整个 provider。
    """
    root = Path(directory)
    rules: list[KazumiRule] = []
    for path in iter_rule_files(root):
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            rule = parse_rule(raw)
        except (OSError, ValueError, TypeError):
            continue
        if rule.deprecated and not include_deprecated:
            continue
        rules.append(rule)
    return rules


__all__ = [
    "DROP_CODES",
    "FIX_DROP_BARE_PATH",
    "FIX_DROP_EMPTY",
    "FIX_DROP_STILL_INVALID",
    "FIX_REGEX_NAMED_GROUP",
    "FIX_XPATH_ATTR_OPERATOR",
    "FIX_XPATH_ATTR_QUOTE",
    "FIX_XPATH_ATTR_SPACING",
    "REWRITE_PIPELINE",
    "KazumiChapterApi",
    "KazumiEpisodePage",
    "KazumiRequest",
    "KazumiRule",
    "KazumiRuleError",
    "KazumiSearchApi",
    "RewriteNote",
    "SelectorRewrite",
    "iter_rule_files",
    "jsonpath_scalar",
    "jsonpath_tokens",
    "jsonpath_values",
    "load_rules",
    "parse_rule",
    "rewrite_attr_operator",
    "rewrite_attr_quote",
    "rewrite_attr_spacing",
    "rewrite_bare_path",
    "rewrite_regex",
    "rewrite_regex_field",
    "rewrite_residual",
    "rewrite_selector",
    "substitute_placeholders",
    "xpath_literal",
]
