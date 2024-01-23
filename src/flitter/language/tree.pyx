# cython: language_level=3, profile=False

"""
Language abstract syntax tree

The tree supports reasonably sophisticated simplification that will reduce
the tree down to a "simpler" form by propogating constants. As this can result
in unrolling loops, simpler does not necessarily mean "smaller."
"""

cimport cython

from loguru import logger

from .. import name_patch
from ..model cimport Vector, Node, Query, Context, StateDict, null_, true_, false_, minusone_
from .vm cimport Program, builtins, static_builtins, dynamic_builtins


logger = name_patch(logger, __name__)

cdef Literal NoOp = Literal(null_)


cdef Expression sequence_pack(list expressions):
    cdef Expression expr
    cdef Literal literal
    cdef Vector value
    cdef list vectors, remaining = []
    cdef bint has_let = False
    while expressions:
        expr = <Expression>expressions.pop(0)
        if isinstance(expr, Literal) and type((<Literal>expr).value) == Vector:
            vectors = []
            while isinstance(expr, Literal) and type((<Literal>expr).value) == Vector:
                value = (<Literal>expr).value
                if value.length:
                    vectors.append(value)
                if not expressions:
                    expr = None
                    break
                expr = <Expression>expressions.pop(0)
            if vectors:
                remaining.append(Literal(Vector._compose(vectors)))
        if expr is not None:
            if isinstance(expr, InlineSequence):
                expressions[:0] = (<InlineSequence>expr).expressions
                continue
            if isinstance(expr, (Let, Import, Function)):
                has_let = True
            remaining.append(expr)
    if len(remaining) == 0:
        return NoOp
    if has_let:
        for expr in remaining:
            if not isinstance(expr, Let):
                return Sequence(tuple(remaining))
        return NoOp
    if len(remaining) == 1:
        return remaining[0]
    return InlineSequence(tuple(remaining))


cdef class Expression:
    def compile(self):
        cdef Program program = Program.__new__(Program)
        self._compile(program, [])
        program.optimize()
        program.link()
        return program

    def simplify(self, StateDict state=None, dict static=None, dynamic=None):
        cdef dict context_vars = {}
        cdef str key
        if static is not None:
            for key, value in static.items():
                context_vars[key] = Vector._coerce(value)
        if dynamic is not None:
            for key in dynamic:
                context_vars[key] = None
        cdef Context context = Context(state=state, variables=context_vars)
        cdef Expression expr
        try:
            expr = self._simplify(context)
        except Exception as exc:
            logger.opt(exception=exc).warning("Unable to simplify program")
            return self
        cdef str error
        for error in context.errors:
            logger.warning("Simplification error: {}", error)
        return expr

    cdef void _compile(self, Program program, list lvars):
        raise NotImplementedError()

    cdef Expression _simplify(self, Context context):
        raise NotImplementedError()


cdef class Top(Expression):
    cdef readonly tuple expressions

    def __init__(self, tuple expressions):
        self.expressions = expressions

    cdef void _compile(self, Program program, list lvars):
        cdef Expression expr, node
        for expr in self.expressions:
            expr._compile(program, lvars)
            if isinstance(expr, NodeModifier) and isinstance((<NodeModifier>expr).ultimate_node(), Search):
                program.drop(1)
            elif not isinstance(expr, (Let, Import, Function, Pragma)):
                program.append_root()
        cdef int i
        cdef str name
        for i, name in enumerate(reversed(lvars)):
            program.local_load(i)
            program.store_global(name)
        if lvars:
            program.local_drop(len(lvars))

    cdef Expression _simplify(self, Context context):
        cdef list expressions = []
        cdef Expression expr
        cdef dict variables = dict(context.variables)
        for expr in self.expressions:
            expr = expr._simplify(context)
            if not isinstance(expr, Literal) or (<Literal>expr).value.length:
                expressions.append(expr)
        cdef str name
        cdef list bindings = []
        for name, value in context.variables.items():
            if name not in variables and value is not None and isinstance(value, Vector):
                bindings.append(PolyBinding((name,), Literal(value)))
        if bindings:
            expressions.append(StoreGlobal(tuple(bindings)))
        return Top(tuple(expressions))

    def __repr__(self):
        return f'Top({self.expressions!r})'


cdef class Pragma(Expression):
    cdef readonly str name
    cdef readonly Expression expr

    def __init__(self, str name, Expression expr):
        self.name = name
        self.expr = expr

    cdef void _compile(self, Program program, list lvars):
        self.expr._compile(program, lvars)
        program.pragma(self.name)

    cdef Expression _simplify(self, Context context):
        return Pragma(self.name, self.expr._simplify(context))

    def __repr__(self):
        return f'Pragma({self.name!r}, {self.expr!r})'


cdef class Import(Expression):
    cdef readonly tuple names
    cdef readonly Expression filename

    def __init__(self, tuple names, Expression filename):
        self.names = names
        self.filename = filename

    cdef void _compile(self, Program program, list lvars):
        self.filename._compile(program, lvars)
        program.import_(self.names)
        lvars.extend(self.names)

    cdef Expression _simplify(self, Context context):
        cdef str name
        for name in self.names:
            context.variables[name] = None
        return Import(self.names, self.filename._simplify(context))

    def __repr__(self):
        return f'Import({self.names!r}, {self.filename!r})'


