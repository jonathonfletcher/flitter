# cython: language_level=3, profile=False, wraparound=False, boundscheck=False

"""
Flitter language stack-based virtual machine
"""

import cython
from loguru import logger

from .. import name_patch
from ..cache import SharedCache
from .context cimport StateDict, Context
from .functions import STATIC_FUNCTIONS, DYNAMIC_FUNCTIONS
from ..model cimport Vector, Node, Query, null_, true_, false_
from .noise import NOISE_FUNCTIONS

from libc.math cimport floor
from libc.stdint cimport int64_t
from cpython cimport PyObject, Py_INCREF, Py_DECREF
from cpython.dict cimport PyDict_GetItem, PyDict_SetItem, PyDict_Contains, PyDict_DelItem, PyDict_Copy
from cpython.exc cimport PyErr_SetFromErrno
from cpython.float cimport PyFloat_FromDouble
from cpython.list cimport PyList_New, PyList_GET_ITEM, PyList_SET_ITEM
from cpython.mem cimport PyMem_Malloc, PyMem_Free, PyMem_Realloc
from cpython.object cimport PyObject_Call, PyObject_CallObject, PyObject_HasAttrString
from cpython.set cimport PySet_Add
from cpython.tuple cimport PyTuple_New, PyTuple_GET_ITEM, PyTuple_SET_ITEM, PyTuple_GET_SIZE


cdef extern from "Python.h":
    ctypedef int64_t _PyTime_t
    _PyTime_t _PyTime_GetPerfCounter() noexcept nogil
    double _PyTime_AsSecondsDouble(_PyTime_t t) noexcept nogil


cdef inline double perf_counter() noexcept nogil:
    return _PyTime_AsSecondsDouble(_PyTime_GetPerfCounter())


logger = name_patch(logger, __name__)

cdef const char* ContextFunc = "context_func\0"

cdef dict static_builtins = {
    'true': true_,
    'false': false_,
    'null': null_,
}
static_builtins.update(STATIC_FUNCTIONS)
static_builtins.update(NOISE_FUNCTIONS)

def debug(value):
    return value

cdef object _debug_func = debug

cdef dict dynamic_builtins = {
    'debug': Vector(_debug_func),
}
dynamic_builtins.update(DYNAMIC_FUNCTIONS)

cdef dict all_builtins = {}
all_builtins.update(dynamic_builtins)
all_builtins.update(static_builtins)

cdef int* StatsCount = NULL
cdef double* StatsDuration = NULL
cdef double CallOutDuration = 0
cdef int CallOutCount = 0

cdef enum OpCode:
    Add
    Append
    AppendRoot
    Attribute
    BeginFor
    BranchFalse
    BranchTrue
    Call
    CallFast
    ClearNodeScope
    Compose
    Drop
    Dup
    EndFor
    EndForCompose
    Eq
    FloorDiv
    Func
    Ge
    Gt
    Import
    IndexLiteral
    Jump
    Label
    Le
    Literal
    LiteralNode
    LiteralNodes
    LocalDrop
    LocalLoad
    LocalPush
    Lookup
    LookupLiteral
    Lt
    Mod
    Mul
    MulAdd
    Name
    Ne
    Neg
    Next
    Not
    Pos
    Pow
    Pragma
    Prepend
    PushNext
    Range
    Search
    SetNodeScope
    Slice
    SliceLiteral
    StoreGlobal
    Sub
    Tag
    TrueDiv
    Xor
    MAX

cdef dict OpCodeNames = {
    OpCode.Add: 'Add',
    OpCode.Append: 'Append',
    OpCode.AppendRoot: 'AppendRoot',
    OpCode.Attribute: 'Attribute',
    OpCode.BeginFor: 'BeginFor',
    OpCode.BranchFalse: 'BranchFalse',
    OpCode.BranchTrue: 'BranchTrue',
    OpCode.Call: 'Call',
    OpCode.CallFast: 'CallFast',
    OpCode.ClearNodeScope: 'ClearNodeScope',
    OpCode.Compose: 'Compose',
    OpCode.Drop: 'Drop',
    OpCode.Dup: 'Dup',
    OpCode.EndFor: 'EndFor',
    OpCode.EndForCompose: 'EndForCompose',
    OpCode.Eq: 'Eq',
    OpCode.FloorDiv: 'FloorDiv',
    OpCode.Func: 'Func',
    OpCode.Ge: 'Ge',
    OpCode.Gt: 'Gt',
    OpCode.Import: 'Import',
    OpCode.IndexLiteral: 'IndexLiteral',
    OpCode.Jump: 'Jump',
    OpCode.Label: 'Label',
    OpCode.Le: 'Le',
    OpCode.Literal: 'Literal',
    OpCode.LiteralNode: 'LiteralNode',
    OpCode.LiteralNodes: 'LiteralNodes',
    OpCode.LocalDrop: 'LocalDrop',
    OpCode.LocalLoad: 'LocalLoad',
    OpCode.LocalPush: 'LocalPush',
    OpCode.Lookup: 'Lookup',
    OpCode.LookupLiteral: 'LookupLiteral',
    OpCode.Lt: 'Lt',
    OpCode.Mod: 'Mod',
    OpCode.Mul: 'Mul',
    OpCode.MulAdd: 'MulAdd',
    OpCode.Name: 'Name',
    OpCode.Ne: 'Ne',
    OpCode.Neg: 'Neg',
    OpCode.Next: 'Next',
    OpCode.Not: 'Not',
    OpCode.Pos: 'Pos',
    OpCode.Pow: 'Pow',
    OpCode.Pragma: 'Pragma',
    OpCode.Prepend: 'Prepend',
    OpCode.PushNext: 'PushNext',
    OpCode.Range: 'Range',
    OpCode.Search: 'Search',
    OpCode.SetNodeScope: 'SetNodeScope',
    OpCode.Slice: 'Slice',
    OpCode.SliceLiteral: 'SliceLiteral',
    OpCode.StoreGlobal: 'StoreGlobal',
    OpCode.Sub: 'Sub',
    OpCode.Tag: 'Tag',
    OpCode.TrueDiv: 'TrueDiv',
    OpCode.Xor: 'Xor',
}


