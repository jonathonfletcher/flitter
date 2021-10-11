"""
Flitter window management
"""

# pylama:ignore=C0413,E402,W0703,R0914,R0902,R0912,R0201,R1702

import array
import logging
import time

import cairo
import moderngl
import numpy as np

import pyglet
pyglet.options['shadow_window'] = False

import pyglet.canvas
import pyglet.window
import pyglet.gl

from . import canvas


Log = logging.getLogger(__name__)


class SceneNode:
    def __init__(self, glctx):
        self.glctx = glctx
        self.children = []
        self.width = None
        self.height = None
        self.node = None

    @property
    def texture(self):
        raise NotImplementedError()

    @property
    def sampler_args(self):
        return {'repeat_x': False, 'repeat_y': False}

    def destroy(self):
        self.release()
        self.glctx = None
        while self.children:
            self.children.pop().destroy()

    def update(self, node):
        self.node = node
        resized = False
        width, height = self.node.get('size', 2, int, (512, 512))
        if width != self.width or height != self.height:
            self.width = width
            self.height = height
            resized = True
        self.create(resized)
        self.descend()
        self.render()

    def descend(self):
        count = 0
        for i, child in enumerate(self.node.children):
            cls = SCENE_CLASSES[child.kind]
            if i == len(self.children):
                self.children.append(cls(self.glctx))
            elif type(self.children[i]) != cls:  # noqa
                self.children[i].destroy()
                self.children[i] = cls(self.glctx)
            self.children[i].update(child)
            count += 1
        while len(self.children) > count:
            self.children.pop().destroy()

    def create(self, resized):
        pass

    def render(self):
        raise NotImplementedError()

    def release(self):
        raise NotImplementedError()


class ProgramNode(SceneNode):
    def __init__(self, glctx):
        super().__init__(glctx)
        self._program = None
        self._rectangle = None
        self._vertex_source = None
        self._fragment_source = None
        self._timestamp = None
        self._last = None

    def release(self):
        if self._last is not None:
            self._last.release()
            self._last = None
        if self._program is not None:
            self._program.release()
            self._program = None
        if self._rectangle is not None:
            self._rectangle.release()
            self._rectangle = None

    def get_vertex_source(self):
        return """#version 410
in vec2 position;
out vec2 coord;
void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    coord = (position + 1.0) / 2.0;
}
"""

    def get_fragment_source(self):
        samplers = '\n'.join(f"uniform sampler2D texture{i};\n" for i in range(len(self.children)))
        textures = '\n'.join(f"    color += texture(texture{i}, coord);\n" for i in range(len(self.children)))
        return f"""#version 410
precision highp float;
in vec2 coord;
out vec4 color;
{samplers}
void main() {{
    color = vec4(0.0, 0.0, 0.0, 0.0);
{textures}
}}
"""

    def compile(self):
        vertex_source = self.get_vertex_source()
        fragment_source = self.get_fragment_source()
        if vertex_source != self._vertex_source or fragment_source != self._fragment_source:
            self._vertex_source = vertex_source
            self._fragment_source = fragment_source
            if self._program is not None:
                self._program.release()
                self._program = None
            if self._rectangle is not None:
                self._rectangle.release()
                self._rectangle = None
            try:
                self._program = self.glctx.program(vertex_shader=self._vertex_source, fragment_shader=self._fragment_source)
                vertices = self.glctx.buffer(array.array('f', [-1, 1, -1, -1, 1, 1, 1, -1]))
                self._rectangle = self.glctx.vertex_array(self._program, [(vertices, '2f', 'position')])
            except Exception:
                Log.exception("Unable to compile shader")
            print(self, self.children)
            print(self._fragment_source)

    @property
    def framebuffer(self):
        raise NotImplementedError()

    def render(self):
        now = time.clock_gettime(time.CLOCK_MONOTONIC_RAW)
        delta = 0.0 if self._timestamp is None else now - self._timestamp
        self._timestamp = now
        self.compile()
        if self._rectangle is not None:
            self.framebuffer.use()
            samplers = []
            unit = 0
            last = False
            for name in self._program:
                member = self._program[name]
                if isinstance(member, moderngl.Uniform):
                    if name == 'delta':
                        member.value = delta
                    elif name == 'last':
                        if self._last is None:
                            self._last = self.glctx.texture((self.width, self.height), 4)
                        self._last.use(location=unit)
                        member.value = unit
                        unit += 1
                        last = True
                    elif name.startswith('texture'):
                        index = int(name[7:])
                        if index < len(self.children):
                            child = self.children[index]
                            sampler_args = child.sampler_args
                            if sampler_args:
                                sampler = self.glctx.sampler(texture=child.texture, **sampler_args)
                                sampler.use(location=unit)
                                samplers.append(sampler)
                            else:
                                child.texture.use(location=unit)
                            member.value = unit
                            unit += 1
                    elif name in self.node:
                        value = self.node.get(name, member.dimension, float)
                        if value is not None:
                            member.value = value if member.dimension == 1 else tuple(value)
            self.framebuffer.clear()
            self._rectangle.render(mode=moderngl.TRIANGLE_STRIP)
            for sampler in samplers:
                sampler.clear()
                sampler.release()
            if last:
                self.glctx.copy_framebuffer(self._last, self.framebuffer)


