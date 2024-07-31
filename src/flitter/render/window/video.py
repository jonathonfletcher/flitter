"""
Video window node
"""

from av.video.reformatter import VideoReformatter

from . import COLOR_FORMATS
from ...cache import SharedCache
from .glconstants import GL_SRGB8_ALPHA8
from .glsl import TemplateLoader
from .shaders import Shader


Reformatter = VideoReformatter()


class Video(Shader):
    DEFAULT_VERTEX_SOURCE = TemplateLoader.get_template('video.vert')
    DEFAULT_FRAGMENT_SOURCE = TemplateLoader.get_template('video.frag')

    def __init__(self, glctx):
        super().__init__(glctx)
        self._filename = None
        self._threading = None
        self._frame0 = None
        self._frame1 = None
        self._frame0_texture = None
        self._frame1_texture = None
        self._colorbits = None

    def release(self):
        if self._filename is not None:
            SharedCache[self._filename].read_video_frames(self, None, threading=self._threading)
            self._filename = None
            self._threading = None
        self._frame0_texture = None
        self._frame1_texture = None
        self._frame0 = None
        self._frame1 = None
        self._colorbits = None
        super().release()

    @property
    def child_textures(self):
        return {'frame0': self._frame0_texture, 'frame1': self._frame1_texture}

    def similar_to(self, node):
        return super().similar_to(node) and node.get('filename', 1, str) == self._filename

    async def descend(self, engine, node, **kwargs):
        # A video is a leaf node from the perspective of the OpenGL world
        pass

    def render(self, node, **kwargs):
        self._filename = node.get('filename', 1, str)
        position = node.get('position', 1, float, 0)
        loop = node.get('loop', 1, bool, False)
        self._threading = node.get('thread', 1, bool, False)
        aspect = {'fit': 1, 'fill': 2}.get(node.get('aspect', 1, str), 0)
        if self._filename is not None:
            ratio, frame0, frame1 = SharedCache[self._filename].read_video_frames(self, position, loop, threading=self._threading)
        else:
            ratio, frame0, frame1 = 0, None, None
        colorbits = node.get('colorbits', 1, int, self.glctx.extra['colorbits'])
        if colorbits not in COLOR_FORMATS:
            colorbits = self.glctx.extra['colorbits']
        if self._frame0_texture is not None and (frame0 is None or (frame0.width, frame0.height) != self._frame0_texture.size):
            self._frame0_texture = None
            self._frame1_texture = None
            self._frame0 = None
            self._frame1 = None
        if frame0 is None:
            self.framebuffer.clear()
            return
        frame_size = frame0.width, frame0.height
        if self._frame0_texture is None:
            self._frame0_texture = self.glctx.texture(frame_size, 4, internal_format=GL_SRGB8_ALPHA8)
            self._frame1_texture = self.glctx.texture(frame_size, 4, internal_format=GL_SRGB8_ALPHA8)
        if frame0 is self._frame1 or frame1 is self._frame0:
            self._frame0_texture, self._frame1_texture = self._frame1_texture, self._frame0_texture
            self._frame0, self._frame1 = self._frame1, self._frame0
        if frame0 is not self._frame0:
            rgb_frame = Reformatter.reformat(frame0, format='rgba')
            plane = rgb_frame.planes[0]
            data = rgb_frame.to_ndarray().data if plane.line_size > plane.width * 4 else plane
            self._frame0_texture.write(memoryview(data))
            self._frame0 = frame0
        if frame1 is None:
            self._frame1 = None
        elif frame1 is not self._frame1:
            rgb_frame = Reformatter.reformat(frame1, format='rgba')
            plane = rgb_frame.planes[0]
            data = rgb_frame.to_ndarray().data if plane.line_size > plane.width * 4 else plane
            self._frame1_texture.write(memoryview(data))
            self._frame1 = frame1
        interpolate = node.get('interpolate', 1, bool, False)
        super().render(node, frame_size=frame_size, aspect_mode=aspect, ratio=ratio if interpolate else 0, **kwargs)