cdef class Sequence(Expression):
    cdef readonly tuple expressions

    def __init__(self, tuple expressions):
        self.expressions = expressions

    cdef void _compile(self, Program program, list lvars):
        cdef Expression expr
        cdef int n=len(lvars), m=0
        for expr in self.expressions:
            expr._compile(program, lvars)
            if not isinstance(expr, (Let, Import, Function, Pragma)):
                m += 1
        if len(lvars) > n:
            program.local_drop(len(lvars)-n)
            while len(lvars) > n:
                lvars.pop()
        if m > 1:
            program.compose(m)
        elif m == 0:
            program.literal(null_)

    cdef Expression _simplify(self, Context context):
        cdef list expressions = []
        cdef Expression expr
        cdef dict saved = context.variables
        context.variables = saved.copy()
        for expr in self.expressions:
            expressions.append(expr._simplify(context))
        context.variables = saved
        return sequence_pack(expressions)

    def __repr__(self):
        return f'{self.__class__.__name__}({self.expressions!r})'


cdef class InlineSequence(Sequence):
    cdef void _compile(self, Program program, list lvars):
        cdef Expression expr
        for expr in self.expressions:
            expr._compile(program, lvars)
        program.compose(len(self.expressions))

    cdef Expression _simplify(self, Context context):
        cdef list expressions = []
        cdef Expression expr
        for expr in self.expressions:
            expressions.append(expr._simplify(context))
        return sequence_pack(expressions)


cdef class Literal(Expression):
    cdef readonly Vector value
    cdef bint copynodes

    def __init__(self, Vector value):
        self.value = value
        self.copynodes = False
        if self.value.objects is not None:
            for obj in self.value.objects:
                if isinstance(obj, Node):
                    self.copynodes = True
                    break

    cdef void _compile(self, Program program, list lvars):
        program.literal(self.value.intern())

    cdef Expression _simplify(self, Context context):
        return Literal(self.value.copynodes()) if self.copynodes else self

    def __repr__(self):
        return f'Literal({self.value!r})'


cdef class Name(Expression):
    cdef readonly str name

    def __init__(self, str name):
        self.name = name

    cdef void _compile(self, Program program, list lvars):
        cdef int i, n=len(lvars)-1
        for i in range(len(lvars)):
            if self.name == <str>lvars[n-i]:
                program.local_load(i)
                break
        else:
            program.name(self.name)

    cdef Expression _simplify(self, Context context):
        if self.name in context.variables:
            value = context.variables[self.name]
            if value is None:
                return self
            elif isinstance(value, Function):
                return FunctionName(self.name)
            elif isinstance(value, Name):
                return (<Name>value)._simplify(context)
            else:
                return Literal((<Vector>value).copynodes())
        elif (value := static_builtins.get(self.name)) is not None:
            return Literal(value)
        elif self.name not in dynamic_builtins:
            if context.unbound is not None:
                context.unbound.add(self.name)
            else:
                context.errors.add(f"Unbound name '{self.name}'")
                return NoOp
        return self

    def __repr__(self):
        return f'Name({self.name!r})'


cdef class FunctionName(Name):
    def __repr__(self):
        return f'FunctionName({self.name!r})'


cdef class Lookup(Expression):
    cdef readonly Expression key

    def __init__(self, Expression key):
        self.key = key

    cdef void _compile(self, Program program, list lvars):
        self.key._compile(program, lvars)
        program.lookup()

    cdef Expression _simplify(self, Context context):
        cdef Expression key = self.key._simplify(context)
        cdef Vector value
        if isinstance(key, Literal):
            if context.state is not None:
                value = context.state.get_item((<Literal>key).value)
                return Literal(value)
            return LookupLiteral((<Literal>key).value)
        return Lookup(key)

    def __repr__(self):
        return f'Lookup({self.key!r})'


cdef class LookupLiteral(Expression):
    cdef readonly Vector key

    def __init__(self, Vector key):
        self.key = key

    cdef void _compile(self, Program program, list lvars):
        program.lookup_literal(self.key.intern())

    cdef Expression _simplify(self, Context context):
        cdef Vector value
        if context.state is not None:
            value = context.state.get_item(self.key)
            return Literal(value)
        return LookupLiteral(self.key)

    def __repr__(self):
        return f'LookupLiteral({self.key!r})'


cdef class Range(Expression):
    cdef readonly Expression start
    cdef readonly Expression stop
    cdef readonly Expression step

    def __init__(self, Expression start, Expression stop, Expression step):
        self.start = start
        self.stop = stop
        self.step = step

    cdef void _compile(self, Program program, list lvars):
        self.start._compile(program, lvars)
        self.stop._compile(program, lvars)
        self.step._compile(program, lvars)
        program.range()

    cdef Expression _simplify(self, Context context):
        cdef Expression start = self.start._simplify(context)
        cdef Expression stop = self.stop._simplify(context)
        cdef Expression step = self.step._simplify(context)
        cdef Vector result
        if isinstance(start, Literal) and isinstance(stop, Literal) and isinstance(step, Literal):
            result = Vector.__new__(Vector)
            result.fill_range((<Literal>start).value, (<Literal>stop).value, (<Literal>step).value)
            return Literal(result)
        return Range(start, stop, step)

    def __repr__(self):
        return f'Range({self.start!r}, {self.stop!r}, {self.step!r})'


