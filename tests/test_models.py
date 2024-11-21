"""
Tests of flitter 3D models
"""

import math

import trimesh

from flitter.model import Vector, Matrix44
from flitter.render.window.models import Model

from . import utils


DefaultSegments = 64


class TestPrimitives(utils.TestCase):
    def tearDown(self):
        Model.flush_caches(0, 0)

    def test_box(self):
        model = Model.box()
        mesh = model.get_trimesh()
        self.assertEqual(model.name, '!box')
        self.assertEqual(mesh.bounds.tolist(), [[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]])
        self.assertEqual(len(mesh.vertices), 24)
        self.assertEqual(len(mesh.faces), 12)
        self.assertEqual(mesh.area, 6)
        self.assertEqual(mesh.volume, 1)

    def test_sphere(self):
        for segments in (4, DefaultSegments, 1024):
            with self.subTest(segments=segments):
                model = Model.sphere(segments)
                self.assertEqual(model.name, f'!sphere-{segments}' if segments != DefaultSegments else '!sphere')
                mesh = model.get_trimesh()
                self.assertEqual(mesh.bounds.tolist(), [[-1, -1, -1], [1, 1, 1]])
                nrows = segments // 4
                self.assertEqual(len(mesh.vertices), 4*(nrows+1)*(nrows+2))
                self.assertEqual(len(mesh.faces), 8*nrows*nrows)
                if segments == 4:
                    self.assertAlmostEqual(mesh.area, 4*math.sqrt(3))
                    self.assertAlmostEqual(mesh.volume, 4/3)
                else:
                    self.assertAlmostEqual(mesh.area, 4*math.pi, places=int(math.log10(segments)))
                    self.assertAlmostEqual(mesh.volume, 4/3*math.pi, places=int(math.log10(segments)))

    def test_cylinder(self):
        for segments in (4, DefaultSegments, 1024):
            with self.subTest(segments=segments):
                model = Model.cylinder(segments)
                self.assertEqual(model.name, f'!cylinder-{segments}' if segments != DefaultSegments else '!cylinder')
                mesh = model.get_trimesh()
                self.assertEqual(mesh.bounds.tolist(), [[-1, -1, -0.5], [1, 1, 0.5]])
                self.assertEqual(len(mesh.vertices), 6*(segments+1))
                self.assertEqual(len(mesh.faces), 4*segments)
                if segments == 4:
                    self.assertAlmostEqual(mesh.area, 4*(1+math.sqrt(2)))
                    self.assertAlmostEqual(mesh.volume, 2)
                else:
                    self.assertAlmostEqual(mesh.area, 4*math.pi, places=int(math.log10(segments)))
                    self.assertAlmostEqual(mesh.volume, math.pi, places=int(math.log10(segments)))

    def test_cone(self):
        for segments in (4, DefaultSegments, 1024):
            with self.subTest(segments=segments):
                model = Model.cone(segments)
                self.assertEqual(model.name, f'!cone-{segments}' if segments != DefaultSegments else '!cone')
                mesh = model.get_trimesh()
                self.assertEqual(mesh.bounds.tolist(), [[-1, -1, -0.5], [1, 1, 0.5]])
                self.assertEqual(len(mesh.vertices), 4*(segments+1))
                self.assertEqual(len(mesh.faces), 2*segments)
                if segments == 4:
                    self.assertAlmostEqual(mesh.area, 2*(1+math.sqrt(3)))
                    self.assertAlmostEqual(mesh.volume, 2/3)
                else:
                    self.assertAlmostEqual(mesh.area, (1+math.sqrt(2))*math.pi, places=int(math.log10(segments)))
                    self.assertAlmostEqual(mesh.volume, math.pi/3, places=int(math.log10(segments)))