cdef initialize_stats():
    global StatsCount, StatsDuration
    StatsCount = <int*>PyMem_Malloc(OpCode.MAX * sizeof(int))
    StatsDuration = <double*>PyMem_Malloc(OpCode.MAX * sizeof(double))
    cdef int i
    for i in range(OpCode.MAX):
        StatsCount[i] = 0
        StatsDuration[i] = 0

initialize_stats()


cdef class Instruction:
    cdef readonly OpCode code

    def __init__(self, OpCode code):
        self.code = code

    def __str__(self):
        return OpCodeNames[self.code]


cdef class InstructionVector(Instruction):
    cdef readonly Vector value

    def __init__(self, OpCode code, Vector value):
        super().__init__(code)
        self.value = value

    def __str__(self):
        return f'{OpCodeNames[self.code]} {self.value!r}'


cdef class InstructionNode(Instruction):
    cdef readonly Node value

    def __init__(self, OpCode code, Node value):
        super().__init__(code)
        self.value = value

    def __str__(self):
        return f'{OpCodeNames[self.code]} {self.value!r}'


cdef class InstructionStr(Instruction):
    cdef readonly str value

    def __init__(self, OpCode code, str value):
        super().__init__(code)
        self.value = value

    def __str__(self):
        return f'{OpCodeNames[self.code]} {self.value!r}'


cdef class InstructionTuple(Instruction):
    cdef readonly tuple value

    def __init__(self, OpCode code, tuple value):
        super().__init__(code)
        self.value = value

    def __str__(self):
        return f'{OpCodeNames[self.code]} {self.value!r}'


cdef class InstructionInt(Instruction):
    cdef readonly int value

    def __init__(self, OpCode code, int value):
        super().__init__(code)
        self.value = value

    def __str__(self):
        return f'{OpCodeNames[self.code]} {self.value!r}'


cdef class InstructionIntTuple(Instruction):
    cdef readonly int ivalue
    cdef readonly tuple tvalue

    def __init__(self, OpCode code, int ivalue, tuple tvalue):
        super().__init__(code)
        self.ivalue = ivalue
        self.tvalue = tvalue

    def __str__(self):
        return f'{OpCodeNames[self.code]} {self.ivalue!r} {self.tvalue!r}'


cdef class InstructionStrTuple(Instruction):
    cdef readonly str svalue
    cdef readonly tuple tvalue

    def __init__(self, OpCode code, str svalue, tuple tvalue):
        super().__init__(code)
        self.svalue = svalue
        self.tvalue = tvalue

    def __str__(self):
        return f'{OpCodeNames[self.code]} {self.svalue!r} {self.tvalue!r}'


cdef class InstructionQuery(Instruction):
    cdef readonly Query value

    def __init__(self, OpCode code, Query value):
        super().__init__(code)
        self.value = value

    def __str__(self):
        return f'{OpCodeNames[self.code]} {self.value!r}'


cdef class InstructionLabel(Instruction):
    cdef readonly int label

    def __init__(self, int label):
        super().__init__(OpCode.Label)
        self.label = label

    def __str__(self):
        return f'.L{self.label}'


cdef class InstructionJump(Instruction):
    cdef readonly int label
    cdef readonly int offset

    def __init__(self, OpCode code, int label):
        super().__init__(code)
        self.label = label

    def __str__(self):
        if self.offset:
            return f'{OpCodeNames[self.code]} .L{self.label} ({self.offset:+d})'
        return f'{OpCodeNames[self.code]} .L{self.label}'


cdef class InstructionJumpInt(InstructionJump):
    cdef readonly int value

    def __init__(self, OpCode code, int label, int value):
        super().__init__(code, label)
        self.value = value

    def __str__(self):
        if self.offset:
            return f'{OpCodeNames[self.code]} {self.value!r} .L{self.label} ({self.offset:+d})'
        return f'{OpCodeNames[self.code]} {self.value!r} .L{self.label}'


cdef class InstructionObjectInt(Instruction):
    cdef readonly object obj
    cdef readonly int value

    def __init__(self, OpCode code, object obj, int value):
        super().__init__(code)
        self.obj = obj
        self.value = value

    def __str__(self):
        return f'{OpCodeNames[self.code]} {self.obj!r} {self.value!r}'


cdef class VectorStack:
    def __cinit__(self, int size=256):
        self.vectors = <PyObject**>PyMem_Malloc(sizeof(PyObject*) * size)
        if self.vectors == NULL:
            raise MemoryError()
        self.size = size
        self.top = -1

    def __dealloc__(self):
        cdef int i
        for i in range(self.top+1):
            Py_DECREF(<Vector>self.vectors[i])
            self.vectors[i] = NULL
        PyMem_Free(self.vectors)

    def __len__(self):
        return self.top + 1

    cpdef VectorStack copy(self):
        return copy(self)

    cpdef void drop(self, int count=1):
        if self.top+1 < count:
            raise TypeError("Insufficient items")
        drop(self, count)

    cpdef void push(self, Vector vector):
        push(self, vector)

    cpdef Vector pop(self):
        if self.top == -1:
            raise TypeError("Stack empty")
        return pop(self)

    cpdef tuple pop_tuple(self, int count):
        if self.top+1 < count:
            raise TypeError("Insufficient items")
        return pop_tuple(self, count)

    cpdef list pop_list(self, int count):
        if self.top+1 < count:
            raise TypeError("Insufficient items")
        return pop_list(self, count)

    cpdef dict pop_dict(self, tuple keys):
        if self.top+1 < len(keys):
            raise TypeError("Insufficient items")
        return pop_dict(self, keys)

    cpdef Vector pop_composed(self, int count):
        if self.top+1 < count:
            raise TypeError("Insufficient items")
        return pop_composed(self, count)

    cpdef Vector peek(self):
        if self.top == -1:
            raise TypeError("Stack empty")
        return peek(self)

    cpdef Vector peek_at(self, int offset):
        if self.top - offset <= -1:
            raise TypeError("Insufficient items")
        return peek_at(self, offset)

    cpdef void poke(self, Vector vector):
        if self.top == -1:
            raise TypeError("Stack empty")
        poke(self, vector)

    cpdef void poke_at(self, int offset, Vector vector):
        if self.top - offset <= -1:
            raise TypeError("Insufficient items")
        poke_at(self, offset, vector)