cdef class UnaryOperation(Expression):
    cdef readonly Expression expr

    def __init__(self, Expression expr):
        self.expr = expr

    def __repr__(self):
        return f'{self.__class__.__name__}({self.expr!r})'


cdef class Negative(UnaryOperation):
    cdef void _compile(self, Program program, list lvars):
        self.expr._compile(program, lvars)
        program.neg()

    cdef Expression _simplify(self, Context context):
        cdef Expression expr = self.expr._simplify(context)
        if isinstance(expr, Literal):
            return Literal((<Literal>expr).value.neg())
        if isinstance(expr, Negative):
            expr = Positive((<Negative>expr).expr)
            return expr._simplify(context)
        cdef MathsBinaryOperation maths
        if isinstance(expr, (Multiply, Divide)):
            maths = expr
            if isinstance(maths.left, Literal):
                expr = type(expr)(Negative(maths.left), maths.right)
                return expr._simplify(context)
            if isinstance(maths.right, Literal):
                expr = type(expr)(maths.left, Negative(maths.right))
                return expr._simplify(context)
        return Negative(expr)


cdef class Positive(UnaryOperation):
    cdef void _compile(self, Program program, list lvars):
        self.expr._compile(program, lvars)
        program.pos()

    cdef Expression _simplify(self, Context context):
        cdef Expression expr = self.expr._simplify(context)
        if isinstance(expr, Literal):
            return Literal((<Literal>expr).value.pos())
        if isinstance(expr, (Negative, Positive, MathsBinaryOperation)):
            return expr._simplify(context)
        return Positive(expr)


cdef class Not(UnaryOperation):
    cdef void _compile(self, Program program, list lvars):
        self.expr._compile(program, lvars)
        program.not_()

    cdef Expression _simplify(self, Context context):
        cdef Expression expr = self.expr._simplify(context)
        if isinstance(expr, Literal):
            return Literal(false_ if (<Literal>expr).value.as_bool() else true_)
        return Not(expr)


cdef class BinaryOperation(Expression):
    cdef readonly Expression left
    cdef readonly Expression right

    def __init__(self, Expression left, Expression right):
        self.left = left
        self.right = right

    cdef void _compile(self, Program program, list lvars):
        self.left._compile(program, lvars)
        self.right._compile(program, lvars)
        self._compile_op(program)

    cdef void _compile_op(self, Program program):
        raise NotImplementedError()

    cdef Expression _simplify(self, Context context):
        cdef Expression left = self.left._simplify(context)
        cdef Expression right = self.right._simplify(context)
        cdef bint literal_left = isinstance(left, Literal)
        cdef bint literal_right = isinstance(right, Literal)
        if literal_left and literal_right:
            return Literal(self.op((<Literal>left).value, (<Literal>right).value))
        elif literal_left:
            if (expr := self.constant_left((<Literal>left).value, right)) is not None:
                return expr._simplify(context)
        elif literal_right:
            if (expr := self.constant_right(left, (<Literal>right).value)) is not None:
                return expr._simplify(context)
        return type(self)(left, right)

    cdef Vector op(self, Vector left, Vector right):
        raise NotImplementedError()

    cdef Expression constant_left(self, Vector left, Expression right):
        return None

    cdef Expression constant_right(self, Expression left, Vector right):
        return None

    def __repr__(self):
        return f'{self.__class__.__name__}({self.left!r}, {self.right!r})'


cdef class MathsBinaryOperation(BinaryOperation):
    cdef Expression _simplify(self, Context context):
        cdef Expression expr=BinaryOperation._simplify(self, context)
        if isinstance(expr, MathsBinaryOperation):
            if isinstance(expr.left, Positive):
                return (<Expression>type(expr)(expr.left.expr, expr.right))._simplify(context)
            elif isinstance(expr.right, Positive):
                return (<Expression>type(expr)(expr.left, expr.right.expr))._simplify(context)
        return expr


cdef class Add(MathsBinaryOperation):
    cdef Vector op(self, Vector left, Vector right):
        return left.add(right)

    cdef void _compile(self, Program program, list lvars):
        self.left._compile(program, lvars)
        self.right._compile(program, lvars)
        program.add()

    cdef Expression constant_left(self, Vector left, Expression right):
        if left.eq(false_):
            return Positive(right)
        if isinstance(right, Negative):
            return Subtract(Literal(left), right.expr)

    cdef Expression constant_right(self, Expression left, Vector right):
        return self.constant_left(right, left)


