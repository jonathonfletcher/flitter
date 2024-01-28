# cython: language_level=3, profile=True

import cython
from loguru import logger
import numpy as np
import trimesh

from libc.math cimport cos, sin, sqrt

from ... import name_patch
from ...cache import SharedCache


logger = name_patch(logger, __name__)

cdef dict ModelCache = {}
cdef int MaxModelCacheEntries = 4096
cdef double Tau = 6.283185307179586
cdef double RootHalf = sqrt(0.5)
cdef double DefaultSmooth = 0.05
cdef int DefaultSegments = 64


cdef class Model:
    def __hash__(self):
        return <Py_hash_t>(<void*>self)

    def __eq__(self, other):
        return self is other

    cdef bint is_constructed(self):
        return False

    cdef bint check_valid(self):
        raise NotImplementedError()

    cdef void build_trimesh_model(self):
        raise NotImplementedError()

    cdef tuple get_buffers(self, object glctx, dict objects):
        cdef str name = self.name
        if self.check_valid():
            if name in objects:
                return objects[name]
        else:
            self.build_trimesh_model()
        trimesh_model = self.trimesh_model
        if trimesh_model is None:
            if name in objects:
                del objects[name]
            return None, None
        while len(ModelCache) > MaxModelCacheEntries:
            dead_name = next(iter(ModelCache))
            del ModelCache[dead_name]
            if dead_name in objects:
                del objects[dead_name]
            logger.trace("Removed model {} from cache", dead_name)
        cdef tuple buffers
        cdef bint has_uv = trimesh_model.visual is not None and isinstance(trimesh_model.visual, trimesh.visual.texture.TextureVisuals)
        vertex_uvs = trimesh_model.visual.uv if has_uv else np.zeros((len(trimesh_model.vertices), 2))
        vertex_data = np.hstack((trimesh_model.vertices, trimesh_model.vertex_normals, vertex_uvs)).astype('f4')
        index_data = trimesh_model.faces.astype('i4')
        buffers = (glctx.buffer(vertex_data), glctx.buffer(index_data))
        logger.trace("Prepared model {} with {} vertices and {} faces", name, len(trimesh_model.vertices), len(trimesh_model.faces))
        objects[name] = buffers
        return buffers

    cdef Model flatten(self):
        return FlattenedModel.get(self)

    cdef Model invert(self):
        return InvertedModel.get(self)

    cdef Model smooth_shade(self, double smooth, double minimum_area):
        return SmoothShadedModel.get(self, smooth, minimum_area)

    cdef Model transform(self, Matrix44 transform_matrix):
        return TransformedModel.get(self, transform_matrix)

    cdef Model slice(self, Vector origin, Vector normal):
        return SlicedModel.get(self, origin, normal)

    @staticmethod
    cdef Model intersect(list models):
        return BooleanOperationModel.get('intersection', models)

    @staticmethod
    cdef Model union(list models):
        return BooleanOperationModel.get('union', models)

    @staticmethod
    cdef Model difference(list models):
        return BooleanOperationModel.get('difference', models)

    @staticmethod
    cdef Model get_box(Node node):
        return Box.get(node)

    @staticmethod
    cdef Model get_sphere(Node node):
        return Sphere.get(node)

    @staticmethod
    cdef Model get_cylinder(Node node):
        return Cylinder.get(node)

    @staticmethod
    cdef Model get_cone(Node node):
        return Cone.get(node)

    @staticmethod
    cdef Model get_external(Node node):
        return ExternalModel.get(node)


cdef class ModelTransformer(Model):
    cdef Model original

    cdef bint check_valid(self):
        if not self.valid:
            return False
        if self.original.check_valid():
            return True
        self.valid = False
        return False


cdef class FlattenedModel(ModelTransformer):
    @staticmethod
    cdef FlattenedModel get(Model original):
        cdef str name = f'flat({original.name})'
        cdef FlattenedModel model = ModelCache.pop(name, None)
        if model is None:
            model = FlattenedModel.__new__(FlattenedModel)
            model.name = name
            model.original = original
        ModelCache[name] = model
        return model

    cdef void build_trimesh_model(self):
        if not self.original.check_valid():
            self.original.build_trimesh_model()
        trimesh_model = self.original.trimesh_model.copy()
        trimesh_model.unmerge_vertices()
        self.trimesh_model = trimesh_model
        self.valid = True


