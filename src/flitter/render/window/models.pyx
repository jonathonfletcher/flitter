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
cdef double DefaultSmooth = 0.1
cdef double DefaultMinimumArea = 0.01


cdef class Model:
    def __hash__(self):
        return <Py_hash_t>(<void*>self)

    def __eq__(self, other):
        return self is other

    cdef bint check_valid(self):
        raise NotImplementedError()

    cdef void build_trimesh_model(self):
        raise NotImplementedError()

    cdef object get_render_trimesh_model(self):
        return self.trimesh_model

    cdef tuple get_buffers(self, object glctx, dict objects):
        cdef str name = self.name
        if self.check_valid():
            if name in objects:
                return objects[name]
        else:
            self.build_trimesh_model()
        trimesh_model = self.get_render_trimesh_model()
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
        faces = trimesh_model.faces[:,::-1] if self.invert else trimesh_model.faces
        cdef bint has_uv = trimesh_model.visual is not None and isinstance(trimesh_model.visual, trimesh.visual.texture.TextureVisuals)
        vertex_uvs = trimesh_model.visual.uv if has_uv else np.zeros((len(trimesh_model.vertices), 2))
        if self.flat:
            face_normals = -trimesh_model.face_normals if self.invert else trimesh_model.face_normals
            vertex_data = np.empty((len(faces), 3, 8), dtype='f4')
            vertex_data[:,:,0:3] = trimesh_model.vertices[faces]
            vertex_data[:,:,3:6] = face_normals[:,None,:]
            vertex_data[:,:,6:8] = vertex_uvs[faces]
            buffers = (glctx.buffer(vertex_data), None)
        else:
            vertex_normals = -trimesh_model.vertex_normals if self.invert else trimesh_model.vertex_normals
            vertex_data = np.hstack((trimesh_model.vertices, vertex_normals, vertex_uvs)).astype('f4')
            index_data = faces.astype('i4')
            buffers = (glctx.buffer(vertex_data), glctx.buffer(index_data))
        logger.trace("Prepared model {} with {} vertices and {} faces", name, len(trimesh_model.vertices), len(trimesh_model.faces))
        objects[name] = buffers
        return buffers

    cdef Model transform(self, Matrix44 transform_matrix):
        return TransformedModel.get(self, transform_matrix)

    @staticmethod
    cdef Model intersect(Node node, list models):
        return IntersectionModel.get(node, models)

    @staticmethod
    cdef Model union(Node node, list models):
        return UnionModel.get(node, models)

    @staticmethod
    cdef Model difference(Node node, list models):
        return DifferenceModel.get(node, models)

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


cdef class TransformedModel(Model):
    cdef Model original
    cdef Matrix44 transform_matrix

    @staticmethod
    cdef TransformedModel get(Model original, Matrix44 transform_matrix):
        cdef str name = f'{original.name}/{hex(transform_matrix.hash(False))[3:]}'
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

    cdef bint check_valid(self):
        if not self.valid:
            return False
        if self.original.check_valid():
            return True
        self.valid = False
        return False

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


cdef class BooleanOperationModel(Model):
    cdef double smooth
    cdef double minimum_area
    cdef list models

    @staticmethod
    cdef str get_name(str operation, double smooth, double minimum_area, list models):
        cdef Model child_model
        cdef str name = operation + '('
        cdef int i = 0
        for i, child_model in enumerate(models):
            if i:
                name += ', '
            name += child_model.name
        if smooth != DefaultSmooth:
            name += f', {smooth:g}'
        if minimum_area != DefaultMinimumArea:
            name += f', {minimum_area:g}'
        name += ')'
        return name

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
            trimesh_model = self.boolean_op(trimesh_models)
            self.trimesh_model = trimesh_model if len(trimesh_model.vertices) and len(trimesh_model.faces) else None
        self.valid = True

    cdef object boolean_op(self, list trimesh_models):
        raise NotImplementedError()

    cdef object get_render_trimesh_model(self):
        if self.trimesh_model is None:
            return None
        return trimesh.graph.smooth_shade(self.trimesh_model, angle=self.smooth*Tau, facet_minarea=1/self.minimum_area)


cdef class IntersectionModel(BooleanOperationModel):
    @staticmethod
    cdef IntersectionModel get(Node node, list models):
        cdef double smooth = node.get_float('smooth', DefaultSmooth)
        cdef double minimum_area = max(1e-4, node.get_float('minimum_area', DefaultMinimumArea))
        cdef str name = BooleanOperationModel.get_name('intersect', smooth, minimum_area, models)
        cdef IntersectionModel model = ModelCache.pop(name, None)
        if model is None:
            model = IntersectionModel.__new__(IntersectionModel)
            model.name = name
            model.smooth = smooth
            model.minimum_area = minimum_area
            model.models = models
        ModelCache[name] = model
        return model

    cdef object boolean_op(self, list trimesh_models):
        return trimesh.boolean.intersection(trimesh_models, engine='manifold')