cdef class Subtract(MathsBinaryOperation):
    cdef Vector op(self, Vector left, Vector right):
        return left.sub(right)

    cdef void _compile_op(self, Program program):
        program.sub()

    cdef Expression constant_left(self, Vector left, Expression right):
        if left.eq(false_):
            return Negative(right)

    cdef Expression constant_right(self, Expression left, Vector right):
        if right.eq(false_):
            return Positive(left)
        return Add(left, Literal(right.neg()))


cdef class Multiply(MathsBinaryOperation):
    cdef Vector op(self, Vector left, Vector right):
        return left.mul(right)

    cdef void _compile_op(self, Program program):
        program.mul()

    cdef Expression constant_left(self, Vector left, Expression right):
        if left.eq(true_):
            return Positive(right)
        if left.eq(minusone_):
            return Negative(right)
        cdef MathsBinaryOperation maths
        if isinstance(right, Add) or isinstance(right, Subtract):
            maths = right
            if isinstance(maths.left, Literal) or isinstance(maths.right, Literal):
                return type(maths)(Multiply(Literal(left), maths.left), Multiply(Literal(left), maths.right))
        elif isinstance(right, Multiply):
            maths = right
            if isinstance(maths.left, Literal):
                return Multiply(Multiply(Literal(left), maths.left), maths.right)
            if isinstance(maths.right, Literal):
                return Multiply(maths.left, Multiply(Literal(left), maths.right))
        elif isinstance(right, Divide):
            maths = right
            if isinstance(maths.left, Literal):
                return Divide(Multiply(Literal(left), maths.left), maths.right)
        elif isinstance(right, Negative):
            return Multiply(Literal(left.neg()), (<Negative>right).expr)

    cdef Expression constant_right(self, Expression left, Vector right):
        return self.constant_left(right, left)


cdef class Divide(MathsBinaryOperation):
    cdef Vector op(self, Vector left, Vector right):
        return left.truediv(right)

    cdef void _compile_op(self, Program program):
        program.truediv()

    cdef Expression constant_right(self, Expression left, Vector right):
        if right.eq(true_):
            return Positive(left)
        return Multiply(left, Literal(true_.truediv(right)))


cdef class FloorDivide(MathsBinaryOperation):
    cdef Vector op(self, Vector left, Vector right):
        return left.floordiv(right)

    cdef void _compile_op(self, Program program):
        program.floordiv()


cdef class Modulo(MathsBinaryOperation):
    cdef Vector op(self, Vector left, Vector right):
        return left.mod(right)

    cdef void _compile_op(self, Program program):
        program.mod()


cdef class Power(MathsBinaryOperation):
    cdef Vector op(self, Vector left, Vector right):
        return left.pow(right)

    cdef void _compile_op(self, Program program):
        program.pow()

    cdef Expression constant_right(self, Expression left, Vector right):
        if right.eq(true_):
            return Positive(left)


cdef class Comparison(BinaryOperation):
    pass


cdef class EqualTo(Comparison):
    cdef Vector op(self, Vector left, Vector right):
        return left.eq(right)

    cdef void _compile_op(self, Program program):
        program.eq()


cdef class NotEqualTo(Comparison):
    cdef Vector op(self, Vector left, Vector right):
        return left.ne(right)

    cdef void _compile_op(self, Program program):
        program.ne()


cdef class LessThan(Comparison):
    cdef Vector op(self, Vector left, Vector right):
        return left.lt(right)

    cdef void _compile_op(self, Program program):
        program.lt()


cdef class GreaterThan(Comparison):
    cdef Vector op(self, Vector left, Vector right):
        return left.gt(right)

    cdef void _compile_op(self, Program program):
        program.gt()


cdef class LessThanOrEqualTo(Comparison):
    cdef Vector op(self, Vector left, Vector right):
        return left.le(right)

    cdef void _compile_op(self, Program program):
        program.le()


cdef class GreaterThanOrEqualTo(Comparison):
    cdef Vector op(self, Vector left, Vector right):
        return left.ge(right)

    cdef void _compile_op(self, Program program):
        program.ge()


cdef class And(BinaryOperation):
    cdef void _compile(self, Program program, list lvars):
        end_label = program.new_label()
        self.left._compile(program, lvars)
        program.dup()
        program.branch_false(end_label)
        program.drop()
        self.right._compile(program, lvars)
        program.label(end_label)

    cdef Expression _simplify(self, Context context):
        cdef Expression left = self.left._simplify(context)
        if isinstance(left, Literal):
            if (<Literal>left).value.as_bool():
                return self.right._simplify(context)
            return left
        return And(left, self.right._simplify(context))


cdef class Or(BinaryOperation):
    cdef void _compile(self, Program program, list lvars):
        end_label = program.new_label()
        self.left._compile(program, lvars)
        program.dup()
        program.branch_true(end_label)
        program.drop()
        self.right._compile(program, lvars)
        program.label(end_label)

    cdef Expression _simplify(self, Context context):
        cdef Expression left = self.left._simplify(context)
        if isinstance(left, Literal):
            if not (<Literal>left).value.as_bool():
                return self.right._simplify(context)
            return left
        return Or(left, self.right._simplify(context))