class Window(ProgramNode):
    GL_VERSION = (4, 1)

    class WindowWrapper(pyglet.window.Window):  # noqa
        """Disable some pyglet functionality that is broken on moderngl"""
        def on_resize(self, width, height):
            pass

        def on_draw(self):
            pass

    def __init__(self):
        super().__init__(None)
        self.window = None
        self.fullscreen = None

    def release(self):
        if self.window is not None:
            self.window.close()
            self.window = None
        super().release()

    @property
    def texture(self):
        return None

    def create(self, resized):
        super().create(resized)
        if self.window is None:
            vsync = self.node.get('vsync', 1, bool, True)
            self.fullscreen = self.node.get('fullscreen', 1, bool, False)
            screen = self.node.get('screen', 1, int, 0)
            title = self.node.get('title', 1, str, "Flitter")
            screens = pyglet.canvas.get_display().get_screens()
            screen = screens[screen] if screen < len(screens) else screens[0]
            config = pyglet.gl.Config(major_version=self.GL_VERSION[0], minor_version=self.GL_VERSION[1], forward_compatible=True,
                                      depth_size=24, double_buffer=True, sample_buffers=1, samples=0)
            if self.fullscreen:
                self.window = self.WindowWrapper(fullscreen=True, caption=title, screen=screen, vsync=vsync, config=config)
            else:
                self.window = self.WindowWrapper(width=self.width, height=self.height, resizable=False, caption=title, screen=screen, vsync=vsync, config=config)
            self.glctx = moderngl.create_context(require=self.GL_VERSION[0] * 100 + self.GL_VERSION[1])
        else:
            fullscreen = self.node.get('fullscreen', 1, bool, False)
            if resized:
                if not self.fullscreen:
                    self.window.set_size(self.width, self.height)
            if fullscreen != self.fullscreen:
                self.window.set_fullscreen(fullscreen)
                if self.fullscreen:
                    self.window.set_size(self.width, self.height)
                self.fullscreen = fullscreen

    @property
    def framebuffer(self):
        return self.glctx.screen

    def render(self):
        if self.fullscreen:
            aspect_ratio = self.width / self.height
            width, height = self.glctx.screen.width, self.glctx.screen.height
            if width / height > aspect_ratio:
                view_width = int(height * aspect_ratio)
                self.glctx.screen.viewport = ((width - view_width) // 2, 0, view_width, height)
            else:
                view_height = int(width / aspect_ratio)
                self.glctx.screen.viewport = (0, (height - view_height) // 2, width, view_height)
        super().render()
        self.window.flip()
        self.window.dispatch_events()


class Shader(ProgramNode):
    def __init__(self, glctx):
        super().__init__(glctx)
        self._framebuffer = None
        self._texture = None

    @property
    def texture(self):
        return self._texture

    def release(self):
        if self._framebuffer is not None:
            self._framebuffer.release()
            self._framebuffer = None
        if self._texture is not None:
            self._texture.release()
            self._texture = None
        super().release()

    def create(self, resized):
        super().create(resized)
        if self._framebuffer is None or self._texture is None or resized:
            if self._framebuffer is not None:
                self._framebuffer.release()
            if self._texture is not None:
                self._texture.release()
            self._texture = self.glctx.texture((self.width, self.height), 4)
            self._framebuffer = self.glctx.framebuffer(color_attachments=(self._texture,))
            self._framebuffer.clear()

    def get_vertex_source(self):
        return self.node.get('vertex', 1, str, super().get_vertex_source())

    def get_fragment_source(self):
        return self.node.get('fragment', 1, str, super().get_fragment_source())

    @property
    def framebuffer(self):
        return self._framebuffer


class Canvas(SceneNode):
    def __init__(self, glctx):
        super().__init__(glctx)
        self._surface = None
        self._array = None
        self._texture = None

    @property
    def texture(self):
        return self._texture

    def release(self):
        if self._texture is not None:
            self._texture.release()
            self._texture = None
        if self._surface is not None:
            self._array = None
            self._surface.finish()
            self._surface = None

    def create(self, resized):
        if resized:
            if self._surface is not None:
                self._array = None
                self._surface.finish()
            self._surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, self.width, self.height)
            self._array = np.ndarray(buffer=self._surface.get_data(), shape=(self.height, self.width), dtype='uint32')
            if self._texture is not None:
                self._texture.release()
            self._texture = self.glctx.texture((self.width, self.height), 4)
            self._texture.swizzle = 'BGRA'
        else:
            self._array[:, :] = 0

    def descend(self):
        # A canvas is a leaf node from the perspective of the OpenGL world
        pass

    def render(self):
        if self._texture is not None:
            ctx = cairo.Context(self._surface)
            # OpenGL and Cairo worlds are upside-down vs each other
            ctx.translate(0, self.height)
            ctx.scale(1, -1)
            canvas.draw(self.node, ctx)
            self.texture.write(self._surface.get_data())


SCENE_CLASSES = {'shader': Shader, 'canvas': Canvas}
