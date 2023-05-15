"""
The main Flitter engine
"""

import asyncio
import gc
from pathlib import Path
import pickle

from loguru import logger

from ..cache import SharedCache
from ..clock import BeatCounter, system_clock
from ..interface.controls import Pad, Encoder
from ..interface.osc import OSCReceiver, OSCSender, OSCMessage, OSCBundle
from ..model import Context, StateDict, Vector
from ..render import process, get_renderer
from ..controller import Controller


class EngineController:
    SEND_PORT = 47177
    RECEIVE_PORT = 47178

    def __init__(self, target_fps=60, screen=0, fullscreen=False, vsync=False, state_file=None, multiprocess=True,
                 autoreset=None, state_eval_wait=0, realtime=True, defined_variables=None):
        self.target_fps = target_fps
        self.realtime = realtime
        self.screen = screen
        self.fullscreen = fullscreen
        self.vsync = vsync
        self.multiprocess = multiprocess
        self.autoreset = autoreset
        self.state_eval_wait = state_eval_wait
        if defined_variables:
            self.defined_variables = {key: Vector.coerce(value) for key, value in defined_variables.items()}
        else:
            self.defined_variables = {}
        self.state_file = Path(state_file) if state_file is not None else None
        if self.state_file is not None and self.state_file.exists():
            logger.info("Recover state from state file: {}", self.state_file)
            with open(self.state_file, 'rb') as file:
                self.global_state = pickle.load(file)
        else:
            self.global_state = {}
        self.global_state_dirty = False
        self.state = None
        self.state_timestamp = None
        self.renderers = {}
        self.controllers = []
        self.counter = BeatCounter()
        self.pads = {}
        self.encoders = {}
        self.osc_sender = OSCSender('localhost', self.SEND_PORT)
        self.osc_receiver = OSCReceiver('localhost', self.RECEIVE_PORT)
        self.queue = []
        self.pages = []
        self.next_page = None
        self.current_page = None
        self.current_path = None

    def load_page(self, filename):
        page_number = len(self.pages)
        path = SharedCache[filename]
        self.pages.append((path, self.global_state.setdefault(page_number, StateDict())))
        logger.info("Added code page {}: {}", page_number, path)

    def switch_to_page(self, page_number):
        if self.pages is not None and 0 <= page_number < len(self.pages):
            self.pads = {}
            self.encoders = {}
            path, state = self.pages[page_number]
            self.state = state
            self.state_timestamp = system_clock()
            self.current_path = path
            self.current_page = page_number
            SharedCache.set_root(self.current_path)
            logger.info("Switched to page {}: {}", page_number, self.current_path)
            self.enqueue_reset()
            if counter_state := self.state['_counter']:
                tempo, quantum, start = counter_state
                self.counter.update(tempo, int(quantum), start)
                logger.info("Restore counter at beat {:.1f}, tempo {:.1f}, quantum {}", self.counter.beat, self.counter.tempo, self.counter.quantum)
                self.enqueue_tempo()
            self.enqueue_page_status()
            for renderers in self.renderers.values():
                for renderer in renderers:
                    renderer.purge()

    async def update_renderers(self, graph, **kwargs):
        nodes_by_kind = {}
        for node in graph.children:
            nodes_by_kind.setdefault(node.kind, []).append(node)
        async with asyncio.TaskGroup() as group:
            for kind, nodes in nodes_by_kind.items():
                renderer_class = get_renderer(kind)
                if renderer_class is not None:
                    references = {}
                    renderers = self.renderers.setdefault(node.kind, [])
                    count = 0
                    for node in nodes:
                        if count == len(renderers):
                            if self.multiprocess:
                                renderer = process.Proxy(renderer_class, **kwargs)
                            else:
                                renderer = renderer_class(**kwargs)
                            renderers.append(renderer)
                        group.create_task(renderers[count].update(node, self.state, references=references, **kwargs))
                        count += 1
                    while len(renderers) > count:
                        renderers.pop().destroy()

    async def update_controllers(self, graph, frame_time):
        async with asyncio.TaskGroup() as group:
            count = 0
            for node in graph.select('* > controller'):
                if count == len(self.controllers):
                    controller = Controller()
                    self.controllers.append(controller)
                group.create_task(self.controllers[count].update(node, self.counter, self.state, frame_time))
                count += 1
            while len(self.controllers) > count:
                self.controllers.pop().destroy()

    def update_controls(self, graph):
        remaining = set(self.pads)
        for node in graph.select_below('pad.'):
            if (number := node.get('number', 2, int)) is not None:
                number = tuple(number)
                if number not in self.pads:
                    logger.debug("New pad @ {!r}", number)
                    pad = self.pads[number] = Pad(number)
                elif number in remaining:
                    pad = self.pads[number]
                    remaining.remove(number)
                else:
                    continue
                if pad.update(node, self.counter.beat, self.state):
                    self.enqueue_pad_status(pad)
        for number in remaining:
            self.enqueue_pad_status(self.pads[number], deleted=True)
            del self.pads[number]
        remaining = set(self.encoders)
        for node in graph.select_below('encoder.'):
            if (number := node.get('number', 1, int)) is not None:
                if number not in self.encoders:
                    logger.debug("New encoder @ {!r}", number)
                    encoder = self.encoders[number] = Encoder(number)
                elif number in remaining:
                    encoder = self.encoders[number]
                    remaining.remove(number)
                else:
                    continue
                if encoder.update(node, self.counter.beat, self.state):
                    self.enqueue_encoder_status(encoder)
        for number in remaining:
            self.enqueue_encoder_status(self.encoders[number], deleted=True)
            del self.encoders[number]

    def enqueue_reset(self):
        self.queue.append(OSCMessage('/reset'))

    def enqueue_pad_status(self, pad, deleted=False):
        address = '/pad/' + '/'.join(str(n) for n in pad.number) + '/state'
        if deleted:
            self.queue.append(OSCMessage(address))
        else:
            self.queue.append(OSCMessage(address, pad.name, *pad.color, pad.quantize, pad.touched, pad.toggled))

    def enqueue_encoder_status(self, encoder, deleted=False):
        address = f'/encoder/{encoder.number}/state'
        if deleted:
            self.queue.append(OSCMessage(address))
        else:
            self.queue.append(OSCMessage(address, encoder.name, *encoder.color, encoder.touched, encoder.value,
                                         encoder.lower, encoder.upper, encoder.origin, encoder.decimals, encoder.percent))

    def enqueue_tempo(self):
        self.queue.append(OSCMessage('/tempo', self.counter.tempo, self.counter.quantum, self.counter.start))

    def enqueue_page_status(self):
        self.queue.append(OSCMessage('/page_left', self.current_page > 0))
        self.queue.append(OSCMessage('/page_right', self.current_page < len(self.pages) - 1))

    def process_message(self, message):
        if isinstance(message, OSCBundle):
            for element in message.elements:
                self.process_message(element)
            return
        logger.trace("Received OSC message: {!r}", message)
        parts = message.address.strip('/').split('/')
        if parts[0] == 'hello':
            self.enqueue_tempo()
            for pad in self.pads.values():
                self.enqueue_pad_status(pad)
            for encoder in self.encoders.values():
                self.enqueue_encoder_status(encoder)
            self.enqueue_page_status()
        elif parts[0] == 'tempo':
            tempo, quantum, start = message.args
            self.counter.update(tempo, int(quantum), start)
            self.state['_counter'] = tempo, int(quantum), start
            self.enqueue_tempo()
        elif parts[0] == 'pad':
            number = tuple(int(n) for n in parts[1:-1])
            if number in self.pads:
                pad = self.pads[number]
                timestamp, *args = message.args
                beat = self.counter.beat_at_time(timestamp)
                toggled = None
                if parts[-1] == 'touched':
                    pad.on_touched(beat)
                    toggled = pad.on_pressure(beat, *args)
                elif parts[-1] == 'held':
                    toggled = pad.on_pressure(beat, *args)
                elif parts[-1] == 'released':
                    pad.on_pressure(beat, 0.0)
                    pad.on_released(beat)
                if toggled and pad.group is not None:
                    for other in self.pads.values():
                        if other is not pad and other.group == pad.group and other.toggled:
                            other.toggled = False
                            other._toggled_beat = beat  # noqa
                            self.enqueue_pad_status(other)
        elif parts[0] == 'encoder':
            number = int(parts[1])
            if number in self.encoders:
                encoder = self.encoders[number]
                timestamp, *args = message.args
                beat = self.counter.beat_at_time(timestamp)
                if parts[-1] == 'touched':
                    encoder.on_touched(beat)
                elif parts[-1] == 'turned':
                    encoder.on_turned(beat, *args)
                elif parts[-1] == 'released':
                    encoder.on_released(beat)
                elif parts[-1] == 'reset':
                    encoder.on_reset(beat)
        elif parts == ['page_left']:
            if self.current_page > 0:
                self.next_page = self.current_page - 1
        elif parts == ['page_right']:
            if self.current_page < len(self.pages) - 1:
                self.next_page = self.current_page + 1

    async def receive_messages(self):
        logger.info("Listening for OSC control messages on port {}", self.RECEIVE_PORT)
        while True:
            message = await self.osc_receiver.receive()
            self.process_message(message)

    def handle_pragmas(self, pragmas):
        if '_counter' not in self.state:
            tempo = pragmas.get('tempo')
            if tempo is not None and len(tempo) == 1 and isinstance(tempo[0], float) and tempo[0] > 0:
                tempo = tempo[0]
            else:
                tempo = 120
            quantum = pragmas.get('quantum')
            if quantum is not None and len(quantum) == 1 and isinstance(quantum[0], float) and quantum[0] >= 2:
                quantum = int(quantum[0])
            else:
                quantum = 4
            self.counter.update(tempo, quantum, system_clock())
            self.state['_counter'] = self.counter.tempo, self.counter.quantum, self.counter.start
            self.enqueue_tempo()
            logger.info("Start counter, tempo {}, quantum {}", self.counter.tempo, self.counter.quantum)

    def reset_state(self):
        self.state.clear()
        for pad in self.pads.values():
            pad.reset()
        for encoder in self.encoders.values():
            encoder.reset()
        self.state_timestamp = None
        self.global_state_dirty = True

    async def run(self):
        try:
            loop = asyncio.get_event_loop()
            loop.create_task(self.receive_messages())
            frames = []
            self.enqueue_reset()
            self.enqueue_page_status()
            frame_time = system_clock()
            last = self.counter.beat_at_time(frame_time)
            dump_time = frame_time
            execution = render = housekeeping = 0
            performance = 1
            gc.disable()
            run_top = current_top = None
            errors = set()
            logs = set()
            while True:
                housekeeping -= system_clock()

                program_top = self.current_path.read_flitter_program(self.defined_variables)
                if program_top is not current_top:
                    level = 'SUCCESS' if current_top is None else 'INFO'
                    logger.log(level, "Loaded page {}: {}", self.current_page, self.current_path)
                    run_top = current_top = program_top

                if current_top is not None and run_top is current_top and self.state_eval_wait and self.state_timestamp is not None and \
                        system_clock() > self.state_timestamp + self.state_eval_wait:
                    start = system_clock()
                    run_top = current_top.simplify(state=self.state)
                    logger.debug("Partially-evaluated current program on state in {:.1f}ms", (system_clock() - start) * 1000)
                    logger.opt(lazy=True).debug("Tree node count after partial-evaluation {after}",
                                                after=lambda: run_top.reduce(lambda e, *rs: sum(rs) + 1))

                if self.state.changed:
                    self.global_state_dirty = True
                    self.state_timestamp = system_clock()
                    self.state.clear_changed()
                    if run_top is not current_top:
                        logger.debug("Undo partial-evaluation on state")
                        run_top = current_top

                beat = self.counter.beat_at_time(frame_time)
                delta = beat - last
                last = beat
                names = {'beat': beat, 'quantum': self.counter.quantum, 'tempo': self.counter.tempo,
                         'delta': delta, 'clock': frame_time, 'performance': performance,
                         'fps': self.target_fps, 'realtime': self.realtime,
                         'screen': self.screen, 'fullscreen': self.fullscreen, 'vsync': self.vsync}

                now = system_clock()
                housekeeping += now
                execution -= now
                if current_top is not None:
                    context = run_top.run(state=self.state, variables=names)
                else:
                    context = Context()
                new_errors = context.errors.difference(errors)
                errors = context.errors
                for error in new_errors:
                    logger.error("Evaluation error: {}", error)
                new_logs = context.logs.difference(logs)
                logs = context.logs
                for log in new_logs:
                    print(log)
                now = system_clock()
                execution += now
                render -= now

                self.handle_pragmas(context.pragmas)
                self.update_controls(context.graph)
                async with asyncio.TaskGroup() as group:
                    group.create_task(self.update_renderers(context.graph, **names))
                    group.create_task(self.update_controllers(context.graph, frame_time))

                now = system_clock()
                render += now
                housekeeping -= now

                del context
                SharedCache.clean()

                if self.queue:
                    await self.osc_sender.send_bundle_from_queue(self.queue)

                if self.autoreset and self.state_timestamp is not None and system_clock() > self.state_timestamp + self.autoreset:
                    logger.debug("Auto-reset state")
                    self.reset_state()
                    current_top = program_top

                if self.global_state_dirty and self.state_file is not None and frame_time > dump_time + 1:
                    logger.debug("Saving state")
                    with open(self.state_file, 'wb') as file:
                        pickle.dump(self.global_state, file)
                    self.global_state_dirty = False
                    dump_time = frame_time

                if self.next_page is not None:
                    if self.autoreset:
                        self.reset_state()
                    self.switch_to_page(self.next_page)
                    self.next_page = None
                    run_top = current_top = None
                    performance = 1
                    count = gc.collect(2)
                    logger.trace("Collected {} objects (full collection)", count)

                elif count := gc.collect(0):
                    logger.trace("Collected {} objects", count)

                now = system_clock()
                frames.append(now)
                frame_period = now - frame_time
                housekeeping += now
                frame_time += 1 / self.target_fps
                if self.realtime:
                    wait_time = frame_time - now
                    performance = min(performance + 0.001, 2) if wait_time > 0.001 else max(0.5, performance - 0.01)
                else:
                    wait_time = 0.001
                    performance = 1
                if wait_time > 0:
                    await asyncio.sleep(wait_time)
                else:
                    logger.trace("Slow frame - {:.0f}ms", frame_period * 1000)
                    await asyncio.sleep(0)
                    frame_time = system_clock()

                if len(frames) > 1 and frames[-1] - frames[0] > 5:
                    nframes = len(frames) - 1
                    fps = nframes / (frames[-1] - frames[0])
                    logger.info("{:.1f}fps; execute {:.1f}ms, render {:.1f}ms, housekeep {:.1f}ms; perf {:.2f}",
                                fps, 1000 * execution / nframes, 1000 * render / nframes, 1000 * housekeeping / nframes, performance)
                    frames = frames[-1:]
                    execution = render = housekeeping = 0
        finally:
            SharedCache.clean(0)
            for renderers in self.renderers.values():
                while renderers:
                    renderers.pop().destroy()
            while self.controllers:
                self.controllers.pop().destroy()
            count = gc.collect(2)
            logger.trace("Collected {} objects (full collection)", count)
            gc.enable()