cdef class Xor(BinaryOperation):
    cdef void _compile_op(self, Program program):
        program.xor()

    cdef Expression _simplify(self, Context context):
        cdef Expression left = self.left._simplify(context)
        cdef Expression right = self.right._simplify(context)
        cdef bint literal_left = isinstance(left, Literal)
        cdef bint literal_right = isinstance(right, Literal)
        if literal_left and not (<Literal>left).value.as_bool():
            return right
        if literal_right and not (<Literal>right).value.as_bool():
            return left
        if literal_left and literal_right:
            return Literal(false_)
        return Xor(left, right)


cdef class Slice(Expression):
    cdef readonly Expression expr
    cdef readonly Expression index

    def __init__(self, Expression expr, Expression index):
        self.expr = expr
        self.index = index

    cdef void _compile(self, Program program, list lvars):
        self.expr._compile(program, lvars)
        self.index._compile(program, lvars)
        program.slice()

    cdef Expression _simplify(self, Context context):
        cdef Expression expr = self.expr._simplify(context)
        cdef Expression index = self.index._simplify(context)
        cdef Vector expr_value
        cdef Vector index_value
        cdef str name
        if isinstance(expr, Literal) and isinstance(index, Literal):
            expr_value = (<Literal>expr).value
            index_value = (<Literal>index).value
            return Literal(expr_value.slice(index_value))
        elif isinstance(index, Literal):
            index_value = (<Literal>index).value
            return FastSlice(expr, index_value)
        return Slice(expr, index)

    def __repr__(self):
        return f'Slice({self.expr!r}, {self.index!r})'


cdef class FastSlice(Expression):
    cdef readonly Expression expr
    cdef readonly Vector index

    def __init__(self, Expression expr, Vector index):
        self.expr = expr
        self.index = index

    cdef void _compile(self, Program program, list lvars):
        self.expr._compile(program, lvars)
        program.slice_literal(self.index.intern())

    cdef Expression _simplify(self, Context context):
        cdef Expression expr = self.expr._simplify(context)
        return FastSlice(expr, self.index)

    def __repr__(self):
        return f'FastSlice({self.expr!r}, {self.index!r})'


cdef class Call(Expression):
    cdef readonly Expression function
    cdef readonly tuple args
    cdef readonly tuple keyword_args

    def __init__(self, Expression function, tuple args, tuple keyword_args=None):
        self.function = function
        self.args = args
        self.keyword_args = keyword_args

    cdef void _compile(self, Program program, list lvars):
        cdef Vector value
        cdef Expression expr
        cdef list names = []
        if self.args:
            for expr in self.args:
                expr._compile(program, lvars)
        if isinstance(self.function, Literal) and not self.keyword_args:
            value = (<Literal>self.function).value
            if value.length == 1 and value.objects is not None and callable(value.objects[0]) and not hasattr(value.objects[0], 'context_func'):
                program.call_fast(value.objects[0], len(self.args))
                return
        cdef Binding keyword_arg
        if self.keyword_args:
            for keyword_arg in self.keyword_args:
                names.append(keyword_arg.name)
                keyword_arg.expr._compile(program, lvars)
        self.function._compile(program, lvars)
        program.call(len(self.args) if self.args else 0, tuple(names) if names else None)

    cdef Expression _simplify(self, Context context):
        cdef Expression function = self.function._simplify(context)
        cdef bint literal = isinstance(function, Literal) and (<Literal>function).value.objects is not None
        cdef Expression arg, expr
        cdef list args = []
        if self.args:
            for arg in self.args:
                arg = arg._simplify(context)
                args.append(arg)
                if not isinstance(arg, Literal):
                    literal = False
        cdef list keyword_args = []
        cdef Binding binding
        if self.keyword_args:
            for binding in self.keyword_args:
                arg = binding.expr._simplify(context)
                keyword_args.append(Binding(binding.name, arg))
                if not isinstance(arg, Literal):
                    literal = False
        cdef list bindings
        cdef Function func_expr
        cdef dict kwargs
        cdef int i
        if isinstance(function, FunctionName):
            func_expr = context.variables[(<FunctionName>function).name]
            kwargs = {binding.name: binding.expr for binding in keyword_args}
            bindings = []
            for i, binding in enumerate(func_expr.parameters):
                if i < len(args):
                    bindings.append(PolyBinding((binding.name,), <Expression>args[i]))
                elif binding.name in kwargs:
                    bindings.append(PolyBinding((binding.name,), <Expression>kwargs[binding.name]))
                elif binding.expr is not None:
                    bindings.append(PolyBinding((binding.name,), binding.expr))
                else:
                    bindings.append(PolyBinding((binding.name,), Literal(null_)))
            expr = InlineLet(func_expr.expr, tuple(bindings))._simplify(context)
            return expr
        cdef list vector_args, results
        cdef Literal literal_arg
        if literal:
            vector_args = [literal_arg.value for literal_arg in args]
            kwargs = {binding.name: (<Literal>binding.expr).value for binding in keyword_args}
            results = []
            for func in (<Literal>function).value.objects:
                if callable(func):
                    try:
                        if hasattr(func, 'context_func'):
                            results.append(Literal(func(context, *vector_args, **kwargs)))
                        else:
                            results.append(Literal(func(*vector_args, **kwargs)))
                    except Exception:
                        break
            else:
                return sequence_pack(results)
        cdef Call call = Call(function, tuple(args), tuple(keyword_args))
        return call

    def __repr__(self):
        return f'Call({self.function!r}, {self.args!r}, {self.keyword_args!r})'


