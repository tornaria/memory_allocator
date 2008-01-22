#*****************************************************************************
#       Copyright (C) 2008 Robert Bradshaw <robertwb@math.washington.edu>
#
#  Distributed under the terms of the GNU General Public License (GPL)
#
#    This code is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#    General Public License for more details.
#
#  The full text of the GPL is available at:
#
#                  http://www.gnu.org/licenses/
#*****************************************************************************


include "stdsage.pxi"

cdef extern from "Python.h":
    int PyInt_AS_LONG(PyObject*)
    PyObject* PyTuple_New(Py_ssize_t size)
    PyObject* PyTuple_GET_ITEM(PyObject* t, Py_ssize_t index)
    void PyTuple_SET_ITEM(PyObject* t, Py_ssize_t index, PyObject* item)
    object PyObject_CallObject(PyObject* func, PyObject* args)
    PyObject* PyFloat_FromDouble(double d)
    void Py_DECREF(PyObject *)

cdef extern from "math.h":
    double sqrt(double)
    double pow(double, double)

    double ceil(double)
    double floor(double)

    double sin(double)
    double cos(double)
    double tan(double)

cdef extern from *:
    void* memcpy(void* dst, void* src, size_t len)

cdef inline int max(int a, int b):
    return a if a > b else b

cdef inline int min(int a, int b):
    return a if a < b else b

cdef enum:
# stack
    PUSH_ARG
    PUSH_CONST
    POP
    POP_N
    DUP

# basic arithamtic
    ADD
    SUB
    MUL
    DIV
    NEG
    ABS
    INVERT

# functional
    ONE_ARG_FUNC
    TWO_ARG_FUNC
    PY_FUNC

cdef union double_op_params:
    void* func
    double c
    int n

cdef struct fast_double_op:
    char type
    double_op_params params

# This is where we wish we had case statements...
cdef inline int process_op(fast_double_op op, double* stack, double* argv, int top) except -2:

#    print [stack[i] for i from 0 <= i <= top], ':', op.type

    cdef int i, n
    cdef PyObject* py_args

    # We have to do some trickery because Pyrex dissallows function pointer casts
    # This will be removed in a future version of Cython.
    cdef double (*f)(double)
    cdef void** fp = <void **>&f
    cdef double (*ff)(double, double)
    cdef void** ffp = <void **>&ff

    if op.type == PUSH_ARG:
        stack[top+1] = argv[op.params.n]
        return top+1

    elif op.type == PUSH_CONST:
        stack[top+1] = op.params.c
        return top+1

    elif op.type == POP:
        return top-1

    elif op.type == POP_N:
        return top-op.params.n

    elif op.type == DUP:
        stack[top+1] = stack[top]
        return top+1

    elif op.type == ADD:
        stack[top-1] += stack[top]
        return top-1

    elif op.type == SUB:
        stack[top-1] -= stack[top]
        return top-1

    elif op.type == MUL:
        stack[top-1] *= stack[top]
        return top-1

    elif op.type == DIV:
        stack[top-1] /= stack[top]
        return top-1

    elif op.type == NEG:
        stack[top] = -stack[top]
        return top

    elif op.type == ABS:
        if stack[top] < 0:
            stack[top] = -stack[top]
        return top

    elif op.type == INVERT:
        stack[top] = 1/stack[top]
        return top

    elif op.type == ONE_ARG_FUNC:
        fp[0] = op.params.func
        stack[top] = f(stack[top])
        return top

    elif op.type == TWO_ARG_FUNC:
        ffp[0] = op.params.func
        stack[top-1] = ff(stack[top-1], stack[top])
        return top-1

    elif op.type == PY_FUNC:
        # Even though it's python, optimize this because it'll be used often...
        # We also don't want to muddle up the other ops
        n = PyInt_AS_LONG(PyTuple_GET_ITEM(op.params.func, 0))
        top = top - n + 1
        py_args = PyTuple_New(n)
        for i from 0 <= i < n:
            PyTuple_SET_ITEM(py_args, i, PyFloat_FromDouble(stack[top+i]))
        stack[top] = PyObject_CallObject(PyTuple_GET_ITEM(op.params.func, 1), py_args)
        Py_DECREF(py_args)
        return top


