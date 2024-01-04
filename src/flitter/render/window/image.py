"""
Video scene node
"""

import PIL.Image

from . import SceneNode, COLOR_FORMATS
from ...cache import SharedCache
from .glconstants import GL_SRGB8


class Image(SceneNode):
    def __init__(self, glctx):
        super().__init__(glctx)
        self._filename = None
        self._image = None
        self._texture = None

    def release(self):
        print('released', self, self._filename)
        self._filename = None
        self._image = None
        self._texture = None

    @property
    def texture(self):
        return self._texture

    async def update(self, engine, node, default_size=(512, 512), **kwargs):
        references = kwargs.setdefault('references', {})
        if node_id := node.get('id', 1, str):
            references[node_id] = self
        self.hidden = node.get('hidden', 1, bool, False)
        self.tags = node.tags
        filename = node.get('filename', 1, str)
        if filename != self._filename:
            self.release()
            self._filename = filename
        if self._filename is not None:
            image = SharedCache[filename].read_pil_image()
            if image is not self._image:
                self._image = image
                self.width = self._image.width
                self.height = self._image.height
                flipped = self._image.transpose(PIL.Image.FLIP_TOP_BOTTOM)
                if self._image.has_transparency_data:
                    self._texture = self.glctx.texture((self.width, self.height), 4, internal_format=GL_SRGB8)
                    self._texture.write(flipped.convert('RGBA').convert('RGBa').tobytes())
                else:
                    self._texture = self.glctx.texture((self.width, self.height), 3, internal_format=GL_SRGB8)
                    self._texture.write(flipped.convert('RGB').tobytes())

    def similar_to(self, node):
        return super().similar_to(node) and node.get('filename', 1, str) == self._filename


SCENE_NODE_CLASS = Image