cdef class NodeModifier(Expression):
    cdef readonly Expression node

    cdef Expression ultimate_node(self):
        cdef Expression node = self.node
        while isinstance(node, NodeModifier):
            node = (<NodeModifier>node).node
        return node


cdef class Tag(NodeModifier):
    cdef readonly str tag

    def __init__(self, Expression node, str tag):
        self.node = node
        self.tag = tag

    cdef void _compile(self, Program program, list lvars):
        self.node._compile(program, lvars)
        program.tag(self.tag)

    cdef Expression _simplify(self, Context context):
        cdef Expression node = self.node._simplify(context)
        cdef Vector nodes
        cdef Node n
        if isinstance(node, Literal):
            nodes = (<Literal>node).value
            if nodes.isinstance(Node):
                for n in nodes.objects:
                    n.add_tag(self.tag)
                return node
        return Tag(node, self.tag)

    def __repr__(self):
        return f'Tag({self.node!r}, {self.tag!r})'


cdef class Attributes(NodeModifier):
    cdef readonly tuple bindings

    def __init__(self, Expression node, tuple bindings):
        self.node = node
        self.bindings = bindings

    cdef void _compile(self, Program program, list lvars):
        cdef Binding binding
        self.node._compile(program, lvars)
        if isinstance(self.node, Literal) and (<Literal>self.node).value.length == 1:
            program.set_node_scope()
            for binding in self.bindings:
                binding.expr._compile(program, lvars)
                program.attribute(binding.name)
        else:
            program.dup()
            program.begin_for()
            START = program.new_label()
            END = program.new_label()
            program.label(START)
            program.push_next(END)
            program.set_node_scope()
            for binding in self.bindings:
                binding.expr._compile(program, lvars)
                program.attribute(binding.name)
            program.drop()
            program.jump(START)
            program.label(END)
            program.end_for()
        program.clear_node_scope()

    cdef Expression _simplify(self, Context context):
        cdef Expression node = self
        cdef list bindings = []
        cdef Attributes attrs
        cdef Binding binding
        cdef set unbound = context.unbound
        context.unbound = set()
        while isinstance(node, Attributes):
            attrs = <Attributes>node
            for binding in reversed(attrs.bindings):
                bindings.append(Binding(binding.name, binding.expr._simplify(context)))
            node = attrs.node
        cdef bint fast = not context.unbound
        cdef bint unbound_names = bool(context.unbound)
        context.unbound = unbound
        node = node._simplify(context)
        cdef Vector nodes
        cdef Node n
        cdef dict saved
        if isinstance(node, Literal):
            nodes = (<Literal>node).value
            if nodes.isinstance(Node):
                while bindings and isinstance((<Binding>bindings[-1]).expr, Literal):
                    binding = bindings.pop()
                    for n in nodes.objects:
                        n[binding.name] = (<Literal>binding.expr).value
                if unbound_names and bindings and nodes.length == 1:
                    n = nodes.objects[0]
                    saved = context.variables
                    context.variables = saved.copy()
                    for attr in n:
                        if attr not in context.variables:
                            context.variables[attr] = n[attr]
                    while bindings:
                        binding = bindings.pop()
                        binding = Binding(binding.name, binding.expr._simplify(context))
                        if isinstance(binding.expr, Literal):
                            value = (<Literal>binding.expr).value
                            n[binding.name] = value
                            if binding.name not in context.variables:
                                context.variables[binding.name] = value
                        else:
                            bindings.append(binding)
                            break
                    context.variables = saved
        if not bindings:
            return node
        bindings.reverse()
        if fast:
            return FastAttributes(node, tuple(bindings))
        return Attributes(node, tuple(bindings))

    def __repr__(self):
        return f'{self.__class__.__name__}({self.node!r}, {self.bindings!r})'


cdef class FastAttributes(Attributes):
    cdef void _compile(self, Program program, list lvars):
        self.node._compile(program, lvars)
        cdef Binding binding
        for binding in self.bindings:
            binding.expr._compile(program, lvars)
            program.attribute(binding.name)


cdef class Search(Expression):
    cdef readonly Query query

    def __init__(self, Query query):
        self.query = query

    cdef void _compile(self, Program program, list lvars):
        program.search(self.query)

    cdef Expression _simplify(self, Context context):
        return self

    def __repr__(self):
        return f'Search({self.query!r})'


cdef class Append(NodeModifier):
    cdef readonly Expression children

    def __init__(self, Expression node, Expression children):
        self.node = node
        self.children = children

    cdef void _compile(self, Program program, list lvars):
        self.node._compile(program, lvars)
        self.children._compile(program, lvars)
        program.append()

    cdef Expression _simplify(self, Context context):
        cdef Expression node = self.node._simplify(context)
        cdef Expression children = self.children._simplify(context)
        cdef Vector nodes, childs
        cdef Node n, c
        if isinstance(node, Literal) and isinstance(children, Literal):
            nodes = (<Literal>node).value
            childs = (<Literal>children).value
            if nodes.isinstance(Node) and childs.isinstance(Node):
                for n in nodes.objects:
                    for c in childs.objects:
                        n.append(c.copy())
                return node
        return Append(node, children)

    def __repr__(self):
        return f'{self.__class__.__name__}({self.node!r}, {self.children!r})'


