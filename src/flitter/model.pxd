# cython: language_level=3, profile=True

import cython


cdef class Vector:
    cdef int length
    cdef list objects
    cdef double* numbers
    cdef double[16] _numbers

    @staticmethod
    cdef Vector _coerce(object other)
    @staticmethod
    cdef Vector _copy(Vector other)
    @staticmethod
    cdef Vector _compose(list vectors, int start, int end)

    cdef int allocate_numbers(self, int n) except -1
    cdef void deallocate_numbers(self)
    cdef void fill_range(self, Vector startv, Vector stopv, Vector stepv)
    cpdef bint isinstance(self, t)
    cdef bint as_bool(self)
    cdef double as_double(self)
    cdef str as_string(self)
    cdef unsigned long long hash(self, bint floor_floats)
    cpdef object match(self, int n=?, type t=?, default=?)
    cpdef Vector copynodes(self)
    cdef str repr(self)
    cdef Vector neg(self)
    cdef Vector pos(self)
    cdef Vector abs(self)
    cdef Vector add(self, Vector other)
    cdef Vector sub(self, Vector other)
    cdef Vector mul(self, Vector other)
    cdef Vector truediv(self, Vector other)
    cdef Vector floordiv(self, Vector other)
    cdef Vector mod(self, Vector other)
    cdef Vector pow(self, Vector other)
    cdef Vector eq(self, Vector other)
    cdef Vector ne(self, Vector other)
    cdef Vector gt(self, Vector other)
    cdef Vector ge(self, Vector other)
    cdef Vector lt(self, Vector other)
    cdef Vector le(self, Vector other)
    cdef int compare(self, Vector other) except -2
    cdef Vector slice(self, Vector index)
    cdef Vector item(self, int i)
    cpdef double squared_sum(self)
    cpdef Vector normalize(self)
    cpdef Vector dot(self, Vector other)
    cpdef Vector cross(self, Vector other)


cdef Vector null_
cdef Vector true_
cdef Vector false_
cdef Vector minusone_


cdef class Matrix33(Vector):
    @staticmethod
    cdef Matrix33 _translate(Vector v)
    @staticmethod
    cdef Matrix33 _scale(Vector v)
    @staticmethod
    cdef Matrix33 _rotate(double turns)

    cdef Matrix33 mmul(self, Matrix33 b)
    cdef Vector vmul(self, Vector b)
    cpdef Matrix33 inverse(self)
    cpdef Matrix33 transpose(self)


cdef class Matrix44(Vector):
    @staticmethod
    cdef Matrix44 _project(double aspect_ratio, double fov, double near, double far)
    @staticmethod
    cdef Matrix44 _ortho(double aspect_ratio, double width, double near, double far)
    @staticmethod
    cdef Matrix44 _look(Vector from_position, Vector to_position, Vector up_direction)
    @staticmethod
    cdef Matrix44 _translate(Vector v)
    @staticmethod
    cdef Matrix44 _scale(Vector v)
    @staticmethod
    cdef Matrix44 _rotate_x(double turns)
    @staticmethod
    cdef Matrix44 _rotate_y(double turns)
    @staticmethod
    cdef Matrix44 _rotate_z(double turns)
    @staticmethod
    cdef Matrix44 _rotate(Vector v)

    cdef Matrix44 mmul(self, Matrix44 b)
    cdef Vector vmul(self, Vector b)
    cpdef Matrix44 inverse(self)
    cpdef Matrix44 transpose(self)
    cpdef Matrix33 matrix33(self)


cdef class Query:
    cdef str kind
    cdef frozenset tags
    cdef bint strict
    cdef bint stop
    cdef bint first
    cdef Query subquery, altquery


cdef class Node:
    cdef object __weakref__
    cdef readonly str kind
    cdef set _tags
    cdef dict _attributes
    cdef bint _attributes_shared
    cdef object _parent
    cdef Node next_sibling, first_child, last_child

    cpdef Node copy(self)
    cpdef void add_tag(self, str tag)
    cpdef void remove_tag(self, str tag)
    cpdef void append(self, Node node)
    cpdef void insert(self, Node node)
    cpdef void remove(self, Node node)
    cdef bint _select(self, Query query, list nodes, bint first)
    cdef bint _equals(self, Node other)
    cpdef object get(self, str name, int n=?, type t=?, object default=?)
    cdef Vector get_fvec(self, str name, int n, Vector default)
    cdef double get_float(self, str name, double default)
    cdef int get_int(self, str name, long long default)
    cdef bint get_bool(self, str name, bint default)
    cdef str get_str(self, str name, str default)
    cdef str repr(self)