cdef class FastDoubleFunc:
    """
    This class is for fast evaluation of algebraic expressions over
    the real numbers (e.g. for plotting). It represents an expression
    as a stack-based series of operations.

    EXAMPLES:
        sage: from sage.ext.fast_eval import FastDoubleFunc
        sage: f = FastDoubleFunc('const', 1.5) # the constant function
        sage: f()
        1.5
        sage: g = FastDoubleFunc('arg', 0) # the first argument
        sage: g(5)
        5.0
        sage: h = f+g
        sage: h(17)
        18.5
        sage: h = h.sin()
        sage: h(pi/2-1.5)
        1.0
        sage: h.is_pure_c()
        True

    We can wrap Python functions too:
        sage: h = FastDoubleFunc('callable', lambda x,y: x*x*x - y, g, f)
        sage: h(10)
        998.5
        sage: h.is_pure_c()
        False

    AUTHOR:
        -- Robert Bradshaw
    """
    cdef readonly int max_height
    cdef readonly int nargs
    cdef readonly int nops
    cdef fast_double_op* ops

    # need to keep this around because structs can't contain (ref-counted) python objects
    cdef py_funcs

    def __init__(self, type, param, *args):

        cdef FastDoubleFunc arg
        cdef int i

        if type == 'arg':
            self.nargs = param+1
            self.nops = 1
            self.max_height = 1
            self.ops = <fast_double_op *>sage_malloc(sizeof(fast_double_op))
            self.ops[0].type = PUSH_ARG
            self.ops[0].params.n = param

        elif type == 'const':
            self.nargs = 0
            self.nops = 1
            self.max_height = 1
            self.ops = <fast_double_op *>sage_malloc(sizeof(fast_double_op))
            self.ops[0].type = PUSH_CONST
            self.ops[0].params.c = param

        elif type == 'callable':
            py_func = len(args), param
            self.py_funcs = (py_func,) # just so it doesn't get garbage collected
            self.nops = 1
            self.nargs = 0
            for i from 0 <= i < len(args):
                a = args[i]
                if not isinstance(a, FastDoubleFunc):
                     a = FastDoubleFunc('const', a)
                     args = args[:i] + (a,) + args[i+1:]
                arg = a
                self.nops += arg.nops
                if arg.py_funcs is not None:
                    self.py_funcs += arg.py_funcs
                self.nargs = max(self.nargs, arg.nargs)
                self.max_height = max(self.max_height, arg.max_height+i)
            self.ops = <fast_double_op *>sage_malloc(sizeof(fast_double_op) * self.nops)
            if self.ops == NULL:
                raise MemoryError
            i = 0
            for arg in args:
                memcpy(self.ops + i, arg.ops, sizeof(fast_double_op) * arg.nops)
                i += arg.nops
            self.ops[self.nops-1].type = PY_FUNC
            self.ops[self.nops-1].params.func = <void *>py_func

        else:
            raise ValueError, "Unknown operation: %s" % type


    def __del__(self):
        if self.ops:
            sage_free(self.ops)

    def __call__(self, *args):
        if len(args) < self.nargs:
            raise TypeError, "Wrong number of arguments (need at least %s, got %s)" % (self.nargs, len(args))
        cdef double* argv = <double*>sage_malloc(sizeof(double) * self.nargs)
        cdef int i = 0
        for i from 0 <= i < self.nargs:
            argv[i] = args[i]
        res = self._call_c(argv)
        sage_free(argv)
        return res

    cdef double _call_c(self, double* argv) except? -2:
        cdef int i, top = -1
        cdef double* stack = <double*>sage_malloc(sizeof(double) * self.max_height)
        for i from 0 <= i < self.nops:
            top = process_op(self.ops[i], stack, argv, top)
        cdef double res = stack[0]
        sage_free(stack)
        return res

    cpdef bint is_pure_c(self):
        cdef int i
        for i from 0 <= i < self.nops:
            if self.ops[i].type == PY_FUNC:
                return 0
        return 1

    def __add__(FastDoubleFunc left, FastDoubleFunc right):
        return binop(left, right, ADD)

    def __sub__(FastDoubleFunc left, FastDoubleFunc right):
        return binop(left, right, SUB)

    def __mul__(FastDoubleFunc left, FastDoubleFunc right):
        return binop(left, right, MUL)

    def __div__(FastDoubleFunc left, FastDoubleFunc right):
        return binop(left, right, DIV)

    def __pow__(FastDoubleFunc left, right, dummy):
        """
        EXAMPLES:
            sage: from sage.ext.fast_eval import FastDoubleFunc
            sage: f = FastDoubleFunc('arg', 0)^2
            sage: f(2)
            4.0
            sage: f = FastDoubleFunc('arg', 0)^4
            sage: f(2)
            16.0
            sage: f = FastDoubleFunc('arg', 0)^-3
            sage: f(2)
            0.125
            sage: f = FastDoubleFunc('arg', 0)^FastDoubleFunc('arg', 1)
            sage: f(5,3)
            125.0
        """
        if not isinstance(right, FastDoubleFunc):
            if right == int(right):
                if right == 1:
                    return left
                elif right == 2:
                    return left.unop(DUP).unop(MUL)
                elif right == 3:
                    return left.unop(DUP).unop(DUP).unop(MUL).unop(MUL)
                elif right == 4:
                    return left.unop(DUP).unop(MUL).unop(DUP).unop(MUL)
                elif right < 0:
                    return (~left)**(-right)
            right = FastDoubleFunc('const', right)
        cdef FastDoubleFunc feval = binop(left, right, TWO_ARG_FUNC)
        feval.ops[feval.nops-1].params.func = &pow
        return feval

    def __neg__(FastDoubleFunc self):
        return self.unop(NEG)

    def __abs__(FastDoubleFunc self):
        return self.unop(ABS)

    def abs(FastDoubleFunc self):
        return self.unop(ABS)

    def __invert__(FastDoubleFunc self):
        return self.unop(INVERT)

    def ceil(self):
        return self.cfunc(&ceil)

    def floor(self):
        return self.cfunc(&floor)

    def sin(self):
        return self.cfunc(&sin)

    def cos(self):
        return self.cfunc(&cos)

    def tan(self):
        return self.cfunc(&tan)

    def sqrt(self):
        return self.cfunc(&sqrt)

    cdef FastDoubleFunc cfunc(FastDoubleFunc self, void* func):
        cdef FastDoubleFunc feval = self.unop(ONE_ARG_FUNC)
        feval.ops[feval.nops - 1].params.func = func
        return feval

    cdef FastDoubleFunc unop(FastDoubleFunc self, char type):
        cdef FastDoubleFunc feval = PY_NEW(FastDoubleFunc)
        feval.nargs = self.nargs
        feval.nops = self.nops + 1
        feval.max_height = self.max_height
        feval.ops = <fast_double_op *>sage_malloc(sizeof(fast_double_op) * feval.nops)
        memcpy(feval.ops, self.ops, sizeof(fast_double_op) * self.nops)
        feval.ops[feval.nops - 1].type = type
        feval.py_funcs = self.py_funcs
        return feval

