# cython: language_level=3, profile=False

"""
Language syntax/evaluation tree
"""

cimport cython

from .functions import FUNCTIONS
from .. cimport model


cdef dict builtins_ = {
    'true': model.true_,
    'false': model.false_,
    'null': model.null_,
}
builtins_.update(FUNCTIONS)

cdef Literal NoOp = Literal(model.null_)


cdef Expression sequence_pack(list expressions):
    cdef Expression expr
    cdef Literal literal
    cdef model.Vector value
    cdef list vectors, remaining = []
    while expressions:
        expr = <Expression>expressions.pop(0)
        if isinstance(expr, Literal) and isinstance((<Literal>expr).value, model.Vector):
            vectors = []
            while isinstance(expr, Literal) and isinstance((<Literal>expr).value, model.Vector):
                value = (<Literal>expr).value
                if value.length:
                    vectors.append(value)
                if not expressions:
                    expr = None
                    break
                expr = <Expression>expressions.pop(0)
            if vectors:
                remaining.append(Literal(model.Vector._compose(vectors)))
        if expr is not None:
            if isinstance(expr, Sequence):
                expressions[:0] = (<Sequence>expr).expressions
                continue
            remaining.append(expr)
    if len(remaining) == 0:
        return NoOp
    if len(remaining) == 1:
        return remaining[0]
    return Sequence(tuple(remaining))


cdef class Expression:
    cpdef model.VectorLike evaluate(self, model.Context context):
        raise NotImplementedError()

    cpdef Expression partially_evaluate(self, model.Context context):
        raise NotImplementedError()


cdef class Top(Expression):
    cdef readonly tuple expressions

    def __init__(self, tuple expressions):
        self.expressions = expressions

    def run(self, state, **kwargs):
        cdef dict variables = {}
        cdef str key
        cdef model.Vector vector
        for key, value in kwargs.items():
            variables[key] = model.Vector.coerce(value)
        cdef model.Context context = model.Context(state=state, variables=variables)
        self.evaluate(context)
        return context

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.VectorLike result
        cdef model.Vector vector
        cdef Expression expr
        cdef model.Node node
        for expr in self.expressions:
            result = expr.evaluate(context)
            if isinstance(result, model.Vector):
                vector = result
                if vector.length and vector.objects is not None:
                    for value in vector.objects:
                        if isinstance(value, model.Node):
                            node = value
                            if node._parent is None:
                                context.graph.append(node)
        return model.null_

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef list expressions = []
        cdef Expression expr
        for expr in self.expressions:
            expressions.append(expr.partially_evaluate(context))
        return Top(tuple(expressions))

    def __repr__(self):
        return f'Top({self.expressions!r})'


cdef class Pragma(Expression):
    cdef readonly str name
    cdef readonly Expression expr

    def __init__(self, str name, Expression expr):
        self.name = name
        self.expr = expr

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector value = self.expr.evaluate(context)
        context.pragma(self.name, value)
        return model.null_

    cpdef Expression partially_evaluate(self, model.Context context):
        return Pragma(self.name, self.expr.partially_evaluate(context))

    def __repr__(self):
        return f'Pragma({self.name!r}, {self.expr!r})'


cdef class Sequence(Expression):
    cdef readonly tuple expressions

    def __init__(self, tuple expressions):
        self.expressions = expressions

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef Expression expr
        cdef list vectors = []
        for expr in self.expressions:
            vectors.append(expr.evaluate(context))
        return model.Vector._compose(vectors)

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef list expressions = []
        cdef Expression expr
        cdef dict saved = context.variables
        context.variables = saved.copy()
        for expr in self.expressions:
            expressions.append(expr.partially_evaluate(context))
        context.variables = saved
        return sequence_pack(expressions)

    def __repr__(self):
        return f'Sequence({self.expressions!r})'


cdef class Literal(Expression):
    cdef readonly model.VectorLike value

    def __init__(self, model.VectorLike value):
        self.value = value

    cpdef model.VectorLike evaluate(self, model.Context context):
        return self.value.copynodes()

    cpdef Expression partially_evaluate(self, model.Context context):
        return Literal(self.value.copynodes())

    def __repr__(self):
        return f'Literal({self.value!r})'