cdef int increase(VectorStack stack) except 0:
    cdef int new_size = stack.size * 2
    stack.vectors = <PyObject**>PyMem_Realloc(stack.vectors, sizeof(PyObject*) * new_size)
    if stack.vectors == NULL:
        raise MemoryError()
    stack.size = new_size
    return new_size

cdef inline VectorStack copy(VectorStack stack):
    cdef VectorStack new_stack = VectorStack.__new__(VectorStack, stack.size)
    cdef int i
    cdef PyObject* ptr
    for i in range(stack.top+1):
        ptr = stack.vectors[i]
        Py_INCREF(<Vector>ptr)
        new_stack.vectors[i] = ptr
    new_stack.top = stack.top
    return new_stack

cdef inline void drop(VectorStack stack, int n) noexcept:
    assert stack.top - n >= -1, "Stack empty"
    stack.top -= n
    cdef int i
    for i in range(1, n+1):
        Py_DECREF(<Vector>stack.vectors[stack.top+i])
        stack.vectors[stack.top+i] = NULL

cdef inline int push(VectorStack stack, Vector vector) except 0:
    stack.top += 1
    if stack.top == stack.size:
        increase(stack)
    Py_INCREF(vector)
    stack.vectors[stack.top] = <PyObject*>vector
    return stack.size

cdef inline Vector pop(VectorStack stack) noexcept:
    assert stack.top > -1, "Stack empty"
    cdef Vector vector = <Vector>stack.vectors[stack.top]
    stack.vectors[stack.top] = NULL
    stack.top -= 1
    Py_DECREF(vector)
    return vector

cdef inline tuple pop_tuple(VectorStack stack, int n):
    assert stack.top - n >= -1, "Stack empty"
    cdef tuple t = PyTuple_New(n)
    stack.top -= n
    cdef PyObject* ptr
    cdef int i, j=stack.top+1
    for i in range(n):
        ptr = stack.vectors[j]
        PyTuple_SET_ITEM(t, i, <Vector>ptr)
        stack.vectors[j] = NULL
        j += 1
    return t

cdef inline list pop_list(VectorStack stack, int n):
    assert stack.top - n >= -1, "Stack empty"
    cdef list t = PyList_New(n)
    stack.top -= n
    cdef PyObject* ptr
    cdef int i, j=stack.top+1
    for i in range(n):
        ptr = stack.vectors[j]
        PyList_SET_ITEM(t, i, <Vector>ptr)
        stack.vectors[j] = NULL
        j += 1
    return t

cdef inline dict pop_dict(VectorStack stack, tuple keys):
    cdef int n = len(keys)
    assert stack.top - n >= -1, "Stack empty"
    cdef dict t = {}
    stack.top -= n
    cdef int next = stack.top + 1
    cdef PyObject* ptr
    cdef int i
    for i in range(n):
        ptr = stack.vectors[next]
        PyDict_SetItem(t, <object>PyTuple_GET_ITEM(keys, i), <Vector>ptr)
        stack.vectors[next] = NULL
        Py_DECREF(<Vector>ptr)
        next += 1
    return t

cdef inline Vector pop_composed(VectorStack stack, int m):
    assert stack.top - m >= -1, "Stack empty"
    if m == 1:
        return pop(stack)
    if m == 0:
        return null_
    stack.top -= m
    cdef int i, j=0, k, n=0, base=stack.top+1
    cdef bint numeric = True
    cdef PyObject* ptr
    for i in range(base, base+m):
        ptr = stack.vectors[i]
        if (<Vector>ptr).objects is not None:
            numeric = False
        n += (<Vector>ptr).length
    if n == 0:
        for i in range(base, base+m):
            ptr = stack.vectors[i]
            Py_DECREF(<object>ptr)
            stack.vectors[i] = NULL
        return null_
    cdef Vector result = Vector.__new__(Vector)
    if numeric:
        result.allocate_numbers(n)
        for i in range(base, base+m):
            ptr = stack.vectors[i]
            for k in range((<Vector>ptr).length):
                result.numbers[j] = (<Vector>ptr).numbers[k]
                j += 1
            Py_DECREF(<object>ptr)
            stack.vectors[i] = NULL
        return result
    cdef list vobjects, objects=PyList_New(n)
    cdef PyObject* itemptr
    for i in range(base, base+m):
        ptr = stack.vectors[i]
        if (<Vector>ptr).objects is None:
            for k in range((<Vector>ptr).length):
                obj = PyFloat_FromDouble((<Vector>ptr).numbers[k])
                Py_INCREF(obj)
                PyList_SET_ITEM(objects, j, obj)
                j += 1
        else:
            vobjects = (<Vector>ptr).objects
            for k in range((<Vector>ptr).length):
                itemptr = PyList_GET_ITEM(vobjects, k)
                Py_INCREF(<object>itemptr)
                PyList_SET_ITEM(objects, j, <object>itemptr)
                j += 1
        Py_DECREF(<object>ptr)
        stack.vectors[i] = NULL
    result.objects = objects
    result.length = n
    return result

cdef inline Vector peek(VectorStack stack) noexcept:
    assert stack.top > -1, "Stack empty"
    return <Vector>stack.vectors[stack.top]

cdef inline Vector peek_at(VectorStack stack, int offset) noexcept:
    assert stack.top-offset > -1, "Stack empty"
    return <Vector>stack.vectors[stack.top-offset]

cdef inline void poke(VectorStack stack, Vector vector) noexcept:
    assert stack.top > -1, "Stack empty"
    Py_DECREF(<Vector>stack.vectors[stack.top])
    Py_INCREF(vector)
    stack.vectors[stack.top] = <PyObject*>vector

cdef inline void poke_at(VectorStack stack, int offset, Vector vector) noexcept:
    assert stack.top-offset > -1, "Stack empty"
    Py_DECREF(<Vector>stack.vectors[stack.top-offset])
    Py_INCREF(vector)
    stack.vectors[stack.top-offset] = <PyObject*>vector


cdef class Function:
    cdef readonly str __name__
    cdef readonly tuple parameters
    cdef readonly tuple defaults
    cdef readonly Program program
    cdef readonly VectorStack lvars
    cdef readonly object root_path


cdef class LoopSource:
    cdef Vector source
    cdef int position
    cdef int iterations