cdef class InvertedModel(ModelTransformer):
    @staticmethod
    cdef InvertedModel get(Model original):
        cdef str name = f'invert({original.name})'
        cdef InvertedModel model = ModelCache.pop(name, None)
        if model is None:
            model = InvertedModel.__new__(InvertedModel)
            model.name = name
            model.original = original
        ModelCache[name] = model
        return model

    cdef void build_trimesh_model(self):
        if not self.original.check_valid():
            self.original.build_trimesh_model()
        trimesh_model = self.original.trimesh_model.copy()
        trimesh_model.invert()
        self.trimesh_model = trimesh_model
        self.valid = True


cdef class SmoothShadedModel(ModelTransformer):
    cdef double smooth
    cdef double minimum_area

    @staticmethod
    cdef SmoothShadedModel get(Model original, double smooth, double minimum_area):
        cdef str name = 'smooth(' + original.name
        if smooth != DefaultSmooth:
            name += f', {smooth:g}'
        if minimum_area:
            name += f', {minimum_area:g}'
        name += ')'
        cdef SmoothShadedModel model = ModelCache.pop(name, None)
        if model is None:
            model = SmoothShadedModel.__new__(SmoothShadedModel)
            model.name = name
            model.original = original
            model.smooth = smooth
            model.minimum_area = minimum_area
        ModelCache[name] = model
        return model

    cdef void build_trimesh_model(self):
        if not self.original.check_valid():
            self.original.build_trimesh_model()
        self.trimesh_model = trimesh.graph.smooth_shade(self.original.trimesh_model, angle=self.smooth*Tau,
                                                        facet_minarea=1/self.minimum_area if self.minimum_area else None)
        self.valid = True


cdef class TransformedModel(ModelTransformer):
    cdef Matrix44 transform_matrix

    @staticmethod
    cdef TransformedModel get(Model original, Matrix44 transform_matrix):
        cdef str name = f'{original.name}@{hex(transform_matrix.hash(False))[3:]}'
        cdef TransformedModel model = ModelCache.pop(name, None)
        if model is None:
            model = TransformedModel.__new__(TransformedModel)
            model.name = name
            model.original = original
            model.transform_matrix = transform_matrix
        ModelCache[name] = model
        return model

    cdef Model transform(self, Matrix44 transform_matrix):
        return TransformedModel.get(self.original, transform_matrix.mmul(self.transform_matrix))

    cdef void build_trimesh_model(self):
        if not self.original.check_valid():
            self.original.build_trimesh_model()
        if self.original.trimesh_model is not None:
            transform_array = np.array(self.transform_matrix, dtype='float64').reshape((4, 4)).transpose()
            trimesh_model = self.original.trimesh_model.copy().apply_transform(transform_array)
            self.trimesh_model = trimesh_model if len(trimesh_model.vertices) and len(trimesh_model.faces) else None
        else:
            self.trimesh_model = None
        self.valid = True


cdef class SlicedModel(ModelTransformer):
    cdef Vector origin
    cdef Vector normal

    cdef bint is_constructed(self):
        return True

    @staticmethod
    cdef SlicedModel get(Model original, Vector origin, Vector normal):
        cdef str name = f'{original.name}/{hex(origin.hash(False) ^ normal.hash(False))[3:]}'
        cdef SlicedModel model = ModelCache.pop(name, None)
        if model is None:
            model = SlicedModel.__new__(SlicedModel)
            model.name = name
            model.original = original
            model.origin = origin
            model.normal = normal.normalize()
        ModelCache[name] = model
        return model

    cdef Model transform(self, Matrix44 transform_matrix):
        cdef Vector origin = transform_matrix.vmul(self.origin)
        cdef Vector normal = transform_matrix.inverse_transpose_matrix33().vmul(self.normal).normalize()
        return SlicedModel.get(TransformedModel.get(self.original, transform_matrix), origin, normal)

    cdef void build_trimesh_model(self):
        if not self.original.check_valid():
            self.original.build_trimesh_model()
        if self.original.trimesh_model is not None:
            trimesh_model = self.original.trimesh_model.copy().slice_plane(tuple(self.origin), tuple(self.normal.neg()), True)
            self.trimesh_model = trimesh_model if len(trimesh_model.vertices) and len(trimesh_model.faces) else None
        else:
            self.trimesh_model = None
        self.valid = True


