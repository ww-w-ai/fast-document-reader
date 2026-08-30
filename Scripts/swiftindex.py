"""A Swift file's declarations, qualified by the types that enclose them.

Nesting is tracked by INDENT, not by brace matching: a declaration's members are the ones written
deeper than it, and a line at or left of its indent ends it. That is enough for this codebase's
style and it cannot be thrown off by a brace inside a string or a comment.
"""
import re

MOD = (r"(?:(?:private|public|internal|fileprivate|open|static|final|mutating|nonmutating"
       r"|override|lazy|weak|unowned|indirect|convenience|required|class)\s+)*")
DECL = re.compile(r"^(\s*)(?:@\w+\s+)?" + MOD + r"(func|struct|enum|class|actor|protocol|extension|var|let|init|subscript|case|typealias)\b\s*(\w+)?")
TYPES = {"struct", "enum", "class", "actor", "protocol", "extension"}


def declarations(lines):
    """[(qualified_name, kind, decl_line, indent)] in file order."""
    out, stack = [], []          # stack of (indent, name)
    for n, text in enumerate(lines, 1):
        if not text.strip() or text.lstrip().startswith("//"):
            continue
        hit = DECL.match(text)
        if not hit:
            continue
        indent, kind, name = len(hit.group(1)), hit.group(2), hit.group(3)
        if not name:
            continue
        while stack and stack[-1][0] >= indent:
            stack.pop()
        qualified = ".".join([s[1] for s in stack] + [name])
        out.append((qualified, kind, n, indent))
        if kind in TYPES:
            stack.append((indent, name))
    return out