def log_vm_stats():
    cdef list stats
    cdef double duration, total=0
    cdef int count, code
    cdef int i
    cdef double start, end, overhead, per_execution
    start = perf_counter()
    for count in range(10000):
        end = perf_counter()
    overhead = (end - start) / 10000
    stats = []
    if CallOutCount:
        duration = max(0, CallOutDuration - CallOutCount*overhead)
        stats.append((duration, CallOutCount, '(native funcs)'))
        total += duration
    for i in range(<int>OpCode.MAX):
        if StatsCount[i]:
            duration = max(0, StatsDuration[i] - StatsCount[i]*overhead)
            stats.append((duration, StatsCount[i], OpCodeNames[i]))
            total += duration
    stats.sort(reverse=True)
    logger.info("VM execution statistics:")
    for duration, count, name in stats:
        per_execution = duration / count * 1e6
        if per_execution < 1:
            logger.info("- {:15s} {:9d} x {:8.0f}ns = {:7.3f}s ({:4.1f}%)", name, count, per_execution*1000,
                        duration, 100*duration/total)
        else:
            logger.info("- {:15s} {:9d} x {:8.3f}µs = {:7.3f}s ({:4.1f}%)", name, count, per_execution,
                        duration, 100*duration/total)


cdef inline void call_helper(Context context, VectorStack stack, object function, tuple args, dict kwargs, bint record_stats, double* duration):
    global CallOutDuration, CallOutCount
    cdef int i, top, lvars_top, n=PyTuple_GET_SIZE(args), m
    cdef Function func
    cdef double call_duration
    cdef tuple parameters, defaults, context_args
    cdef VectorStack lvars
    cdef PyObject* obj
    if type(function) is Function:
        func = <Function>function
        lvars = func.lvars
        parameters = func.parameters
        defaults = func.defaults
        m = PyTuple_GET_SIZE(parameters)
        for i in range(m):
            if i < n:
                push(lvars, <Vector>PyTuple_GET_ITEM(args, i))
            elif kwargs is not None and (obj := PyDict_GetItem(kwargs, <object>PyTuple_GET_ITEM(parameters, i))) != NULL:
                push(lvars, <Vector>obj)
            else:
                push(lvars, <Vector>PyTuple_GET_ITEM(defaults, i))
        lvars_top = lvars.top
        top = stack.top
        saved_path = context.path
        context.path = func.root_path
        if record_stats:
            call_duration = -perf_counter()
        func.program._execute(context, stack, lvars, record_stats)
        if record_stats:
            call_duration += perf_counter()
            duration[0] = duration[0] - call_duration
        assert stack.top == top + 1, "Bad function return stack"
        assert lvars.top == lvars_top, "Bad function return lvars"
        drop(lvars, m)
        context.path = saved_path
    elif function is _debug_func and n == 1 and kwargs is None:
        obj = PyTuple_GET_ITEM(args, 0)
        PySet_Add(context.logs, (<Vector>obj).repr())
        push(stack, <Vector>obj)
    else:
        if PyObject_HasAttrString(function, ContextFunc):
            context_args = PyTuple_New(n+1)
            Py_INCREF(context)
            PyTuple_SET_ITEM(context_args, 0, context)
            for i in range(n):
                obj = PyTuple_GET_ITEM(args, i)
                Py_INCREF(<object>obj)
                PyTuple_SET_ITEM(context_args, i+1, <object>obj)
            args = context_args
        if record_stats:
            call_duration = -perf_counter()
        try:
            if kwargs is None:
                push(stack, <Vector>PyObject_CallObject(function, args))
            else:
                push(stack, <Vector>PyObject_Call(function, args, kwargs))
        except Exception as exc:
            PySet_Add(context.errors, f"Error calling {function!r}\n{str(exc)}")
            push(stack, null_)
        if record_stats:
            call_duration += perf_counter()
            CallOutDuration += call_duration
            CallOutCount += 1
            duration[0] = duration[0] - call_duration


cdef inline dict import_module(Context context, str filename, bint record_stats, double* duration):
    cdef Context import_context
    cdef Program program = SharedCache.get_with_root(filename, context.path).read_flitter_program()
    if program is not None:
        import_context = context
        while import_context is not None:
            if import_context.path is program.path:
                PySet_Add(context.errors, f"Circular import of {filename}")
                break
            import_context = import_context.parent
        else:
            import_context = Context.__new__(Context)
            import_context.parent = context
            import_context.errors = context.errors
            import_context.logs = context.logs
            import_context.graph = context.graph
            import_context.pragmas = context.pragmas
            import_context.state = context.state
            import_context.variables = {}
            import_context.path = program.path
            if record_stats:
                duration[0] += perf_counter()
            program._execute(import_context, None, None, record_stats)
            if record_stats:
                duration[0] -= perf_counter()
            assert program.stack.top == -1, "Bad stack"
            assert program.lvars.top == -1, "Bad lvars"
            return import_context.variables
    return None


