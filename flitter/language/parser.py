"""
Flitter language compiler
"""

# pylama:ignore=R0201,C0103

from pathlib import Path

from lark import Lark, Transformer
from lark.indenter import Indenter
from lark.visitors import v_args

from . import ast


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
    SIGNED_NUMBER = float

    def TRUE(self, _):
        return True

    def FALSE(self, _):
        return False

    def ESCAPED_STRING(self, token):
        return token[1:-1].encode('utf-8').decode('unicode_escape')

    add = ast.Add
    args = v_args(inline=False)(tuple)
    attribute = ast.Attribute
    binding = ast.Binding
    bool = ast.Boolean
    call = ast.Call
    compose = ast.Compose
    comprehension = ast.Comprehension
    divide = ast.Divide
    eq = ast.EqualTo
    ge = ast.GreaterThanOrEqualTo
    graph = ast.Graph
    gt = ast.GreaterThan
    if_else = ast.IfElse
    sequence = v_args(inline=False)(tuple)
    le = ast.LessThanOrEqualTo
    let = v_args(inline=False)(ast.Let)
    loop = ast.For
    lt = ast.LessThan
    multiply = ast.Multiply
    name = ast.Name
    ne = ast.NotEqualTo
    node = ast.Node
    null = ast.Null
    number = ast.Number
    power = ast.Power
    range = ast.Range
    seach = ast.Search
    string = ast.String
    subtract = ast.Subtract
    tags = v_args(inline=False)(tuple)
    test = ast.Test
    tests = v_args(inline=False)(tuple)


GRAMMAR = (Path(__file__).parent / 'grammar.lark').open('r').read()
PARSER = Lark(GRAMMAR, postlex=FlitterIndenter(), regex=True, start='sequence', maybe_placeholders=True)


def parse(source):
    return FlitterTransformer().transform(PARSER.parse(source))