cdef class Prepend(Append):
    cdef void _compile(self, Program program, list lvars):
        self.node._compile(program, lvars)
        self.children._compile(program, lvars)
        program.prepend()

    cdef Expression _simplify(self, Context context):
        cdef Expression node = self.node._simplify(context)
        cdef Expression children = self.children._simplify(context)
        cdef Vector nodes, childs
        cdef Node n, c
        if isinstance(node, Literal) and isinstance(children, Literal):
            nodes = (<Literal>node).value
            childs = (<Literal>children).value
            if nodes.isinstance(Node) and childs.isinstance(Node):
                for n in nodes.objects:
                    for c in reversed(childs.objects):
                        n.insert(c.copy())
                return node
        return Prepend(node, children)


cdef class Binding:
    cdef readonly str name
    cdef readonly Expression expr

    def __init__(self, str name, Expression expr):
        self.name = name
        self.expr = expr

    def __repr__(self):
        return f'Binding({self.name!r}, {self.expr!r})'


cdef class PolyBinding:
    cdef readonly tuple names
    cdef readonly Expression expr

    def __init__(self, tuple names, Expression expr):
        self.names = names
        self.expr = expr

    def __repr__(self):
        return f'PolyBinding({self.names!r}, {self.expr!r})'


cdef class Let(Expression):
    cdef readonly tuple bindings

    def __init__(self, tuple bindings):
        self.bindings = bindings

    cdef void _compile(self, Program program, list lvars):
        cdef PolyBinding binding
        for binding in self.bindings:
            binding.expr._compile(program, lvars)
            program.local_push(len(binding.names))
            lvars.extend(binding.names)

    cdef Expression _simplify(self, Context context):
        cdef list remaining = []
        cdef PolyBinding binding
        cdef Expression expr
        cdef Vector value
        cdef str name
        cdef int i, n
        for binding in self.bindings:
            expr = binding.expr._simplify(context)
            if isinstance(expr, Literal):
                value = (<Literal>expr).value
                n = len(binding.names)
                if n == 1:
                    name = binding.names[0]
                    context.variables[name] = value
                else:
                    for i, name in enumerate(binding.names):
                        context.variables[name] = value.item(i)
            elif isinstance(expr, Name) and len(binding.names) == 1:
                name = binding.names[0]
                if (<Name>expr).name != name:
                    context.variables[name] = expr
            else:
                for name in binding.names:
                    context.variables[name] = None
                remaining.append(PolyBinding(binding.names, expr))
        if remaining:
            return Let(tuple(remaining))
        return NoOp

    def __repr__(self):
        return f'{self.__class__.__name__}({self.bindings!r})'


cdef class StoreGlobal(Let):
    cdef void _compile(self, Program program, list lvars):
        cdef PolyBinding binding
        for binding in self.bindings:
            binding.expr._compile(program, lvars)
            assert len(binding.names) == 1, "StoreGlobal cannot multi-bind"
            program.store_global(binding.names[0])


cdef class InlineLet(Expression):
    cdef readonly Expression body
    cdef readonly tuple bindings

    def __init__(self, Expression body, tuple bindings):
        self.body = body
        self.bindings = bindings

    cdef void _compile(self, Program program, list lvars):
        cdef PolyBinding binding
        cdef int n=len(lvars)
        for binding in self.bindings:
            binding.expr._compile(program, lvars)
            program.local_push(len(binding.names))
            lvars.extend(binding.names)
        self.body._compile(program, lvars)
        program.local_drop(len(self.bindings))
        while len(lvars) > n:
            lvars.pop()

    cdef Expression _simplify(self, Context context):
        cdef dict saved = context.variables
        context.variables = saved.copy()
        cdef list remaining = []
        cdef PolyBinding binding
        cdef Expression expr
        cdef Vector value
        cdef str name
        cdef int i, n
        for binding in self.bindings:
            expr = binding.expr._simplify(context)
            if isinstance(expr, Literal):
                value = (<Literal>expr).value
                n = len(binding.names)
                if n == 1:
                    name = binding.names[0]
                    context.variables[name] = value
                else:
                    for i, name in enumerate(binding.names):
                        context.variables[name] = value.item(i)
            elif isinstance(expr, Name) and len(binding.names) == 1:
                name = binding.names[0]
                if (<Name>expr).name != name:
                    context.variables[name] = expr
            else:
                for name in binding.names:
                    context.variables[name] = None
                remaining.append(PolyBinding(binding.names, expr))
        body = self.body._simplify(context)
        context.variables = saved
        if remaining:
            return InlineLet(body, tuple(remaining))
        return body

    def __repr__(self):
        return f'InlineLet({self.body!r}, {self.bindings!r})'


