"""
Flitter language AST
"""

# pylama:ignore=R0903

from dataclasses import dataclass
from typing import Tuple, Any


class Expression:
    pass


@dataclass(frozen=True)
class Sequence(Expression):
    expressions: Tuple[Expression, ...]


@dataclass(frozen=True)
class Literal(Expression):
    value: Any


@dataclass(frozen=True)
class Name(Expression):
    name: str


@dataclass(frozen=True)
class Range(Expression):
    start: Expression
    stop: Expression
    step: Expression


@dataclass(frozen=True)
class UnaryOperation(Expression):
    expr: Expression


class Negative(UnaryOperation):
    pass


class Not(UnaryOperation):
    pass


@dataclass(frozen=True)
class BinaryOperation(Expression):
    left: Expression
    right: Expression


class Add(BinaryOperation):
    pass


class Subtract(BinaryOperation):
    pass


class Multiply(BinaryOperation):
    pass


class Divide(BinaryOperation):
    pass


class FloorDivide(BinaryOperation):
    pass


class Modulo(BinaryOperation):
    pass


class Power(BinaryOperation):
    pass


class Comparison(BinaryOperation):
    pass


class EqualTo(Comparison):
    pass


class NotEqualTo(Comparison):
    pass


class LessThan(Comparison):
    pass


class GreaterThan(Comparison):
    pass


class LessThanOrEqualTo(Comparison):
    pass


class GreaterThanOrEqualTo(Comparison):
    pass


class And(BinaryOperation):
    pass


class Or(BinaryOperation):
    pass


@dataclass(frozen=True)
class Index(Expression):
    expr: Expression
    item: Expression


@dataclass(frozen=True)
class Call(Expression):
    function: Expression
    args: Tuple[Expression, ...]


@dataclass(frozen=True)
class Node(Expression):
    kind: str
    tags: Tuple[str, ...]


@dataclass(frozen=True)
class Attribute(Expression):
    node: Expression
    name: str
    expr: Expression


@dataclass(frozen=True)
class Search(Expression):
    query: str


@dataclass(frozen=True)
class Append(Expression):
    node: Expression
    children: Tuple[Expression, ...]


@dataclass(frozen=True)
class Binding:
    name: str
    expr: Expression


@dataclass(frozen=True)
class Let(Expression):
    bindings: Tuple[Binding, ...]


@dataclass(frozen=True)
class For(Expression):
    name: str
    source: Expression
    body: Tuple[Expression, ...]


@dataclass(frozen=True)
class Test:
    test: Expression
    then: Tuple[Expression, ...]


@dataclass(frozen=True)
class IfElse(Expression):
    tests: Tuple[Test, ...]
    else_: Tuple[Expression, ...]
