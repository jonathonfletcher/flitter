"""
Flitter language compiler
"""

# pylama:ignore=R0201,C0103

from pathlib import Path

from lark import Lark, Transformer
from lark.indenter import Indenter
from lark.visitors import v_args

from . import ast
from ..model import values


class FlitterIndenter(Indenter):
    NL_type = '_NL'
    OPEN_PAREN_types = ['_LPAR', '_LBRA']
    CLOSE_PAREN_types = ['_RPAR', '_RBRA']
    INDENT_type = '_INDENT'
    DEDENT_type = '_DEDENT'
    tab_len = 8


@v_args(inline=True)
class FlitterTransformer(Transformer):
    NAME = str

    def SIGNED_NUMBER(self, token):
        return values.Vector((float(token),))

    def ESCAPED_STRING(self, token):
        return values.Vector((token[1:-1].encode('utf-8').decode('unicode_escape'),))

    def QUERY(self, token):
        return token[1:-1].strip()

    def TRUE(self, _):
        return values.Vector((1.,))

    def FALSE(self, _):
        return values.Vector((0.,))

    def NULL(self, _):
        return values.null

    def range(self, start, stop, step):
        return ast.Range(ast.Literal(values.null) if start is None else start, stop, ast.Literal(values.null) if step is None else step)

    add = ast.Add
    append = ast.Append
    args = v_args(inline=False)(tuple)
    attribute = ast.Attribute
    binding = ast.Binding
    bool = ast.Literal
    call = ast.Call
    divide = ast.Divide
    eq = ast.EqualTo
    floordivide = ast.FloorDivide
    ge = ast.GreaterThanOrEqualTo
    gt = ast.GreaterThan
    if_else = ast.IfElse
    sequence = v_args(inline=False)(ast.Sequence)
    le = ast.LessThanOrEqualTo
    let = v_args(inline=False)(ast.Let)
    literal = ast.Literal
    loop = ast.For
    lt = ast.LessThan
    multiply = ast.Multiply
    name = ast.Name
    ne = ast.NotEqualTo
    node = ast.Node
    power = ast.Power
    search = ast.Search
    subtract = ast.Subtract
    tags = v_args(inline=False)(tuple)
    test = ast.Test
    tests = v_args(inline=False)(tuple)


GRAMMAR = (Path(__file__).parent / 'grammar.lark').open('r').read()
PARSER = Lark(GRAMMAR, postlex=FlitterIndenter(), regex=True, start='sequence', maybe_placeholders=True)


def parse(source):
    return FlitterTransformer().transform(PARSER.parse(source))