cdef class For(Expression):
    cdef readonly tuple names
    cdef readonly Expression source
    cdef readonly Expression body

    def __init__(self, tuple names, Expression source, Expression body):
        self.names = names
        self.source = source
        self.body = body

    cdef void _compile(self, Program program, list lvars):
        self.source._compile(program, lvars)
        program.begin_for()
        START = program.new_label()
        END = program.new_label()
        cdef int i, n=len(self.names)
        lvars.extend(self.names)
        program.literal(null_)
        program.local_push(n)
        program.label(START)
        program.next(n, END)
        self.body._compile(program, lvars)
        program.jump(START)
        program.label(END)
        program.local_drop(n)
        program.end_for_compose()
        for i in range(n):
            lvars.pop()

    cdef Expression _simplify(self, Context context):
        cdef Expression body, source=self.source._simplify(context)
        cdef list remaining = []
        cdef Vector values, single
        cdef dict saved = context.variables
        context.variables = saved.copy()
        cdef str name
        if not isinstance(source, Literal):
            for name in self.names:
                context.variables[name] = None
            body = self.body._simplify(context)
            context.variables = saved
            return For(self.names, source, body)
        values = (<Literal>source).value
        cdef int i=0, n=values.length
        while i < n:
            for name in self.names:
                context.variables[name] = values.item(i)
                i += 1
            remaining.append(self.body._simplify(context))
        context.variables = saved
        return sequence_pack(remaining)

    def __repr__(self):
        return f'For({self.names!r}, {self.source!r}, {self.body!r})'


cdef class IfCondition:
    cdef readonly Expression condition
    cdef readonly Expression then

    def __init__(self, Expression condition, Expression then):
        self.condition = condition
        self.then = then

    def __repr__(self):
        return f'IfCondition({self.condition!r}, {self.then!r})'


cdef class IfElse(Expression):
    cdef readonly tuple tests
    cdef readonly Expression else_

    def __init__(self, tuple tests, Expression else_):
        self.tests = tests
        self.else_ = else_

    cdef void _compile(self, Program program, list lvars):
        cdef IfCondition test
        END = program.new_label()
        for test in self.tests:
            NEXT = program.new_label()
            test.condition._compile(program, lvars)
            program.branch_false(NEXT)
            test.then._compile(program, lvars)
            program.jump(END)
            program.label(NEXT)
        if self.else_ is not None:
            self.else_._compile(program, lvars)
        else:
            program.literal(null_)
        program.label(END)

    cdef Expression _simplify(self, Context context):
        cdef list remaining = []
        cdef IfCondition test
        cdef Expression condition, then
        for test in self.tests:
            condition = test.condition._simplify(context)
            if isinstance(condition, Literal):
                if (<Literal>condition).value.as_bool():
                    then = test.then._simplify(context)
                    if not remaining:
                        return then
                    else:
                        return IfElse(tuple(remaining), then)
            else:
                then = test.then._simplify(context)
                remaining.append(IfCondition(condition, then))
        else_ = self.else_._simplify(context) if self.else_ is not None else None
        if remaining:
            return IfElse(tuple(remaining), else_)
        return NoOp if else_ is None else else_

    def __repr__(self):
        return f'IfElse({self.tests!r}, {self.else_!r})'


cdef class Function(Expression):
    cdef readonly str name
    cdef readonly tuple parameters
    cdef readonly Expression expr

    def __init__(self, str name, tuple parameters, Expression expr):
        self.name = name
        self.parameters = parameters
        self.expr = expr

    cdef void _compile(self, Program program, list lvars):
        cdef Binding parameter
        cdef list names = []
        for parameter in self.parameters:
            names.append(parameter.name)
            if parameter.expr is None:
                program.literal(null_)
            else:
                parameter.expr._compile(program, lvars)
        cdef Program body = Program.__new__(Program)
        self.expr._compile(body, lvars + names)
        body.optimize()
        body.link()
        program.literal(body)
        program.func(self.name, tuple(names))
        program.local_push(1)
        lvars.append(self.name)

    cdef Expression _simplify(self, Context context):
        cdef list parameters = []
        cdef Binding parameter
        cdef Expression expr
        cdef bint literal = True
        for parameter in self.parameters:
            expr = parameter.expr._simplify(context) if parameter.expr is not None else None
            if expr is not None and not isinstance(expr, Literal):
                literal = False
            parameters.append(Binding(parameter.name, expr))
        cdef dict saved = context.variables
        cdef str key, name
        cdef set unbound = context.unbound
        context.unbound = set()
        context.variables = {}
        for key, value in saved.items():
            if value is not None:
                context.variables[key] = value
        for parameter in parameters:
            context.variables[parameter.name] = None
        expr = self.expr._simplify(context)
        cdef Function function = Function(self.name, tuple(parameters), expr)
        context.variables = saved
        context.variables[self.name] = function if literal and not context.unbound else None
        if unbound is not None:
            context.unbound.difference_update(saved)
            unbound.update(context.unbound)
        context.unbound = unbound
        return function

    def __repr__(self):
        return f'Function({self.name!r}, {self.parameters!r}, {self.expr!r})'
