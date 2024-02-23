"""
Flitter functional testing
"""

import asyncio
from pathlib import Path
import tempfile
import unittest

import PIL.Image
import PIL.ImageChops
import PIL.ImageStat

from flitter.engine.control import EngineController


def image_diff(ref, img):
    """Return how dissimilar two images are as a score between 0 (identical) and 1 (completely different)"""
    return PIL.ImageStat.Stat(PIL.ImageChops.difference(ref, img).convert('L')).sum[0] / (img.width * img.height * 255)


class TestRendering(unittest.TestCase):
    """
    Some simple rendering functional tests

    Scripts will be executed for a single frame and a `SIZE` image should be
    saved to the filename `OUTPUT`.
    """

    SIZE = (200, 100)

    def setUp(self):
        self.script_path = Path(tempfile.mktemp('.fl'))
        self.input_path = Path(tempfile.mktemp('.png'))
        self.output_path = Path(tempfile.mktemp('.png'))
        self.controller = EngineController(realtime=False, target_fps=1, run_time=1, offscreen=True,
                                           defined_names={'SIZE': self.SIZE,
                                                          'INPUT': str(self.input_path),
                                                          'OUTPUT': str(self.output_path)})

    def tearDown(self):
        if self.script_path.exists():
            self.script_path.unlink()
        if self.input_path.exists():
            self.input_path.unlink()
        if self.output_path.exists():
            self.output_path.unlink()

    def test_simple_canvas(self):
        """Render a simple green rectangle filling the viewport"""
        self.script_path.write_text("""
!window size=SIZE
    !record filename=OUTPUT
        !canvas
            !path
                !rect size=SIZE
                !fill color=0;1;0
""", encoding='utf8', newline='\n')
        self.controller.load_page(self.script_path)
        asyncio.run(self.controller.run())
        img = PIL.Image.open(self.output_path)
        self.assertEqual(img.size, self.SIZE)
        self.assertEqual(img.tobytes(), b'\x00\xff\x00' * self.SIZE[0] * self.SIZE[1])

    def test_simple_canvas3d(self):
        """Render a simple green emissive box filling the viewport"""
        self.script_path.write_text("""
!window size=SIZE
    !record filename=OUTPUT
        !canvas3d orthographic=true
            !box size=SIZE*(1;1;0) emissive=0;1;0
""", encoding='utf8', newline='\n')
        self.controller.load_page(self.script_path)
        asyncio.run(self.controller.run())
        img = PIL.Image.open(self.output_path)
        self.assertEqual(img.size, self.SIZE)
        self.assertEqual(img.tobytes(), b'\x00\xff\x00' * self.SIZE[0] * self.SIZE[1])

    def test_simple_shader(self):
        """Render a simple shader that returns green for all fragments"""
        self.script_path.write_text("""
!window size=SIZE
    !record filename=OUTPUT
        !shader fragment='''#version 330
                            in vec2 coord;
                            out vec4 color;
                            void main() {
                                color = vec4(0, 1, 0, 1);
                            }'''
""", encoding='utf8', newline='\n')
        self.controller.load_page(self.script_path)
        asyncio.run(self.controller.run())
        img = PIL.Image.open(self.output_path)
        self.assertEqual(img.size, self.SIZE)
        self.assertEqual(img.tobytes(), b'\x00\xff\x00' * self.SIZE[0] * self.SIZE[1])

    def test_simple_image(self):
        """Render an image node from a simple temporary image"""
        PIL.Image.new('RGB', self.SIZE, (0, 255, 0)).save(self.input_path, 'PNG')
        self.script_path.write_text("""
!window size=SIZE
    !record filename=OUTPUT
        !image filename=INPUT
""", encoding='utf8', newline='\n')
        self.controller.load_page(self.script_path)
        asyncio.run(self.controller.run())
        img = PIL.Image.open(self.output_path)
        self.assertEqual(img.size, self.SIZE)
        self.assertEqual(img.tobytes(), b'\x00\xff\x00' * self.SIZE[0] * self.SIZE[1])


class TestDocumentationDiagrams(unittest.TestCase):
    """
    Recreate the documentation diagrams and check them against the pre-calculated ones.
    Some amount of difference is expected here because the GitHub workflow tests run on
    Ubuntu and the font availability is different. There also seems to be an issue with
    Skia not doing anti-aliasing in Xvfb (Mesa).
    """

    def test_diagrams(self):
        scripts_dir = Path(__file__).parent.parent / 'docs/diagrams'
        scripts = sorted(path for path in scripts_dir.iterdir() if path.suffix == '.fl')
        self.assertTrue(len(scripts) > 0)
        for i, script in enumerate(scripts):
            with self.subTest(script=script):
                output_path = Path(tempfile.mktemp('.png'))
                try:
                    reference = PIL.Image.open(script.with_suffix('.png'))
                    controller = EngineController(realtime=False, target_fps=1, run_time=1, offscreen=True,
                                                  defined_names={'OUTPUT': str(output_path)})
                    controller.load_page(script)
                    asyncio.run(controller.run())
                    output = PIL.Image.open(output_path)
                    self.assertEqual(reference.size, output.size)
                    self.assertLess(image_diff(reference, output), 0.002)
                finally:
                    if output_path.exists():
                        output_path.unlink()


class TestDocumentationTutorial(unittest.TestCase):
    """
    Recreate the tutorial images and check them against the pre-calculated ones.
    """

    def test_diagrams(self):
        scripts_dir = Path(__file__).parent.parent / 'docs/tutorial_images'
        scripts = sorted(path for path in scripts_dir.iterdir() if path.suffix == '.fl')
        self.assertTrue(len(scripts) > 0)
        for i, script in enumerate(scripts):
            with self.subTest(script=script):
                output_path = Path(tempfile.mktemp('.jpg'))
                try:
                    reference = PIL.Image.open(script.with_suffix('.jpg'))
                    controller = EngineController(realtime=False, target_fps=1, run_time=1, offscreen=True,
                                                  defined_names={'OUTPUT': str(output_path)})
                    controller.load_page(script)
                    asyncio.run(controller.run())
                    output = PIL.Image.open(output_path)
                    self.assertEqual(reference.size, output.size)
                    self.assertLess(image_diff(reference, output), 0.005)
                finally:
                    if output_path.exists():
                        output_path.unlink()