class TestManifoldPrimitives(utils.TestCase):
    def tearDown(self):
        Model.flush_caches(0, 0)

    def test_box(self):
        mesh = Model.box().get_manifold().to_mesh()
        mesh = trimesh.Trimesh(vertices=mesh.vert_properties, faces=mesh.tri_verts, process=False)
        self.assertEqual(mesh.bounds.tolist(), [[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]])
        self.assertEqual(len(mesh.vertices), 8)
        self.assertEqual(len(mesh.faces), 12)
        self.assertEqual(mesh.area, 6)
        self.assertEqual(mesh.volume, 1)

    def test_sphere(self):
        for segments in (4, DefaultSegments, 1024):
            with self.subTest(segments=segments):
                mesh = Model.sphere(segments).get_manifold().to_mesh()
                mesh = trimesh.Trimesh(vertices=mesh.vert_properties, faces=mesh.tri_verts, process=False)
                self.assertEqual(mesh.bounds.tolist(), [[-1, -1, -1], [1, 1, 1]])
                nrows = segments // 2
                self.assertEqual(len(mesh.vertices), 2+nrows*nrows)
                self.assertEqual(len(mesh.faces), 2*nrows*nrows)
                if segments == 4:
                    self.assertAlmostEqual(mesh.area, 4*math.sqrt(3))
                    self.assertAlmostEqual(mesh.volume, 4/3)
                else:
                    self.assertAlmostEqual(mesh.area, 4*math.pi, places=int(math.log10(segments)))
                    self.assertAlmostEqual(mesh.volume, 4/3*math.pi, places=int(math.log10(segments)))

    def test_cylinder(self):
        for segments in (4, DefaultSegments, 1024):
            with self.subTest(segments=segments):
                mesh = Model.cylinder(segments).get_manifold().to_mesh()
                mesh = trimesh.Trimesh(vertices=mesh.vert_properties, faces=mesh.tri_verts, process=False)
                self.assertEqual(mesh.bounds.tolist(), [[-1, -1, -0.5], [1, 1, 0.5]])
                self.assertEqual(len(mesh.vertices), 2*segments)
                self.assertEqual(len(mesh.faces), 4*(segments-1))
                if segments == 4:
                    self.assertAlmostEqual(mesh.area, 4*(1+math.sqrt(2)))
                    self.assertAlmostEqual(mesh.volume, 2)
                else:
                    self.assertAlmostEqual(mesh.area, 4*math.pi, places=int(math.log10(segments)))
                    self.assertAlmostEqual(mesh.volume, math.pi, places=int(math.log10(segments)))

    def test_cone(self):
        for segments in (4, DefaultSegments, 1024):
            with self.subTest(segments=segments):
                mesh = Model.cone(segments).get_manifold().to_mesh()
                mesh = trimesh.Trimesh(vertices=mesh.vert_properties, faces=mesh.tri_verts, process=False)
                self.assertEqual(mesh.bounds.tolist(), [[-1, -1, -0.5], [1, 1, 0.5]])
                self.assertEqual(len(mesh.vertices), segments+1)
                self.assertEqual(len(mesh.faces), 2*(segments-1))
                if segments == 4:
                    self.assertAlmostEqual(mesh.area, 2*(1+math.sqrt(3)))
                    self.assertAlmostEqual(mesh.volume, 2/3)
                else:
                    self.assertAlmostEqual(mesh.area, (1+math.sqrt(2))*math.pi, places=int(math.log10(segments)))
                    self.assertAlmostEqual(mesh.volume, math.pi/3, places=int(math.log10(segments)))