cdef class Program:
    def __cinit__(self):
        self.instructions = []
        self.linked = False
        self.stack = VectorStack.__new__(VectorStack)
        self.lvars = VectorStack.__new__(VectorStack)
        self.next_label = 1

    def __len__(self):
        return len(self.instructions)

    def __str__(self):
        return '\n'.join(str(instruction) for instruction in self.instructions)

    def set_path(self, object path):
        self.path = path

    def set_top(self, object top):
        self.top = top

    def run(self, StateDict state=None, dict variables=None, bint record_stats=False):
        cdef dict context_vars = None
        cdef str key
        if state is None:
            state = StateDict()
        if variables is not None:
            context_vars = {}
            for key, value in variables.items():
                context_vars[key] = Vector._coerce(value)
        cdef Context context = Context(state=state, variables=context_vars, path=self.path)
        self._execute(context, None, None, record_stats)
        assert self.stack.top == -1, "Bad stack"
        assert self.lvars.top == -1, "Bad lvars"
        return context

    cpdef void link(self):
        cdef Instruction instruction
        cdef int label, address, target
        cdef list addresses
        cdef InstructionJump jump
        cdef dict jumps={}, labels={}
        for address, instruction in enumerate(self.instructions):
            if instruction.code == OpCode.Label:
                labels[(<InstructionLabel>instruction).label] = address
            elif isinstance(instruction, InstructionJump):
                (<list>jumps.setdefault((<InstructionJump>instruction).label, [])).append(address)
        for label, addresses in jumps.items():
            target = labels[label]
            for address in addresses:
                jump = self.instructions[address]
                jump.offset = target - address
        self.linked = True

    cpdef void optimize(self):
        cdef Instruction instruction, last=None
        cdef list instructions=[]
        cdef int n
        assert not self.linked, "Cannot optimize a linked program"
        for instruction in self.instructions:
            if instructions:
                last = instructions[len(instructions)-1]
                if last.code == OpCode.Compose:
                    if instruction.code == OpCode.Compose:
                        instructions.pop()
                        n = (<InstructionInt>instruction).value - 1 + (<InstructionInt>last).value
                        instruction = InstructionInt(OpCode.Compose, n)
                    elif instruction.code == OpCode.Append:
                        instructions.pop()
                        n = (<InstructionInt>instruction).value - 1 + (<InstructionInt>last).value
                        instruction = InstructionInt(OpCode.Append, n)
                elif last.code == OpCode.Mul:
                    if instruction.code == OpCode.Add:
                        instructions.pop()
                        instruction = Instruction(OpCode.MulAdd)
                elif last.code == OpCode.Literal:
                    if (<InstructionVector>last).value.length == 0 \
                            and (instruction.code == OpCode.Append or instruction.code == OpCode.AppendRoot):
                        instructions.pop()
                        continue
            instructions.append(instruction)
        self.instructions = instructions

    cpdef int new_label(self):
        label = self.next_label
        self.next_label += 1
        return label

    cpdef void dup(self):
        self.instructions.append(Instruction(OpCode.Dup))

    cpdef void drop(self, int count=1):
        self.instructions.append(InstructionInt(OpCode.Drop, count))

    cpdef void label(self, int label):
        self.instructions.append(InstructionLabel(label))

    cpdef void jump(self, int label):
        self.instructions.append(InstructionJump(OpCode.Jump, label))

    cpdef void branch_true(self, int label):
        self.instructions.append(InstructionJump(OpCode.BranchTrue, label))

    cpdef void branch_false(self, int label):
        self.instructions.append(InstructionJump(OpCode.BranchFalse, label))

    cpdef void pragma(self, str name):
        self.instructions.append(InstructionStr(OpCode.Pragma, name))

    cpdef void import_(self, tuple names):
        self.instructions.append(InstructionTuple(OpCode.Import, names))

    cpdef void literal(self, value):
        cdef Vector vector = Vector._coerce(value)
        if vector.objects is not None:
            if vector.length == 1:
                obj = vector.objects[0]
                if type(obj) is Node:
                    self.instructions.append(InstructionNode(OpCode.LiteralNode, <Node>obj))
                    return
            else:
                for obj in vector.objects:
                    if type(obj) is Node:
                        self.instructions.append(InstructionVector(OpCode.LiteralNodes, vector))
                        return
        self.instructions.append(InstructionVector(OpCode.Literal, vector))

    cpdef void local_push(self, int count):
        self.instructions.append(InstructionInt(OpCode.LocalPush, count))

    cpdef void local_load(self, int offset):
        self.instructions.append(InstructionInt(OpCode.LocalLoad, offset))

    cpdef void local_drop(self, int count):
        self.instructions.append(InstructionInt(OpCode.LocalDrop, count))

    cpdef void name(self, str name):
        self.instructions.append(InstructionStr(OpCode.Name, name))

    cpdef void lookup(self):
        self.instructions.append(Instruction(OpCode.Lookup))

    cpdef void lookup_literal(self, Vector value):
        self.instructions.append(InstructionVector(OpCode.LookupLiteral, value))

    cpdef void range(self):
        self.instructions.append(Instruction(OpCode.Range))

    cpdef void neg(self):
        self.instructions.append(Instruction(OpCode.Neg))

    cpdef void pos(self):
        self.instructions.append(Instruction(OpCode.Pos))

    cpdef void not_(self):
        self.instructions.append(Instruction(OpCode.Not))

    cpdef void add(self):
        self.instructions.append(Instruction(OpCode.Add))

    cpdef void sub(self):
        self.instructions.append(Instruction(OpCode.Sub))

    cpdef void mul(self):
        self.instructions.append(Instruction(OpCode.Mul))

    cpdef void mul_add(self):
        self.instructions.append(Instruction(OpCode.MulAdd))

    cpdef void truediv(self):
        self.instructions.append(Instruction(OpCode.TrueDiv))

    cpdef void floordiv(self):
        self.instructions.append(Instruction(OpCode.FloorDiv))

    cpdef void mod(self):
        self.instructions.append(Instruction(OpCode.Mod))

    cpdef void pow(self):
        self.instructions.append(Instruction(OpCode.Pow))

    cpdef void eq(self):
        self.instructions.append(Instruction(OpCode.Eq))

    cpdef void ne(self):
        self.instructions.append(Instruction(OpCode.Ne))

    cpdef void gt(self):
        self.instructions.append(Instruction(OpCode.Gt))

    cpdef void lt(self):
        self.instructions.append(Instruction(OpCode.Lt))

    cpdef void ge(self):
        self.instructions.append(Instruction(OpCode.Ge))

    cpdef void le(self):
        self.instructions.append(Instruction(OpCode.Le))

    cpdef void xor(self):
        self.instructions.append(Instruction(OpCode.Xor))

    cpdef void slice(self):
        self.instructions.append(Instruction(OpCode.Slice))

    cpdef void slice_literal(self, Vector value):
        if value.length == 1 and value.numbers != NULL:
            self.instructions.append(InstructionInt(OpCode.IndexLiteral, <int>floor(value.numbers[0])))
        else:
            self.instructions.append(InstructionVector(OpCode.SliceLiteral, value))

    cpdef void call(self, int count, tuple names=None):
        self.instructions.append(InstructionIntTuple(OpCode.Call, count, names))

    cpdef void call_fast(self, object function, int count):
        self.instructions.append(InstructionObjectInt(OpCode.CallFast, function, count))

    cpdef void tag(self, str name):
        self.instructions.append(InstructionStr(OpCode.Tag, name))

    cpdef void attribute(self, str name):
        self.instructions.append(InstructionStr(OpCode.Attribute, name))

    cpdef void append(self, int count=1):
        self.instructions.append(InstructionInt(OpCode.Append, count))

    cpdef void prepend(self):
        self.instructions.append(Instruction(OpCode.Prepend))

    cpdef void compose(self, int count):
        self.instructions.append(InstructionInt(OpCode.Compose, count))

    cpdef void set_node_scope(self):
        self.instructions.append(Instruction(OpCode.SetNodeScope))

    cpdef void clear_node_scope(self):
        self.instructions.append(Instruction(OpCode.ClearNodeScope))

    cpdef void begin_for(self):
        self.instructions.append(Instruction(OpCode.BeginFor))

    cpdef void next(self, int count, int label):
        self.instructions.append(InstructionJumpInt(OpCode.Next, label, count))

    cpdef void push_next(self, int label):
        self.instructions.append(InstructionJump(OpCode.PushNext, label))

    cpdef void end_for(self):
        self.instructions.append(Instruction(OpCode.EndFor))

    cpdef void end_for_compose(self):
        self.instructions.append(Instruction(OpCode.EndForCompose))

    cpdef void store_global(self, str name):
        self.instructions.append(InstructionStr(OpCode.StoreGlobal, name))

    cpdef void search(self, Query query):
        self.instructions.append(InstructionQuery(OpCode.Search, query))

    cpdef void func(self, str name, tuple parameters):
        self.instructions.append(InstructionStrTuple(OpCode.Func, name, parameters))

    cpdef void append_root(self):
        self.instructions.append(Instruction(OpCode.AppendRoot))

    def execute(self, Context context, list lvars=None, bint record_stats=False):
        """This is a test-harness function. Do not use."""
        if not self.linked:
            self.link()
        cdef VectorStack lvars_stack = VectorStack()
        cdef Vector vector
        if lvars:
            for vector in lvars:
                lvars_stack.push(vector)
        cdef VectorStack stack = VectorStack()
        self._execute(context, stack, lvars_stack, record_stats)
        if lvars is not None:
            lvars.clear()
            while len(lvars_stack):
                lvars.insert(0, lvars_stack.pop())
        return stack.pop_list(len(stack))

    cdef void _execute(self, Context context, VectorStack stack, VectorStack lvars, bint record_stats):
        global CallOutCount, CallOutDuration
        if stack is None:
            stack = self.stack
        if lvars is None:
            lvars = self.lvars
        cdef int i, j, m, n, pc=0, program_end=len(self.instructions)
        cdef dict node_scope=None, variables=context.variables, builtins=all_builtins, state=context.state._state
        cdef list loop_sources=[]
        cdef LoopSource loop_source = None
        cdef double duration, call_out_duration

        cdef Instruction instruction=None
        cdef str filename
        cdef object name, arg, node
        cdef tuple names, args
        cdef Vector r1, r2, r3
        cdef dict attributes, import_variables, kwargs
        cdef list values
        cdef Query query
        cdef Function function
        cdef PyObject* objptr

        assert self.linked, "Program has not been linked"

        try:
            while 0 <= pc < program_end:
                instruction = <Instruction>PyList_GET_ITEM(self.instructions, pc)
                pc += 1
                if record_stats:
                    duration = -perf_counter()

                if instruction.code == OpCode.Dup:
                    push(stack, peek(stack))

                elif instruction.code == OpCode.Drop:
                    drop(stack, (<InstructionInt>instruction).value)

                elif instruction.code == OpCode.Label:
                    pass

                elif instruction.code == OpCode.Jump:
                    pc += (<InstructionJump>instruction).offset

                elif instruction.code == OpCode.BranchTrue:
                    if pop(stack).as_bool():
                        pc += (<InstructionJump>instruction).offset

                elif instruction.code == OpCode.BranchFalse:
                    if not pop(stack).as_bool():
                        pc += (<InstructionJump>instruction).offset

                elif instruction.code == OpCode.Pragma:
                    PyDict_SetItem(context.pragmas, (<InstructionStr>instruction).value, pop(stack))

                elif instruction.code == OpCode.Import:
                    filename = pop(stack).as_string()
                    names = (<InstructionTuple>instruction).value
                    n = PyTuple_GET_SIZE(names)
                    import_variables = import_module(context, filename, record_stats, &duration)
                    if import_variables is not None:
                        for i in range(n):
                            objptr = PyDict_GetItem(import_variables, <object>PyTuple_GET_ITEM(names, i))
                            if objptr != NULL:
                                push(lvars, <Vector>objptr)
                            else:
                                PySet_Add(context.errors, f"Unable to import '{<str>PyTuple_GET_ITEM(names, i)}' from '{filename}'")
                                push(lvars, null_)
                    else:
                        PySet_Add(context.errors, f"Unable to import from '{filename}'")
                        for i in range(n):
                            push(lvars, null_)
                    filename = names = import_variables = None

                elif instruction.code == OpCode.Literal:
                    push(stack, (<InstructionVector>instruction).value)

                elif instruction.code == OpCode.LiteralNode:
                    r1 = Vector.__new__(Vector)
                    r1.objects = [(<InstructionNode>instruction).value.copy()]
                    r1.length = 1
                    push(stack, r1)
                    r1 = None

                elif instruction.code == OpCode.LiteralNodes:
                    push(stack, (<InstructionVector>instruction).value.copynodes())

                elif instruction.code == OpCode.LocalDrop:
                    drop(lvars, (<InstructionInt>instruction).value)

                elif instruction.code == OpCode.LocalLoad:
                    push(stack, peek_at(lvars, (<InstructionInt>instruction).value).copynodes())

                elif instruction.code == OpCode.LocalPush:
                    r1 = pop(stack)
                    n = (<InstructionInt>instruction).value
                    if n == 1:
                        push(lvars, r1)
                    else:
                        for i in range(n):
                            push(lvars, r1.item(i))
                    r1 = None

                elif instruction.code == OpCode.Name:
                    name = (<InstructionStr>instruction).value
                    objptr = PyDict_GetItem(variables, name)
                    if objptr == NULL:
                        objptr = PyDict_GetItem(builtins, name)
                    if objptr == NULL and node_scope is not None:
                        objptr = PyDict_GetItem(node_scope, name)
                    if objptr != NULL:
                        push(stack, <Vector>objptr)
                    else:
                        push(stack, null_)
                        PySet_Add(context.errors, f"Unbound name '{<str>name}'")
                    name = None
                    objptr = NULL

                elif instruction.code == OpCode.Lookup:
                    objptr = PyDict_GetItem(state, peek(stack))
                    if objptr != NULL:
                        poke(stack, <Vector>objptr)
                    else:
                        poke(stack, null_)
                    objptr = NULL

                elif instruction.code == OpCode.LookupLiteral:
                    objptr = PyDict_GetItem(state, (<InstructionVector>instruction).value)
                    if objptr != NULL:
                        push(stack, <Vector>objptr)
                    else:
                        push(stack, null_)
                    objptr = NULL

                elif instruction.code == OpCode.Range:
                    r3 = pop(stack)
                    r2 = pop(stack)
                    r1 = Vector.__new__(Vector)
                    r1.fill_range(peek(stack), r2, r3)
                    poke(stack, r1)
                    r1 = r2 = r3 = None

                elif instruction.code == OpCode.Neg:
                    poke(stack, peek(stack).neg())

                elif instruction.code == OpCode.Pos:
                    if peek(stack).objects is not None:
                        poke(stack, null_)

                elif instruction.code == OpCode.Not:
                    poke(stack, false_ if peek(stack).as_bool() else true_)

                elif instruction.code == OpCode.Add:
                    r1 = pop(stack)
                    poke(stack, peek(stack).add(r1))
                    r1 = None

                elif instruction.code == OpCode.Sub:
                    r1 = pop(stack)
                    poke(stack, peek(stack).sub(r1))
                    r1 = None

                elif instruction.code == OpCode.Mul:
                    r1 = pop(stack)
                    poke(stack, peek(stack).mul(r1))
                    r1 = None

                elif instruction.code == OpCode.MulAdd:
                    r2 = pop(stack)
                    r1 = pop(stack)
                    poke(stack, peek(stack).mul_add(r1, r2))
                    r1 = r2 = None

                elif instruction.code == OpCode.TrueDiv:
                    r1 = pop(stack)
                    poke(stack, peek(stack).truediv(r1))
                    r1 = None

                elif instruction.code == OpCode.FloorDiv:
                    r1 = pop(stack)
                    poke(stack, peek(stack).floordiv(r1))
                    r1 = None

                elif instruction.code == OpCode.Mod:
                    r1 = pop(stack)
                    poke(stack, peek(stack).mod(r1))
                    r1 = None

                elif instruction.code == OpCode.Pow:
                    r1 = pop(stack)
                    poke(stack, peek(stack).pow(r1))
                    r1 = None

                elif instruction.code == OpCode.Eq:
                    r1 = pop(stack)
                    poke(stack, peek(stack).eq(r1))
                    r1 = None

                elif instruction.code == OpCode.Ne:
                    r1 = pop(stack)
                    poke(stack, peek(stack).ne(r1))
                    r1 = None

                elif instruction.code == OpCode.Gt:
                    r1 = pop(stack)
                    poke(stack, peek(stack).gt(r1))
                    r1 = None

                elif instruction.code == OpCode.Lt:
                    r1 = pop(stack)
                    poke(stack, peek(stack).lt(r1))
                    r1 = None

                elif instruction.code == OpCode.Ge:
                    r1 = pop(stack)
                    poke(stack, peek(stack).ge(r1))
                    r1 = None

                elif instruction.code == OpCode.Le:
                    r1 = pop(stack)
                    poke(stack, peek(stack).le(r1))
                    r1 = None

                elif instruction.code == OpCode.Xor:
                    r2 = pop(stack)
                    r1 = peek(stack)
                    if not r1.as_bool():
                        poke(stack, r2)
                    elif r2.as_bool():
                        poke(stack, false_)
                    r1 = r2 = None

                elif instruction.code == OpCode.Slice:
                    r1 = pop(stack)
                    poke(stack, peek(stack).slice(r1))
                    r1 = None

                elif instruction.code == OpCode.SliceLiteral:
                    poke(stack, peek(stack).slice((<InstructionVector>instruction).value))

                elif instruction.code == OpCode.IndexLiteral:
                    poke(stack, peek(stack).item((<InstructionInt>instruction).value))

                elif instruction.code == OpCode.Call:
                    r1 = pop(stack)
                    if (<InstructionIntTuple>instruction).tvalue is not None:
                        kwargs = pop_dict(stack, (<InstructionIntTuple>instruction).tvalue)
                    else:
                        kwargs = None
                    n = (<InstructionIntTuple>instruction).ivalue
                    args = pop_tuple(stack, n) if n else ()
                    if r1.objects is not None:
                        for i in range(r1.length):
                            call_helper(context, stack, <object>PyList_GET_ITEM(r1.objects, i), args, kwargs, record_stats, &duration)
                        if r1.length > 1:
                            push(stack, pop_composed(stack, r1.length))
                    else:
                        push(stack, null_)
                    r1 = kwargs = args = None

                elif instruction.code == OpCode.CallFast:
                    if record_stats:
                        call_duration = -perf_counter()
                    args = pop_tuple(stack, (<InstructionObjectInt>instruction).value)
                    try:
                        r1 = <Vector>PyObject_CallObject((<InstructionObjectInt>instruction).obj, args)
                    except Exception as exc:
                        PySet_Add(context.errors, f"Error calling {function!r}\n{str(exc)}")
                        r1 = null_
                    if record_stats:
                        call_duration += perf_counter()
                        CallOutDuration += call_duration
                        CallOutCount += 1
                        duration -= call_duration
                    push(stack, r1)
                    r1 = args = None

                elif instruction.code == OpCode.Func:
                    function = Function.__new__(Function)
                    function.__name__ = (<InstructionStrTuple>instruction).svalue
                    function.parameters = (<InstructionStrTuple>instruction).tvalue
                    function.program = <Program>PyList_GET_ITEM(pop(stack).objects, 0)
                    function.lvars = copy(lvars)
                    function.root_path = context.path
                    n = PyTuple_GET_SIZE(function.parameters)
                    function.defaults = pop_tuple(stack, n) if n else ()
                    r1 = <Vector>Vector.__new__(Vector)
                    r1.objects = [function]
                    r1.length = 1
                    push(stack, r1)
                    function = r1 = None

                elif instruction.code == OpCode.Tag:
                    name = (<InstructionStr>instruction).value
                    r1 = peek(stack)
                    if r1.objects is not None:
                        for i in range(r1.length):
                            objptr = PyList_GET_ITEM(r1.objects, i)
                            if type(<object>objptr) is Node:
                                if (<Node>objptr)._tags is None:
                                    (<Node>objptr)._tags = set()
                                PySet_Add((<Node>objptr)._tags, name)
                    name = r1 = None
                    objptr = NULL

                elif instruction.code == OpCode.Attribute:
                    r2 = pop(stack)
                    r1 = peek(stack)
                    if r1.objects is not None:
                        name = (<InstructionStr>instruction).value
                        for i in range(r1.length):
                            objptr = PyList_GET_ITEM(r1.objects, i)
                            if type(<object>objptr) is Node:
                                attributes = (<Node>objptr)._attributes
                                if (<Node>objptr)._attributes_shared:
                                    (<Node>objptr)._attributes = attributes = PyDict_Copy(attributes)
                                    (<Node>objptr)._attributes_shared = False
                                if r2.length:
                                    PyDict_SetItem(attributes, name, r2)
                                elif PyDict_Contains(attributes, name) == 1:
                                    PyDict_DelItem(attributes, name)
                    r1 = r2 = name = attributes = None
                    objptr = NULL

                elif instruction.code == OpCode.Append:
                    m = (<InstructionInt>instruction).value
                    r1 = peek_at(stack, m)
                    if r1.objects is not None:
                        n = r1.length - 1
                        for i in range(m-1, -1, -1):
                            r2 = peek_at(stack, i)
                            if r2.objects is not None:
                                for j in range(r1.length):
                                    objptr = PyList_GET_ITEM(r1.objects, j)
                                    if type(<object>objptr) is Node:
                                        (<Node>objptr).append_vector(r2, j != n)
                    drop(stack, m)
                    r1 = r2 = None
                    objptr = NULL

                elif instruction.code == OpCode.Prepend:
                    r2 = pop(stack)
                    r1 = peek(stack)
                    if r1.objects is not None and r2.objects is not None:
                        n = r1.length - 1
                        for i, node in enumerate(r1.objects):
                            if type(node) is Node:
                                if i == n:
                                    for child in reversed(r2.objects):
                                        if type(child) is Node:
                                            (<Node>node).insert(<Node>child)
                                else:
                                    for child in reversed(r2.objects):
                                        if type(child) is Node:
                                            (<Node>node).insert((<Node>child).copy())
                    r1 = r2 = node = None

                elif instruction.code == OpCode.Compose:
                    push(stack, pop_composed(stack, (<InstructionInt>instruction).value))

                elif instruction.code == OpCode.BeginFor:
                    if loop_source is not None:
                        loop_sources.append(loop_source)
                    loop_source = LoopSource.__new__(LoopSource)
                    loop_source.source = pop(stack)
                    loop_source.position = 0
                    loop_source.iterations = 0

                elif instruction.code == OpCode.Next:
                    if loop_source.position >= loop_source.source.length:
                        pc += (<InstructionJump>instruction).offset
                    else:
                        n = (<InstructionJumpInt>instruction).value
                        for i in range(n-1, -1, -1):
                            poke_at(lvars, i, loop_source.source.item(loop_source.position))
                            loop_source.position += 1
                        loop_source.iterations += 1

                elif instruction.code == OpCode.PushNext:
                    if loop_source.position == loop_source.source.length:
                        pc += (<InstructionJump>instruction).offset
                    else:
                        push(stack, loop_source.source.item(loop_source.position))
                        loop_source.position += 1
                        loop_source.iterations += 1

                elif instruction.code == OpCode.EndFor:
                    if loop_sources:
                        loop_source = <LoopSource>loop_sources.pop()
                    else:
                        loop_source = None

                elif instruction.code == OpCode.EndForCompose:
                    push(stack, pop_composed(stack, loop_source.iterations))
                    if loop_sources:
                        loop_source = <LoopSource>loop_sources.pop()
                    else:
                        loop_source = None

                elif instruction.code == OpCode.SetNodeScope:
                    r1 = peek(stack)
                    if r1.objects is not None and r1.length == 1:
                        objptr = PyList_GET_ITEM(r1.objects, 0)
                        if type(<object>objptr) is Node:
                            if (<Node>objptr)._attributes_shared:
                                (<Node>objptr)._attributes = PyDict_Copy((<Node>objptr)._attributes)
                                (<Node>objptr)._attributes_shared = False
                            node_scope = (<Node>objptr)._attributes
                    r1 = None
                    objptr = NULL

                elif instruction.code == OpCode.ClearNodeScope:
                    node_scope = None

                elif instruction.code == OpCode.StoreGlobal:
                    PyDict_SetItem(variables, (<InstructionStr>instruction).value, pop(stack))

                elif instruction.code == OpCode.Search:
                    node = context.graph.first_child
                    values = []
                    query = (<InstructionQuery>instruction).value
                    while node is not None:
                        if (<Node>node)._select(query, values, query.first):
                            break
                        node = (<Node>node).next_sibling
                    if values:
                        r1 = <Vector>Vector.__new__(Vector)
                        r1.objects = values
                        r1.length = len(values)
                    else:
                        r1 = null_
                    push(stack, r1)
                    node = values = query = r1 = None

                elif instruction.code == OpCode.AppendRoot:
                    r1 = pop(stack)
                    if r1.objects is not None:
                        for i in range(r1.length):
                            objptr = PyList_GET_ITEM(r1.objects, i)
                            if type(<object>objptr) is Node:
                                if (<Node>objptr)._parent is None:
                                    context.graph.append(<Node>objptr)
                    r1 = None
                    objptr = NULL

                else:
                    raise ValueError(f"Unrecognised instruction: {instruction}")

                if record_stats:
                    duration += perf_counter()
                    StatsCount[<int>instruction.code] += 1
                    StatsDuration[<int>instruction.code] += duration

        except:
            if instruction is not None:
                logger.error("VM exception processing:\n{} <--",
                             "\n".join(str(instruction) for instruction in self.instructions[pc-5:pc]))
            raise

        assert pc == program_end, "Jump outside of program"