cdef FastDoubleFunc binop(FastDoubleFunc left, FastDoubleFunc right, char type):
    cdef FastDoubleFunc feval = PY_NEW(FastDoubleFunc)
    feval.nargs = max(left.nargs, right.nargs)
    feval.nops = left.nops + right.nops + 1
    feval.max_height = max(left.max_height, right.max_height+1)
    feval.ops = <fast_double_op *>sage_malloc(sizeof(fast_double_op) * feval.nops)
    memcpy(feval.ops, left.ops, sizeof(fast_double_op) * left.nops)
    memcpy(feval.ops + left.nops, right.ops, sizeof(fast_double_op) * right.nops)
    feval.ops[feval.nops - 1].type = type
    if left.py_funcs is None:
        feval.py_funcs = right.py_funcs
    elif right.py_funcs is None:
        feval.py_funcs = left.py_funcs
    else:
        feval.py_funcs = left.py_funcs + right.py_funcs
    return feval


def fast_float_constant(x):
    """
    Return a fast-to-evaluate constant.

    EXAMPLES:
        sage: from sage.ext.fast_eval import fast_float_constant
        sage: f = fast_float_constant(-2.75)
        sage: f()
        -2.75
    """
    return FastDoubleFunc('const', x)

def fast_float_arg(n):
    """
    Return a fast-to-evaluate argument selector.

    INPUT:
        n -- the (zero-indexed) argument to select

    EXAMPLES:
        sage: from sage.ext.fast_eval import fast_float_arg
        sage: f = fast_float_arg(0)
        sage: f(1,2)
        1.0
        sage: f = fast_float_arg(1)
        sage: f(1,2)
        2.0
    """
    return FastDoubleFunc('arg', n)

def fast_float_func(f, *args):
    """
    Returns a wraper around a python function.

    INPUT:
        f -- a callable python object
        args -- a list of FastDoubleFunc inputs

    EXAMPLES:
        sage: from sage.ext.fast_eval import fast_float_func, fast_float_arg
        sage: f = fast_float_arg(0)
        sage: g = fast_float_arg(1)
        sage: h = fast_float_func(lambda x,y: x-y, f, g)
        sage: h(5, 10)
        -5.0
    """
    return FastDoubleFunc('callable', f, *args)