class TestTransform(utils.TestCase):
    def tearDown(self):
        Model.flush_caches(0, 0)

    def assertTransform(self, base_model, matrix):
        transformed_model = base_model.transform(matrix)
        self.assertEqual(transformed_model.name, f'{base_model.name}@{hex(matrix.hash(False))[2:]}')
        base_mesh = base_model.get_trimesh()
        transformed_mesh = transformed_model.get_trimesh()
        self.assertEqual(len(base_mesh.vertices), len(transformed_mesh.vertices))
        self.assertEqual(base_mesh.faces.tolist(), transformed_mesh.faces.tolist())
        for vertex1, vertex2 in zip(base_mesh.vertices.tolist(), transformed_mesh.vertices.tolist()):
            self.assertAllAlmostEqual(vertex2, matrix @ vertex1, places=6)
        base_mesh = base_model.get_manifold().to_mesh()
        transformed_mesh = transformed_model.get_manifold().to_mesh()
        self.assertEqual(len(base_mesh.vert_properties), len(transformed_mesh.vert_properties))
        self.assertEqual(base_mesh.tri_verts.tolist(), transformed_mesh.tri_verts.tolist())
        for vertex1, vertex2 in zip(base_mesh.vert_properties.tolist(), transformed_mesh.vert_properties.tolist()):
            self.assertAllAlmostEqual(vertex2, matrix @ vertex1, places=6)

    def test_translate(self):
        self.assertTransform(Model.cylinder(), Matrix44.translate((1, 2, 3)))

    def test_rotate(self):
        self.assertTransform(Model.cylinder(), Matrix44.rotate(1/3))

    def test_scale(self):
        self.assertTransform(Model.cylinder(), Matrix44.scale((2, 3, 4)))


class TestCache(utils.TestCase):
    def tearDown(self):
        Model.flush_caches(0, 0)

    def test_cached_trimesh(self):
        model = Model.box()
        bounds = model.get_bounds()
        mesh = model.get_trimesh()
        manifold = model.get_manifold()
        self.assertIs(model.get_bounds(), bounds)
        self.assertIs(model.get_trimesh(), mesh)
        self.assertIs(model.get_manifold(), manifold)

    def test_invalidate(self):
        model = Model.box()
        bounds = model.get_bounds()
        mesh = model.get_trimesh()
        manifold = model.get_manifold()
        self.assertIs(model.get_bounds(), bounds)
        self.assertIs(model.get_trimesh(), mesh)
        self.assertIs(model.get_manifold(), manifold)
        model.invalidate()
        self.assertIsNot(model.get_bounds(), bounds)
        self.assertIsNot(model.get_trimesh(), mesh)
        self.assertIsNot(model.get_manifold(), manifold)

    def test_invalidate_dependency(self):
        dependency = Model.box()
        model = dependency.transform(Matrix44())
        bounds = model.get_bounds()
        mesh = model.get_trimesh()
        manifold = model.get_manifold()
        self.assertIs(model.get_bounds(), bounds)
        self.assertIs(model.get_trimesh(), mesh)
        self.assertIs(model.get_manifold(), manifold)
        dependency.invalidate()
        self.assertIsNot(model.get_bounds(), bounds)
        self.assertIsNot(model.get_trimesh(), mesh)
        self.assertIsNot(model.get_manifold(), manifold)