cdef class BooleanOperationModel(Model):
    cdef str operation
    cdef list models

    cdef bint is_constructed(self):
        return True

    @staticmethod
    cdef BooleanOperationModel get(str operation, list models):
        cdef Model child_model
        cdef str name = operation + '('
        cdef int i = 0
        for i, child_model in enumerate(models):
            if i:
                name += ', '
            name += child_model.name
        name += ')'
        cdef BooleanOperationModel model = ModelCache.pop(name, None)
        if model is None:
            model = BooleanOperationModel.__new__(BooleanOperationModel)
            model.name = name
            model.operation = operation
            model.models = models
        ModelCache[name] = model
        return model

    cdef Model transform(self, Matrix44 transform_matrix):
        cdef Model model
        cdef list models = []
        for model in self.models:
            models.append(model.transform(transform_matrix))
        return BooleanOperationModel.get(self.operation, models)

    cdef bint check_valid(self):
        if not self.valid:
            return False
        cdef Model model
        for model in self.models:
            if not model.check_valid():
                break
        else:
            return True
        self.valid = False
        return False

    cdef void build_trimesh_model(self):
        cdef list trimesh_models = []
        cdef Model model
        for model in self.models:
            if not model.check_valid():
                model.build_trimesh_model()
            if model.trimesh_model is None:
                continue
            trimesh_model = model.trimesh_model.copy()
            if not trimesh_model.is_watertight:
                trimesh_model.merge_vertices(merge_tex=True, merge_norm=True)
                if not trimesh_model.is_watertight and not trimesh_model.fill_holes():
                    trimesh_model = trimesh_model.convex_hull
            trimesh_models.append(trimesh_model)
        if not trimesh_models:
            self.trimesh_model = None
        else:
            if self.operation == 'difference' and len(trimesh_models) > 2:
                union_models = trimesh.boolean.boolean_manifold(trimesh_models[1:], 'union')
                trimesh_model = trimesh.boolean.boolean_manifold([trimesh_models[0], union_models], 'difference')
            else:
                trimesh_model = trimesh.boolean.boolean_manifold(trimesh_models, self.operation)
            self.trimesh_model = trimesh_model if len(trimesh_model.vertices) and len(trimesh_model.faces) else None
        self.valid = True


cdef class PrimitiveModel(Model):
    cdef bint check_valid(self):
        return self.valid


cdef class Box(PrimitiveModel):
    Vertices = np.array([
        (-.5,-.5,+.5), (+.5,-.5,+.5), (+.5,+.5,+.5), (-.5,+.5,+.5),
        (-.5,+.5,+.5), (+.5,+.5,+.5), (+.5,+.5,-.5), (-.5,+.5,-.5),
        (+.5,+.5,+.5), (+.5,-.5,+.5), (+.5,-.5,-.5), (+.5,+.5,-.5),
        (+.5,+.5,-.5), (+.5,-.5,-.5), (-.5,-.5,-.5), (-.5,+.5,-.5),
        (-.5,+.5,-.5), (-.5,-.5,-.5), (-.5,-.5,+.5), (-.5,+.5,+.5),
        (-.5,-.5,-.5), (+.5,-.5,-.5), (+.5,-.5,+.5), (-.5,-.5,+.5),
    ], dtype='f4')
    VertexNormals = np.array([
        (0,0,1), (0,0,1), (0,0,1), (0,0,1),
        (0,1,0), (0,1,0), (0,1,0), (0,1,0),
        (1,0,0), (1,0,0), (1,0,0), (1,0,0),
        (0,0,-1), (0,0,-1), (0,0,-1), (0,0,-1),
        (-1,0,0), (-1,0,0), (-1,0,0), (-1,0,0),
        (0,-1,0), (0,-1,0), (0,-1,0), (0,-1,0),
    ], dtype='f4')
    VertexUV = np.array([
        (0,0), (1/6,0), (1/6,1), (0,1),
        (1/6,0), (2/6,0), (2/6,1), (1/6,1),
        (2/6,0), (3/6,0), (3/6,1), (2/6,1),
        (3/6,0), (4/6,0), (4/6,1), (3/6,1),
        (4/6,0), (5/6,0), (5/6,1), (4/6,1),
        (5/6,0), (6/6,0), (6/6,1), (5/6,1),
    ], dtype='f4')
    Faces = np.array([
        (0,1,2), (2,3,0),
        (4,5,6), (6,7,4),
        (8,9,10), (10,11,8),
        (12,13,14), (14,15,12),
        (16,17,18), (18,19,16),
        (20,21,22), (22,23,20),
    ], dtype='i4')

    @staticmethod
    cdef Box get(Node node):
        cdef str name = '!box'
        cdef Box model = ModelCache.pop(name, None)
        if model is None:
            model = Box.__new__(Box)
            model.name = name
            model.trimesh_model = None
        ModelCache[name] = model
        return model

    cdef void build_trimesh_model(self):
        visual = trimesh.visual.texture.TextureVisuals(uv=Box.VertexUV)
        self.trimesh_model = trimesh.base.Trimesh(vertices=Box.Vertices, vertex_normals=Box.VertexNormals, faces=Box.Faces, visual=visual)
        self.valid = True