cdef class Name(Expression):
    cdef readonly str name

    def __init__(self, str name):
        self.name = name

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.VectorLike result
        result = context.variables.get(self.name)
        if result is not None:
            return result.copynodes()
        result = builtins_.get(self.name)
        if result is not None:
            return result
        return model.null_

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef model.VectorLike value
        if self.name in context.variables:
            value = context.variables[self.name]
            return Literal(value.copynodes())
        if self.name in builtins_:
            value = builtins_[self.name]
            return Literal(value)
        return self

    def __repr__(self):
        return f'Name({self.name!r})'


cdef class Lookup(Expression):
    cdef readonly Expression key

    def __init__(self, Expression key):
        self.key = key

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector key = self.key.evaluate(context)
        return context.state.get(key, model.null_)

    cpdef Expression partially_evaluate(self, model.Context context):
        return Lookup(self.key.partially_evaluate(context))

    def __repr__(self):
        return f'Lookup({self.key!r})'


cdef class Range(Expression):
    cdef readonly Expression start
    cdef readonly Expression stop
    cdef readonly Expression step

    def __init__(self, Expression start, Expression stop, Expression step):
        self.start = start
        self.stop = stop
        self.step = step

    cpdef model.VectorLike evaluate(self, model.Context context):
        start = self.start.evaluate(context)
        stop = self.stop.evaluate(context)
        step = self.step.evaluate(context)
        cdef model.Vector result = model.Vector.__new__(model.Vector)
        result.fill_range(start, stop, step)
        return result

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef Expression start = self.start.partially_evaluate(context)
        cdef Expression stop = self.stop.partially_evaluate(context)
        cdef Expression step = self.step.partially_evaluate(context)
        if isinstance(start, Literal) and isinstance(stop, Literal) and isinstance(step, Literal):
            return Literal(model.Vector.range((<Literal>start).value, (<Literal>stop).value, (<Literal>step).value))
        return Range(start, stop, step)

    def __repr__(self):
        return f'Range({self.start!r}, {self.stop!r}, {self.step!r})'


cdef class UnaryOperation(Expression):
    cdef readonly Expression expr

    def __init__(self, Expression expr):
        self.expr = expr

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef Expression expr = self.expr.partially_evaluate(context)
        cdef Expression unary = type(self)(expr)
        if isinstance(expr, Literal):
            return Literal(unary.evaluate(context))
        return unary

    def __repr__(self):
        return f'{self.__class__.__name__}({self.expr!r})'