cdef class UnionModel(BooleanOperationModel):
    @staticmethod
    cdef UnionModel get(Node node, list models):
        cdef double smooth = node.get_float('smooth', DefaultSmooth)
        cdef double minimum_area = max(1e-4, node.get_float('minimum_area', DefaultMinimumArea))
        cdef str name = BooleanOperationModel.get_name('union', smooth, minimum_area, models)
        cdef UnionModel model = ModelCache.pop(name, None)
        if model is None:
            model = UnionModel.__new__(UnionModel)
            model.name = name
            model.smooth = smooth
            model.minimum_area = minimum_area
            model.models = models
        ModelCache[name] = model
        return model

    cdef object boolean_op(self, list trimesh_models):
        return trimesh.boolean.union(trimesh_models, engine='manifold')


cdef class DifferenceModel(BooleanOperationModel):
    @staticmethod
    cdef DifferenceModel get(Node node, list models):
        cdef double smooth = node.get_float('smooth', DefaultSmooth)
        cdef double minimum_area = max(1e-4, node.get_float('minimum_area', DefaultMinimumArea))
        cdef str name = BooleanOperationModel.get_name('difference', smooth, minimum_area, models)
        cdef DifferenceModel model = ModelCache.pop(name, None)
        if model is None:
            model = DifferenceModel.__new__(DifferenceModel)
            model.name = name
            model.smooth = smooth
            model.minimum_area = minimum_area
            model.models = models
        ModelCache[name] = model
        return model

    cdef object boolean_op(self, list trimesh_models):
        if len(trimesh_models) > 2:
            union_models = trimesh.boolean.union(trimesh_models[1:], engine='manifold')
            return trimesh.boolean.difference([trimesh_models[0], union_models], engine='manifold')
        return trimesh.boolean.difference(trimesh_models, engine='manifold')


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
        cdef bint invert = node.get_bool('invert', False)
        cdef str name = 'box|invert' if invert else 'box'
        cdef Box model = ModelCache.pop(name, None)
        if model is None:
            model = Box.__new__(Box)
            model.name = name
            model.flat = False
            model.invert = invert
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
        cdef bint flat = node.get_bool('flat', False)
        cdef bint invert = node.get_bool('invert', False)
        cdef int subdivisions = node.get_int('subdivisions', 3)
        cdef int segments = max(4, node.get_int('segments', 4<<subdivisions))
        cdef str name = f'!sphere-{segments}'
        if flat:
            name += '|flat'
        if invert:
            name += '|invert'
        cdef Sphere model = ModelCache.pop(name, None)
        if model is None:
            model = Sphere.__new__(Sphere)
            model.name = name
            model.flat = flat
            model.invert = invert
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
        cdef bint flat = node.get_bool('flat', False)
        cdef bint invert = node.get_bool('invert', False)
        cdef int segments = max(2, node.get_int('segments', 32))
        cdef str name = f'!cylinder-{segments}'
        if flat:
            name += '|flat'
        if invert:
            name += '|invert'
        cdef Cylinder model = ModelCache.pop(name, None)
        if model is None:
            model = Cylinder.__new__(Cylinder)
            model.name = name
            model.flat = flat
            model.invert = invert
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
        cdef bint flat = node.get_bool('flat', False)
        cdef bint invert = node.get_bool('invert', False)
        cdef int segments = max(2, node.get_int('segments', 32))
        cdef str name = f'!cone-{segments}'
        if flat:
            name += '|flat'
        if invert:
            name += '|invert'
        cdef Cone model = ModelCache.pop(name, None)
        if model is None:
            model = Cone.__new__(Cone)
            model.name = name
            model.flat = flat
            model.invert = invert
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
        cdef bint flat = node.get_bool('flat', False)
        cdef bint invert = node.get_bool('invert', False)
        cdef str name = filename
        if flat:
            name += '|flat'
        if invert:
            name += '|invert'
        cdef ExternalModel model = ModelCache.pop(name, None)
        if model is None:
            model = ExternalModel.__new__(ExternalModel)
            model.name = name
            model.flat = flat
            model.invert = invert
            model.filename = filename
            model.trimesh_model = None
        ModelCache[name] = model
        return model

    cdef bint check_valid(self):
        return self.trimesh_model is SharedCache[self.filename].read_trimesh_model()

    cdef void build_trimesh_model(self):
        self.trimesh_model = SharedCache[self.filename].read_trimesh_model()
        self.valid = True