cdef class Sphere(PrimitiveModel):
    cdef int segments

    @staticmethod
    cdef Sphere get(Node node):
        cdef int segments = max(4, node.get_int('segments', DefaultSegments))
        cdef str name = f'!sphere-{segments}' if segments != DefaultSegments else '!sphere'
        cdef Sphere model = ModelCache.pop(name, None)
        if model is None:
            model = Sphere.__new__(Sphere)
            model.name = name
            model.segments = segments
            model.trimesh_model = None
        ModelCache[name] = model
        return model

    @cython.cdivision(True)
    cdef void build_trimesh_model(self):
        cdef int ncols = self.segments, nrows = ncols//2, nvertices = (nrows+1)*(ncols+1), nfaces = (2+(nrows-2)*2)*ncols
        cdef object vertices_array = np.empty((nvertices, 3), dtype='f4')
        cdef float[:,:] vertices = vertices_array
        cdef object vertex_normals_array = np.empty((nvertices, 3), dtype='f4')
        cdef float[:,:] vertex_normals = vertex_normals_array
        cdef object vertex_uv_array = np.empty((nvertices, 2), dtype='f4')
        cdef float[:,:] vertex_uv = vertex_uv_array
        cdef object faces_array = np.empty((nfaces, 3), dtype='i4')
        cdef int[:,:] faces = faces_array
        cdef float x, y, z, r, th, u, v
        cdef int row, col, i=0, j=0
        for row in range(nrows + 1):
            v = <float>row/nrows
            if row == 0:
                r, z = 0, -1
            elif row == nrows:
                r, z = 0, 1
            else:
                th = Tau*(v-0.5)/2
                r, z = cos(th), sin(th)
            for col in range(ncols+1):
                u = (col+0.5)/ncols if row == 0 else ((col-0.5)/ncols if row == nrows else <float>col/ncols)
                if col == 0:
                    x, y = r, 0
                elif col == ncols:
                    x, y = r, 0
                else:
                    x, y = r*cos(Tau*u), r*sin(Tau*u)
                vertices[i, 0], vertices[i, 1], vertices[i, 2] = x, y, z
                vertex_normals[i, 0], vertex_normals[i, 1], vertex_normals[i, 2] = x, y, z
                vertex_uv[i, 0], vertex_uv[i, 1] = u, v
                if col < ncols and row < nrows:
                    if row < nrows-1:
                        faces[j, 0], faces[j, 1], faces[j, 2] = i, i+2+ncols, i+1+ncols
                        j += 1
                    if row > 0:
                        faces[j, 0], faces[j, 1], faces[j, 2] = i, i+1, i+2+ncols
                        j += 1
                i += 1
        visual = trimesh.visual.texture.TextureVisuals(uv=vertex_uv_array)
        self.trimesh_model = trimesh.base.Trimesh(vertices=vertices_array, vertex_normals=vertex_normals_array, faces=faces_array, visual=visual)
        self.valid = True