cdef class Negative(UnaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector value = self.expr.evaluate(context)
        return value.neg()


cdef class Positive(UnaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector value = self.expr.evaluate(context)
        return value.pos()


cdef class Not(UnaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector value = self.expr.evaluate(context)
        return model.false_ if value.as_bool() else model.true_


cdef class BinaryOperation(Expression):
    cdef readonly Expression left
    cdef readonly Expression right

    def __init__(self, Expression left, Expression right):
        self.left = left
        self.right = right

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef Expression left = self.left.partially_evaluate(context)
        cdef Expression right = self.right.partially_evaluate(context)
        cdef Expression binary = type(self)(left, right)
        if isinstance(left, Literal) and isinstance(right, Literal):
            return Literal(binary.evaluate(context))
        return binary

    def __repr__(self):
        return f'{self.__class__.__name__}({self.left!r}, {self.right!r})'


cdef class MathsBinaryOperation(BinaryOperation):
    pass


cdef class Add(MathsBinaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.add(right)


cdef class Subtract(MathsBinaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.sub(right)


cdef class Multiply(MathsBinaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.mul(right)


cdef class Divide(MathsBinaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.truediv(right)


cdef class FloorDivide(MathsBinaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.floordiv(right)


cdef class Modulo(MathsBinaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.mod(right)


cdef class Power(MathsBinaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.pow(right)


cdef class Comparison(BinaryOperation):
    pass


cdef class EqualTo(Comparison):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.eq(right)


cdef class NotEqualTo(Comparison):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.ne(right)


cdef class LessThan(Comparison):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.lt(right)


cdef class GreaterThan(Comparison):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.gt(right)


cdef class LessThanOrEqualTo(Comparison):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.le(right)


cdef class GreaterThanOrEqualTo(Comparison):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        return left.ge(right)


cdef class And(BinaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        return self.right.evaluate(context) if left.as_bool() else left


cdef class Or(BinaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        return left if left.as_bool() else self.right.evaluate(context)


cdef class Xor(BinaryOperation):
    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector left = self.left.evaluate(context)
        cdef model.Vector right = self.right.evaluate(context)
        if not left.as_bool():
            return right
        if not right.as_bool():
            return left
        return model.false_


cdef class Slice(Expression):
    cdef readonly Expression expr
    cdef readonly Expression index

    def __init__(self, Expression expr, Expression index):
        self.expr = expr
        self.index = index

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.VectorLike expr = self.expr.evaluate(context)
        cdef model.Vector index = self.index.evaluate(context)
        return expr.slice(index)

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef Expression expr = self.expr.partially_evaluate(context)
        cdef Expression index = self.index.partially_evaluate(context)
        cdef model.VectorLike expr_value
        cdef model.Vector index_value
        if isinstance(expr, Literal) and isinstance(index, Literal):
            expr_value = (<Literal>expr).value
            index_value = (<Literal>index).value
            return Literal(expr_value.slice(index_value))
        return Slice(expr, index)

    def __repr__(self):
        return f'Slice({self.expr!r}, {self.index!r})'


cdef class Call(Expression):
    cdef readonly Expression function
    cdef readonly tuple args

    def __init__(self, Expression function, tuple args):
        self.function = function
        self.args = args

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector function = self.function.evaluate(context)
        if not function.length or function.objects is None:
            return model.null_
        cdef list args = []
        cdef Expression arg
        cdef model.VectorLike value
        for arg in self.args:
            value = arg.evaluate(context)
            args.append(value)
        cdef list results = []
        cdef Function func_expr
        cdef dict saved, params
        cdef Binding parameter
        cdef int i
        for func in function.objects:
            if callable(func):
                results.append(func(*args))
            elif isinstance(func, Function):
                func_expr = func
                saved = context.variables
                context.variables = {}
                for i, parameter in enumerate(func_expr.parameters):
                    if i < len(args):
                        context.variables[parameter.name] = args[i]
                    elif parameter.expr is not None:
                        context.variables[parameter.name] = (<Literal>parameter.expr).value
                    else:
                        context.variables[parameter.name] = model.null_
                results.append(func_expr.expr.evaluate(context))
                context.variables = saved
        return model.Vector._compose(results)

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef Expression function = self.function.partially_evaluate(context)
        cdef list args = []
        cdef Expression arg
        cdef bint literal = isinstance(function, Literal)
        for arg in self.args:
            arg = arg.partially_evaluate(context)
            args.append(arg)
            if not isinstance(arg, Literal):
                literal = False
        cdef Call call = Call(function, tuple(args))
        if literal:
            return Literal(call.evaluate(context))
        return Call(function, tuple(args))

    def __repr__(self):
        return f'Call({self.function!r}, {self.args!r})'


cdef class Node(Expression):
    cdef readonly str kind

    def __init__(self, str kind):
        self.kind = kind

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Node node = model.Node.__new__(model.Node, self.kind)
        return model.Vector.__new__(model.Vector, node)

    cpdef Expression partially_evaluate(self, model.Context context):
        return Literal(self.evaluate(context))

    def __repr__(self):
        return f'Node({self.kind!r})'


cdef class Tag(Expression):
    cdef readonly Expression node
    cdef readonly str tag

    def __init__(self, Expression node, str tag):
        self.node = node
        self.tag = tag

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector nodes = self.node.evaluate(context)
        cdef model.Node node
        if nodes.isinstance(model.Node):
            for node in nodes.objects:
                node._tags.add(self.tag)
        return nodes

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef Expression node = self.node.partially_evaluate(context)
        cdef model.Vector nodes
        cdef model.Node n
        if isinstance(node, Literal):
            nodes = (<Literal>node).value
            if nodes.isinstance(model.Node):
                for n in nodes.objects:
                    n.add_tag(self.tag)
                return node
        return Tag(node, self.tag)

    def __repr__(self):
        return f'Tag({self.node!r}, {self.tag!r})'


cdef class Attributes(Expression):
    cdef readonly Expression node
    cdef readonly tuple bindings

    def __init__(self, Expression node, tuple bindings):
        self.node = node
        self.bindings = bindings

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Node node
        cdef model.Vector value
        cdef dict variables, saved
        cdef Binding binding
        cdef model.Vector nodes = self.node.evaluate(context)
        if nodes.objects is not None:
            saved = context.variables
            for item in nodes.objects:
                if isinstance(item, model.Node):
                    node = item
                    variables = saved.copy()
                    for attr, value in node._attributes.items():
                        variables.setdefault(attr, value)
                    context.variables = variables
                    for binding in self.bindings:
                        value = binding.expr.evaluate(context)
                        if value.length:
                            node._attributes[binding.name] = value
                            if binding.name not in saved:
                                variables[binding.name] = value
            context.variables = saved
        return nodes

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef Expression node = self
        cdef list bindings = []
        cdef Attributes attrs
        cdef Binding binding
        while isinstance(node, Attributes):
            attrs = <Attributes>node
            for binding in reversed(attrs.bindings):
                bindings.append(Binding(binding.name, binding.expr.partially_evaluate(context)))
            node = attrs.node
        node = node.partially_evaluate(context)
        cdef model.Vector nodes
        cdef model.Node n
        if isinstance(node, Literal):
            nodes = (<Literal>node).value
            if nodes.isinstance(model.Node):
                while bindings and isinstance((<Binding>bindings[-1]).expr, Literal):
                    binding = bindings.pop()
                    for n in nodes.objects:
                        n[binding.name] = (<Literal>binding.expr).value
        if not bindings:
            return node
        bindings.reverse()
        return Attributes(node, tuple(bindings))

    def __repr__(self):
        return f'Attributes({self.node!r}, {self.bindings!r})'


cdef class Search(Expression):
    cdef readonly model.Query query

    def __init__(self, model.Query query):
        self.query = query

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Node node = context.graph.first_child
        cdef list nodes = []
        while node is not None:
            node._select(self.query, nodes, False)
            node = node.next_sibling
        return model.Vector.__new__(model.Vector, nodes)

    cpdef Expression partially_evaluate(self, model.Context context):
        return self

    def __repr__(self):
        return f'Search({self.query!r})'


cdef class Append(Expression):
    cdef readonly Expression node
    cdef readonly Expression children

    def __init__(self, Expression node, Expression children):
        self.node = node
        self.children = children

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector nodes = self.node.evaluate(context)
        cdef model.Vector children = self.children.evaluate(context)
        cdef model.Node node, child
        cdef int i, n = nodes.length
        if nodes.isinstance(model.Node) and children.isinstance(model.Node):
            for i in range(n):
                node = nodes.objects[i]
                if i < n-1:
                    for child in children.objects:
                        node.append(child.copy())
                else:
                    for child in children.objects:
                        node.append(child)
        return nodes

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef Expression node = self.node.partially_evaluate(context)
        cdef Expression children = self.children.partially_evaluate(context)
        cdef model.Vector nodes, childs
        cdef model.Node n, c
        if isinstance(node, Literal) and isinstance(children, Literal):
            nodes = (<Literal>node).value
            childs = (<Literal>children).value
            if nodes.isinstance(model.Node) and childs.isinstance(model.Node):
                for n in nodes.objects:
                    for c in childs.objects:
                        n.append(c.copy())
                return node
        return Append(node, children)

    def __repr__(self):
        return f'Append({self.node!r}, {self.children!r})'


cdef class Prepend(Expression):
    cdef readonly Expression node
    cdef readonly Expression children

    def __init__(self, Expression node, Expression children):
        self.node = node
        self.children = children

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector nodes = self.node.evaluate(context)
        cdef model.Vector children = self.children.evaluate(context)
        cdef model.Node node, child
        cdef int i, n = nodes.length
        if nodes.isinstance(model.Node) and children.isinstance(model.Node):
            for i in range(n):
                node = nodes.objects[i]
                if i < n-1:
                    for child in reversed(children.objects):
                        node.insert(child.copy())
                else:
                    for child in reversed(children.objects):
                        node.insert(child)
        return nodes

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef Expression node = self.node.partially_evaluate(context)
        cdef Expression children = self.children.partially_evaluate(context)
        cdef model.Vector nodes, childs
        cdef model.Node n, c
        if isinstance(node, Literal) and isinstance(children, Literal):
            nodes = (<Literal>node).value
            childs = (<Literal>children).value
            if nodes.isinstance(model.Node) and childs.isinstance(model.Node):
                for n in nodes.objects:
                    for c in reversed(childs.objects):
                        n.insert(c.copy())
                return node
        return Prepend(node, children)

    def __repr__(self):
        return f'Prepend({self.node!r}, {self.children!r})'


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

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef PolyBinding binding
        cdef model.Vector value
        cdef str name
        cdef int i, n
        for binding in self.bindings:
            value = binding.expr.evaluate(context)
            n = len(binding.names)
            for i, name in enumerate(binding.names):
                if i == n-1:
                    context.variables[name] = value.slice(model.Vector.range(i, n)) if i else value
                else:
                    context.variables[name] = value.item(i)
        return model.null_

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef list remaining = []
        cdef PolyBinding binding
        cdef Expression expr
        cdef model.Vector value
        cdef str name
        cdef int i, n
        for binding in self.bindings:
            expr = binding.expr.partially_evaluate(context)
            if isinstance(expr, Literal):
                value = (<Literal>expr).value
                n = len(binding.names)
                for i, name in enumerate(binding.names):
                    if i == n-1:
                        context.variables[name] = value.slice(model.Vector.range(i, n)) if i else value
                    else:
                        context.variables[name] = value.item(i)
            else:
                for name in binding.names:
                    if name in context.variables:
                        del context.variables[name]
                remaining.append(PolyBinding(binding.names, expr))
        if remaining:
            return Let(tuple(remaining))
        return NoOp

    def __repr__(self):
        return f'Let({self.bindings!r})'


cdef class InlineLet(Expression):
    cdef readonly Expression body
    cdef readonly tuple bindings

    def __init__(self, Expression body, tuple bindings):
        self.body = body
        self.bindings = bindings

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef PolyBinding binding
        cdef dict saved = context.variables
        context.variables = saved.copy()
        cdef model.Vector value
        cdef str name
        cdef int i, n
        for binding in self.bindings:
            value = binding.expr.evaluate(context)
            n = len(binding.names)
            for i, name in enumerate(binding.names):
                if i == n-1:
                    context.variables[name] = value.slice(model.Vector.range(i, n)) if i else value
                else:
                    context.variables[name] = value.item(i)
        cdef model.VectorLike result = self.body.evaluate(context)
        context.variables = saved
        return result

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef list remaining = []
        cdef PolyBinding binding
        cdef Expression body, expr
        cdef dict saved = context.variables
        context.variables = saved.copy()
        cdef model.Vector value
        cdef str name
        cdef int i, n
        for binding in self.bindings:
            expr = binding.expr.partially_evaluate(context)
            if isinstance(expr, Literal):
                value = (<Literal>expr).value
                n = len(binding.names)
                for i, name in enumerate(binding.names):
                    if i == n-1:
                        context.variables[name] = value.slice(model.Vector.range(i, n)) if i else value
                    else:
                        context.variables[name] = value.item(i)
            else:
                for name in binding.names:
                    if name in context.variables:
                        del context.variables[name]
                remaining.append(PolyBinding(binding.names, expr))
        body = self.body.partially_evaluate(context)
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

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef model.Vector source = self.source.evaluate(context)
        cdef list results = []
        cdef model.Vector value
        cdef dict saved = context.variables
        context.variables = saved.copy()
        cdef int i=0, n=source.length
        cdef str name
        while i < n:
            for name in self.names:
                context.variables[name] = source.item(i)
                i += 1
            results.append(self.body.evaluate(context))
        context.variables = saved
        return model.Vector._compose(results)

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef Expression body, source=self.source.partially_evaluate(context)
        cdef list remaining = []
        cdef model.Vector values, single
        cdef dict saved = context.variables
        context.variables = saved.copy()
        cdef str name
        if not isinstance(source, Literal):
            for name in self.names:
                if name in context.variables:
                    del context.variables[name]
            body = self.body.partially_evaluate(context)
            context.variables = saved
            return For(self.names, source, body)
        values = (<Literal>source).value
        cdef int i=0, n=values.length
        while i < n:
            for name in self.names:
                context.variables[name] = values.item(i)
                i += 1
            remaining.append(self.body.partially_evaluate(context))
        context.variables = saved
        return sequence_pack(remaining)

    def __repr__(self):
        return f'For({self.names!r}, {self.source!r}, {self.body!r})'


cdef class Test:
    cdef readonly Expression condition
    cdef readonly Expression then

    def __init__(self, Expression condition, Expression then):
        self.condition = condition
        self.then = then

    def __repr__(self):
        return f'Test({self.condition!r}, {self.then!r})'


cdef class IfElse(Expression):
    cdef readonly tuple tests
    cdef readonly Expression else_

    def __init__(self, tuple tests, Expression else_):
        self.tests = tests
        self.else_ = else_

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef Test test
        for test in self.tests:
            if test.condition.evaluate(context).as_bool():
                return test.then.evaluate(context)
        return self.else_.evaluate(context) if self.else_ is not None else model.null_

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef list remaining = []
        cdef Test test
        cdef Expression condition, then
        for test in self.tests:
            condition = test.condition.partially_evaluate(context)
            then = test.then.partially_evaluate(context)
            if isinstance(condition, Literal):
                if (<Literal>condition).value.as_bool():
                    if not remaining:
                        return then
                    else:
                        return IfElse(tuple(remaining), then)
            else:
                remaining.append(Test(condition, then))
        else_ = self.else_.partially_evaluate(context) if self.else_ is not None else None
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

    cpdef model.VectorLike evaluate(self, model.Context context):
        cdef list parameters = []
        cdef Binding parameter
        cdef dict saved=context.variables, variables=saved.copy()
        for parameter in self.parameters:
            if parameter.name in variables:
                del variables[parameter.name]
            if parameter.expr is not None and not isinstance(parameter.expr, Literal):
                parameters.append(Binding(parameter.name, Literal(parameter.expr.evaluate(context))))
            else:
                parameters.append(parameter)
        context.variables = variables
        cdef Expression expr = self.expr.partially_evaluate(context)
        context.variables = saved
        context.variables[self.name] = model.Vector.__new__(model.Vector, Function(self.name, tuple(parameters), expr))
        return model.null_

    cpdef Expression partially_evaluate(self, model.Context context):
        cdef list parameters = []
        cdef Binding parameter
        cdef Expression expr
        for parameter in self.parameters:
            parameters.append(Binding(parameter.name, parameter.expr.partially_evaluate(context) if parameter.expr is not None else None))
        cdef dict saved = context.variables
        context.variables = saved.copy()
        for parameter in parameters:
            if parameter.name in context.variables:
                del context.variables[parameter.name]
        expr = self.expr.partially_evaluate(context)
        context.variables = saved
        return Function(self.name, tuple(parameters), expr)

    def __repr__(self):
        return f'Function({self.name!r}, {self.parameters!r}, {self.expr!r})'