class TestStructuring(utils.TestCase):
    def setUp(self):
        self.M = Matrix44.translate(1)
        self.M_hash = hex(self.M.hash(False))[2:]
        self.M2 = Matrix44.translate(2)
        self.M2_hash = hex(self.M2.hash(False))[2:]
        self.P = Vector((0, 0, 0))
        self.N = Vector((1, 0, 0))
        self.PN_hash = hex(self.P.hash(False) ^ self.N.hash(False))[2:]

    def test_flatten(self):
        self.assertEqual(Model.box().flatten().name, 'flatten(!box)')
        self.assertEqual(Model.box().flatten().flatten().name, 'flatten(!box)')
        self.assertEqual(Model.box().flatten().invert().name, 'invert(flatten(!box))')
        self.assertEqual(Model.box().flatten().repair().name, 'repair(flatten(!box))')
        self.assertEqual(Model.box().flatten().snap_edges().name, 'flatten(!box)')
        self.assertEqual(Model.box().flatten().transform(self.M).name, f'flatten(!box)@{self.M_hash}')
        self.assertEqual(Model.box().flatten().uv_remap('sphere').name, 'uv_remap(flatten(!box), sphere)')
        self.assertEqual(Model.box().flatten().trim(self.P, self.N).name, f'trim(flatten(!box), {self.PN_hash})')

    def test_invert(self):
        self.assertEqual(Model.box().invert().name, 'invert(!box)')
        self.assertEqual(Model.box().invert().flatten().name, 'flatten(invert(!box))')
        self.assertEqual(Model.box().invert().invert().name, '!box')
        self.assertEqual(Model.box().invert().repair().name, 'invert(repair(!box))')
        self.assertEqual(Model.box().invert().snap_edges().name, 'invert(snap_edges(!box))')
        self.assertEqual(Model.box().invert().transform(self.M).name, f'invert(!box@{self.M_hash})')
        self.assertEqual(Model.box().invert().uv_remap('sphere').name, 'uv_remap(invert(!box), sphere)')
        self.assertEqual(Model.box().invert().trim(self.P, self.N).name, f'trim(invert(!box), {self.PN_hash})')

    def test_repair(self):
        self.assertEqual(Model.box().repair().name, 'repair(!box)')
        self.assertEqual(Model.box().repair().flatten().name, 'flatten(repair(!box))')
        self.assertEqual(Model.box().repair().invert().name, 'invert(repair(!box))')
        self.assertEqual(Model.box().repair().repair().name, 'repair(!box)')
        self.assertEqual(Model.box().repair().snap_edges().name, 'snap_edges(repair(!box))')
        self.assertEqual(Model.box().repair().transform(self.M).name, f'repair(!box)@{self.M_hash}')
        self.assertEqual(Model.box().repair().uv_remap('sphere').name, 'uv_remap(repair(!box), sphere)')
        self.assertEqual(Model.box().repair().trim(self.P, self.N).name, f'trim(repair(!box), {self.PN_hash})')

    def test_snap_edges(self):
        self.assertEqual(Model.box().snap_edges(0).name, 'flatten(!box)')
        self.assertEqual(Model.box().snap_edges().name, 'snap_edges(!box)')
        self.assertEqual(Model.box().snap_edges(0.05).name, 'snap_edges(!box)')
        self.assertEqual(Model.box().snap_edges(0.25).name, 'snap_edges(!box, 0.25)')
        self.assertEqual(Model.box().snap_edges(0.05, 0.25).name, 'snap_edges(!box, 0.05, 0.25)')
        self.assertEqual(Model.box().snap_edges(0.25, 0.25).name, 'snap_edges(!box, 0.25, 0.25)')
        self.assertEqual(Model.box().snap_edges().flatten().name, 'flatten(!box)')
        self.assertEqual(Model.box().snap_edges().invert().name, 'invert(snap_edges(!box))')
        self.assertEqual(Model.box().snap_edges().repair().name, 'snap_edges(repair(!box))')
        self.assertEqual(Model.box().snap_edges().snap_edges().name, 'snap_edges(!box)')
        self.assertEqual(Model.box().snap_edges().transform(self.M).name, f'snap_edges(!box@{self.M_hash})')
        self.assertEqual(Model.box().snap_edges().uv_remap('sphere').name, 'uv_remap(snap_edges(!box), sphere)')
        self.assertEqual(Model.box().snap_edges().trim(self.P, self.N).name, f'trim(!box, {self.PN_hash})')

    def test_transform(self):
        self.assertEqual(Model.box().transform(Matrix44()).name, '!box')
        self.assertEqual(Model.box().transform(self.M).name, f'!box@{self.M_hash}')
        self.assertEqual(Model.box().transform(self.M).flatten().name, f'flatten(!box@{self.M_hash})')
        self.assertEqual(Model.box().transform(self.M).invert().name, f'invert(!box@{self.M_hash})')
        self.assertEqual(Model.box().transform(self.M).repair().name, f'repair(!box)@{self.M_hash}')
        self.assertEqual(Model.box().transform(self.M).snap_edges().name, f'snap_edges(!box@{self.M_hash})')
        self.assertEqual(Model.box().transform(self.M).transform(self.M).name, f'!box@{self.M2_hash}')
        self.assertEqual(Model.box().transform(self.M).uv_remap('sphere').name, f'uv_remap(!box@{self.M_hash}, sphere)')
        self.assertEqual(Model.box().transform(self.M).trim(self.P, self.N).name, f'trim(!box@{self.M_hash}, {self.PN_hash})')

    def test_uvremap(self):
        self.assertEqual(Model.box().uv_remap('sphere').name, 'uv_remap(!box, sphere)')
        self.assertEqual(Model.box().uv_remap('sphere').flatten().name, 'flatten(uv_remap(!box, sphere))')
        self.assertEqual(Model.box().uv_remap('sphere').invert().name, 'invert(uv_remap(!box, sphere))')
        self.assertEqual(Model.box().uv_remap('sphere').repair().name, 'uv_remap(repair(!box), sphere)')
        self.assertEqual(Model.box().uv_remap('sphere').snap_edges().name, 'snap_edges(uv_remap(!box, sphere))')
        self.assertEqual(Model.box().uv_remap('sphere').transform(self.M).name, f'uv_remap(!box, sphere)@{self.M_hash}')
        self.assertEqual(Model.box().uv_remap('test').uv_remap('sphere').name, 'uv_remap(!box, sphere)')
        self.assertEqual(Model.box().uv_remap('sphere').trim(self.P, self.N).name, f'trim(uv_remap(!box, sphere), {self.PN_hash})')

    def test_trim(self):
        self.assertEqual(Model.box().trim(self.P, self.N).name, f'trim(!box, {self.PN_hash})')
        self.assertEqual(Model.box().trim(self.P, self.N).flatten().name, f'flatten(trim(!box, {self.PN_hash}))')
        self.assertEqual(Model.box().trim(self.P, self.N).invert().name, f'invert(trim(!box, {self.PN_hash}))')
        self.assertEqual(Model.box().trim(self.P, self.N).repair().name, f'trim(repair(!box), {self.PN_hash})')
        self.assertEqual(Model.box().trim(self.P, self.N).snap_edges().name, f'snap_edges(trim(!box, {self.PN_hash}))')
        MPN_hash = hex((self.M @ self.P).hash(False) ^ (self.M.inverse_transpose_matrix33() @ self.N).hash(False))[2:]
        self.assertEqual(Model.box().trim(self.P, self.N).transform(self.M).name, f'trim(!box@{self.M_hash}, {MPN_hash})')
        self.assertEqual(Model.box().trim(self.P, self.N).uv_remap('sphere').name, f'uv_remap(trim(!box, {self.PN_hash}), sphere)')
        self.assertEqual(Model.box().trim(self.P, self.N).trim(self.P, self.N).name, f'trim(trim(!box, {self.PN_hash}), {self.PN_hash})')

    def test_union(self):
        self.assertIsNone(Model.union())
        self.assertEqual(Model.union(Model.box()).name, '!box')
        self.assertEqual(Model.union(Model.box(), Model.box()).name, '!box')
        self.assertEqual(Model.union(Model.box(), Model.sphere()).name, 'union(!box, !sphere)')
        self.assertEqual(Model.union(Model.box(), Model.sphere(), Model.box()).name, 'union(!box, !sphere)')
        self.assertEqual(Model.union(Model.box(), Model.union(Model.sphere(), Model.cylinder())).name, 'union(!box, !sphere, !cylinder)')
        self.assertEqual(Model.union(Model.box(), Model.sphere()).flatten().name, 'flatten(union(!box, !sphere))')
        self.assertEqual(Model.union(Model.box(), Model.sphere()).invert().name, 'invert(union(!box, !sphere))')
        self.assertEqual(Model.union(Model.box(), Model.sphere()).repair().name, 'union(!box, !sphere)')
        self.assertEqual(Model.union(Model.box(), Model.sphere()).snap_edges().name, 'snap_edges(union(!box, !sphere))')
        self.assertEqual(Model.union(Model.box(), Model.sphere()).transform(self.M).name, f'union(!box@{self.M_hash}, !sphere@{self.M_hash})')
        self.assertEqual(Model.union(Model.box(), Model.sphere()).uv_remap('sphere').name, 'uv_remap(union(!box, !sphere), sphere)')
        self.assertEqual(Model.union(Model.box(), Model.sphere()).trim(self.P, self.N).name, f'trim(union(!box, !sphere), {self.PN_hash})')

    def test_intersect(self):
        self.assertIsNone(Model.intersect())
        self.assertEqual(Model.intersect(Model.box()).name, '!box')
        self.assertEqual(Model.intersect(Model.box(), Model.box()).name, '!box')
        self.assertEqual(Model.intersect(Model.box(), Model.sphere()).name, 'intersect(!box, !sphere)')
        self.assertEqual(Model.intersect(Model.box(), Model.sphere(), Model.box()).name, 'intersect(!box, !sphere)')
        self.assertEqual(Model.intersect(Model.box(), Model.sphere()).flatten().name, 'flatten(intersect(!box, !sphere))')
        self.assertEqual(Model.intersect(Model.box(), Model.sphere()).invert().name, 'invert(intersect(!box, !sphere))')
        self.assertEqual(Model.intersect(Model.box(), Model.sphere()).repair().name, 'intersect(!box, !sphere)')
        self.assertEqual(Model.intersect(Model.box(), Model.sphere()).snap_edges().name, 'snap_edges(intersect(!box, !sphere))')
        self.assertEqual(Model.intersect(Model.box(), Model.sphere()).transform(self.M).name, f'intersect(!box@{self.M_hash}, !sphere@{self.M_hash})')
        self.assertEqual(Model.intersect(Model.box(), Model.sphere()).uv_remap('sphere').name, 'uv_remap(intersect(!box, !sphere), sphere)')
        self.assertEqual(Model.intersect(Model.box(), Model.sphere()).trim(self.P, self.N).name, f'intersect(trim(!box, {self.PN_hash}), !sphere)')

    def test_difference(self):
        self.assertIsNone(Model.difference())
        self.assertEqual(Model.difference(Model.box()).name, '!box')
        self.assertIsNone(Model.difference(Model.box(), Model.box()))
        self.assertEqual(Model.difference(Model.box(), Model.sphere()).name, 'difference(!box, !sphere)')
        self.assertIsNone(Model.difference(Model.box(), Model.sphere(), Model.box()))
        self.assertEqual(Model.difference(Model.box(), Model.sphere()).flatten().name, 'flatten(difference(!box, !sphere))')
        self.assertEqual(Model.difference(Model.box(), Model.sphere()).invert().name, 'invert(difference(!box, !sphere))')
        self.assertEqual(Model.difference(Model.box(), Model.sphere()).repair().name, 'difference(!box, !sphere)')
        self.assertEqual(Model.difference(Model.box(), Model.sphere()).snap_edges().name, 'snap_edges(difference(!box, !sphere))')
        self.assertEqual(Model.difference(Model.box(), Model.sphere()).transform(self.M).name, f'difference(!box@{self.M_hash}, !sphere@{self.M_hash})')
        self.assertEqual(Model.difference(Model.box(), Model.sphere()).uv_remap('sphere').name, 'uv_remap(difference(!box, !sphere), sphere)')
        self.assertEqual(Model.difference(Model.box(), Model.sphere()).trim(self.P, self.N).name, f'difference(trim(!box, {self.PN_hash}), !sphere)')