cdef class Cylinder(PrimitiveModel):
    cdef int segments

    @staticmethod
    cdef Cylinder get(Node node):
        cdef int segments = max(2, node.get_int('segments', DefaultSegments))
        cdef str name = f'!cylinder-{segments}' if segments != DefaultSegments else '!cylinder'
        cdef Cylinder model = ModelCache.pop(name, None)
        if model is None:
            model = Cylinder.__new__(Cylinder)
            model.name = name
            model.segments = segments
            model.trimesh_model = None
        ModelCache[name] = model
        return model

    @cython.cdivision(True)
    @cython.boundscheck(False)
    cdef void build_trimesh_model(self):
        cdef int i, j, k, n = self.segments, m = (n+1)*6
        cdef object vertices_array = np.empty((m, 3), dtype='f4')
        cdef float[:,:] vertices = vertices_array
        cdef object vertex_normals_array = np.empty((m, 3), dtype='f4')
        cdef float[:,:] vertex_normals = vertex_normals_array
        cdef object vertex_uv_array = np.empty((m, 2), dtype='f4')
        cdef float[:,:] vertex_uv = vertex_uv_array
        cdef object faces_array = np.empty((n*4, 3), dtype='i4')
        cdef int[:,:] faces = faces_array
        cdef float x, y, th, u, uu
        for i in range(n+1):
            j = k = i * 6
            u = <float>i / n
            u_ = (i+0.5) / n
            th = Tau * u
            x = cos(th)
            y = sin(th)
            # bottom centre (k):
            vertices[j, 0], vertices[j, 1], vertices[j, 2] = 0, 0, -0.5
            vertex_normals[j, 0], vertex_normals[j, 1], vertex_normals[j, 2] = 0, 0, -1
            vertex_uv[j, 0], vertex_uv[j, 1] = u_, 0
            j += 1
            # bottom edge (k+1):
            vertices[j, 0], vertices[j, 1], vertices[j, 2] = x, y, -0.5
            vertex_normals[j, 0], vertex_normals[j, 1], vertex_normals[j, 2] = 0, 0, -1
            vertex_uv[j, 0], vertex_uv[j, 1] = u, 0.25
            j += 1
            # side bottom (k+2):
            vertices[j, 0], vertices[j, 1], vertices[j, 2] = x, y, -0.5
            vertex_normals[j, 0], vertex_normals[j, 1], vertex_normals[j, 2] = x, y, 0
            vertex_uv[j, 0], vertex_uv[j, 1] = u, 0.25
            j += 1
            # side top (k+3):
            vertices[j, 0], vertices[j, 1], vertices[j, 2] = x, y, 0.5
            vertex_normals[j, 0], vertex_normals[j, 1], vertex_normals[j, 2] = x, y, 0
            vertex_uv[j, 0], vertex_uv[j, 1] = u, 0.75
            j += 1
            # top edge (k+4):
            vertices[j, 0], vertices[j, 1], vertices[j, 2] = x, y, 0.5
            vertex_normals[j, 0], vertex_normals[j, 1], vertex_normals[j, 2] = 0, 0, 1
            vertex_uv[j, 0], vertex_uv[j, 1] = u, 0.75
            j += 1
            # top centre (k+5):
            vertices[j, 0], vertices[j, 1], vertices[j, 2] = 0, 0, 0.5
            vertex_normals[j, 0], vertex_normals[j, 1], vertex_normals[j, 2] = 0, 0, 1
            vertex_uv[j, 0], vertex_uv[j, 1] = u_, 1
            if i < n:
                j = i * 4
                # bottom face
                faces[j, 0], faces[j, 1], faces[j, 2] = k, k+1+6, k+1
                j += 1
                # side face 1
                faces[j, 0], faces[j, 1], faces[j, 2] = k+2+6, k+3, k+2
                j += 1
                # side face 2
                faces[j, 0], faces[j, 1], faces[j, 2] = k+3, k+2+6, k+3+6
                j += 1
                # top face
                faces[j, 0], faces[j, 1], faces[j, 2] = k+5, k+4, k+4+6
        visual = trimesh.visual.texture.TextureVisuals(uv=vertex_uv_array)
        self.trimesh_model = trimesh.base.Trimesh(vertices=vertices_array, vertex_normals=vertex_normals_array, faces=faces_array, visual=visual)
        self.valid = True


cdef class Cone(PrimitiveModel):
    cdef int segments

    @staticmethod
    cdef Cone get(Node node):
        cdef int segments = max(2, node.get_int('segments', DefaultSegments))
        cdef str name = f'!cone-{segments}' if segments != DefaultSegments else '!cone'
        cdef Cone model = ModelCache.pop(name, None)
        if model is None:
            model = Cone.__new__(Cone)
            model.name = name
            model.segments = segments
            model.trimesh_model = None
        ModelCache[name] = model
        return model

    @cython.cdivision(True)
    @cython.boundscheck(False)
    cdef void build_trimesh_model(self):
        cdef int i, j, k, n = self.segments, m = (n+1)*4
        cdef object vertices_array = np.empty((m, 3), dtype='f4')
        cdef float[:,:] vertices = vertices_array
        cdef object vertex_normals_array = np.empty((m, 3), dtype='f4')
        cdef float[:,:] vertex_normals = vertex_normals_array
        cdef object vertex_uv_array = np.empty((m, 2), dtype='f4')
        cdef float[:,:] vertex_uv = vertex_uv_array
        cdef object faces_array = np.empty((n*2, 3), dtype='i4')
        cdef int[:,:] faces = faces_array
        cdef float x, y, th, u, uu
        for i in range(n+1):
            j = k = i * 4
            u = <double>i / n
            u_ = (i+0.5) / n
            th = Tau * u
            th_ = Tau * u_
            x = cos(th)
            y = sin(th)
            # bottom centre (k):
            vertices[j, 0], vertices[j, 1], vertices[j, 2] = 0, 0, -0.5
            vertex_normals[j, 0], vertex_normals[j, 1], vertex_normals[j, 2] = 0, 0, -1
            vertex_uv[j, 0], vertex_uv[j, 1] = u_, 0
            j += 1
            # bottom edge (k+1):
            vertices[j, 0], vertices[j, 1], vertices[j, 2] = x, y, -0.5
            vertex_normals[j, 0], vertex_normals[j, 1], vertex_normals[j, 2] = 0, 0, -1
            vertex_uv[j, 0], vertex_uv[j, 1] = u, 0.25
            j += 1
            # side bottom (k+2):
            vertices[j, 0], vertices[j, 1], vertices[j, 2] = x, y, -0.5
            vertex_normals[j, 0], vertex_normals[j, 1], vertex_normals[j, 2] = x*RootHalf, y*RootHalf, RootHalf
            vertex_uv[j, 0], vertex_uv[j, 1] = u, 0.25
            j += 1
            # side top (k+3):
            vertices[j, 0], vertices[j, 1], vertices[j, 2] = 0, 0, 0.5
            vertex_normals[j, 0], vertex_normals[j, 1], vertex_normals[j, 2] = cos(th_)*RootHalf, sin(th_)*RootHalf, RootHalf
            vertex_uv[j, 0], vertex_uv[j, 1] = u_, 1
            if i < n:
                j = i * 2
                # bottom face
                faces[j, 0], faces[j, 1], faces[j, 2] = k, k+1+4, k+1
                j += 1
                # side face
                faces[j, 0], faces[j, 1], faces[j, 2] = k+3, k+2, k+2+4
        visual = trimesh.visual.texture.TextureVisuals(uv=vertex_uv_array)
        self.trimesh_model = trimesh.base.Trimesh(vertices=vertices_array, vertex_normals=vertex_normals_array, faces=faces_array, visual=visual)
        self.valid = True


cdef class ExternalModel(Model):
    cdef str filename

    @staticmethod
    cdef ExternalModel get(Node node):
        cdef str filename = node.get_str('filename', None)
        if not filename:
            return None
        cdef str name = filename
        cdef ExternalModel model = ModelCache.pop(name, None)
        if model is None:
            model = ExternalModel.__new__(ExternalModel)
            model.name = name
            model.filename = filename
            model.trimesh_model = None
        ModelCache[name] = model
        return model

    cdef bint check_valid(self):
        return self.trimesh_model is SharedCache[self.filename].read_trimesh_model()

    cdef void build_trimesh_model(self):
        self.trimesh_model = SharedCache[self.filename].read_trimesh_model()
        self.valid = True
