"""
Flitter controller driver API
"""

import math

from loguru import logger

from ...model import Vector, Node


class Control:
    def __init__(self, control_id):
        self._initialised = False
        self.control_id = control_id
        self.reset()

    def reset(self):
        if self._initialised:
            logger.trace("De-initialised {}({!r})", self.__class__.__name__, self.control_id)
        self._initialised = False
        self._state_prefix = None
        self._name = None
        self._color = None

    def update(self, engine, node: Node, now: float):
        changed = False
        if (state_prefix := node.get('state')) != self._state_prefix:
            self._state_prefix = state_prefix
            changed = True
        if (name := node.get('name', 1, str)) != self._name:
            self._name = name
            changed = True
        if (color := node.get('color', 3, float)) != self._color:
            self._color = color
            changed = True
        if not self._initialised:
            logger.trace("Initialised {}({!r})", self.__class__.__name__, self.control_id)
        self._initialised = True
        return changed

    def update_representation(self):
        raise NotImplementedError()


class PositionControl(Control):
    DEFAULT_LAG = 1/4

    def reset(self):
        super().reset()
        self._lag = None
        self._lower = None
        self._upper = None
        self._raw_position = None
        self._position = None
        self._position_time = None

    def get_raw_divisor(self):
        raise NotImplementedError()

    def update(self, engine, node, now):
        changed = super().update(engine, node, now)
        if (lag := node.get('lag', 1, float, self.DEFAULT_LAG)) != self._lag:
            self._lag = lag
            changed = True
        if (lower := node.get('lower', 1, float, 0)) != self._lower:
            self._lower = lower
            changed = True
        if (upper := max(self._lower, node.get('upper', 1, float, 1))) != self._upper:
            self._upper = upper
            changed = True
        position_range = self._upper - self._lower
        if self._raw_position is not None:
            raw_divisor = self.get_raw_divisor()
            position = self._raw_position / raw_divisor * position_range + self._lower
            if self._position is not None and abs(position - self._position) > position_range / 1000:
                delta = engine.counter.beat_at_time(now) - engine.counter.beat_at_time(self._position_time)
                alpha = math.exp(-delta / self._lag) if self._lag > 0 else 0
                self._position = self._position * alpha + position * (1 - alpha)
                self._position_time = now
            elif self._position != position:
                self._position = position
                self._position_time = now
        if self._state_prefix and self._position is not None:
            engine.state[self._state_prefix] = self._position
        return changed


class EncoderControl(PositionControl):
    STYLES = {'volume', 'pan', 'continuous'}

    def reset(self):
        super().reset()
        self._style = None
        self._initial = None
        self._turns = None

    def update(self, engine, node, now):
        changed = super().update(engine, node, now)
        style = node.get('style', 1, str, 'volume').lower()
        if style not in self.STYLES:
            style = 'volume'
        if style != self._style:
            self._style = style
            changed = True
        position_range = self._upper - self._lower
        if (initial := node.get('initial', 1, float, self._lower + position_range / 2 if self._style == 'pan' else self._lower)) != self._initial:
            self._initial = initial
            changed = True
        if (turns := node.get('turns', 1, float, 1)) != self._turns:
            self._turns = turns
            changed = True
        if self._raw_position is None:
            if self._state_prefix and self._state_prefix in engine.state:
                initial = float(engine.state[self._state_prefix])
            else:
                initial = self._initial
            self._position = min(max(self._lower, initial), self._upper)
            self._position_time = now
            self._raw_position = (self._position - self._lower) / position_range * self.get_raw_divisor() if position_range else 0
            changed = True
        return changed

    def handle_turn(self, delta, timestamp):
        if not self._initialised or delta == 0:
            return
        raw_position = self._raw_position + delta
        if self._style != 'continuous':
            raw_position = min(max(0, raw_position), self.get_raw_divisor())
        if raw_position != self._raw_position:
            self._raw_position = raw_position
            self._position_time = timestamp
            self.update_representation()

    def handle_reset(self, timestamp):
        if not self._initialised:
            return
        position_range = self._upper - self._lower
        position = min(max(self._lower, self._initial), self._upper)
        self._raw_position = (position - self._lower) / position_range * self.get_raw_divisor() if position_range else 0
        self.update_representation()


class ButtonControl(Control):
    ToggleGroups = {}

    def reset(self):
        super().reset()
        self._pushed = None
        self._push_time = None
        self._release_time = None
        self._action = None
        self._action_can_trigger = None
        self._action_triggered = None
        self._toggle = None
        self._toggled = None
        self._toggle_time = None
        self._toggle_group = None

    def update(self, engine, node, now):
        changed = super().update(engine, node, now)
        action = node.get('action', 1, str)
        toggle = node.get('toggle', 1, bool, False)
        group = node.get('group')
        if group is not None:
            group = tuple(group)
        if action != self._action:
            self._action = action
            if self._action is None:
                self._action_can_trigger = None
                self._action_triggered = None
            changed = True
        if toggle != self._toggle:
            self._toggle = toggle
            self._toggled = None
            self._toggle_time = None
            changed = True
        if self._toggle and self._toggled is None:
            key = self._state_prefix + ['toggled'] if self._state_prefix else None
            if key and key in engine.state:
                self._toggled = bool(engine.state[key])
                toggled_beat = float(engine.state[key + ['beat']])
                self._toggle_time = engine.counter.time_at_beat(toggled_beat)
            else:
                self._toggled = node.get('initial', 1, bool, False)
                self._toggle_time = now
            changed = True
        if group != self._toggle_group:
            if self._toggle_group is not None:
                self.ToggleGroups[self._toggle_group].remove(self)
            self._toggle_group = group
            self.ToggleGroups.setdefault(self._toggle_group, set()).add(self)
            changed = True
        if self._state_prefix:
            engine.state[self._state_prefix] = self._pushed if not self._toggle else self._toggled
            engine.state[self._state_prefix + ['pushed']] = self._pushed
            engine.state[self._state_prefix + ['released']] = not self._pushed if self._pushed is not None else None
            engine.state[self._state_prefix + ['pushed', 'beat']] = \
                engine.counter.beat_at_time(self._push_time) if self._push_time is not None else None
            engine.state[self._state_prefix + ['released', 'beat']] = \
                engine.counter.beat_at_time(self._release_time) if self._release_time is not None else None
            engine.state[self._state_prefix + ['toggled']] = self._toggled if self._toggle else None
            engine.state[self._state_prefix + ['toggled', 'beat']] = \
                engine.counter.beat_at_time(self._toggle_time) if self._toggle_time is not None else None
        if self._action is not None:
            match self._action:
                case 'next':
                    self._action_can_trigger = engine.has_next_page()
                case 'previous':
                    self._action_can_trigger = engine.has_previous_page()
            if self._action_triggered:
                match self._action:
                    case 'next':
                        engine.next_page()
                    case 'previous':
                        engine.previous_page()
                self._action_triggered = False
        return changed

    def handle_push(self, pushed, timestamp):
        if not self._initialised or pushed == self._pushed:
            return
        self._pushed = pushed
        if self._pushed:
            self._push_time = timestamp
            if self._action is not None:
                self._action_triggered = True
            elif self._toggle:
                self._toggled = not self._toggled
                self._toggle_time = timestamp
                if self._toggle_group is not None and self._toggled:
                    for button in self.ToggleGroups[self._group]:
                        if button is not self and button._toggle and button._toggled:
                            button._toggled = False
                            button._toggle_time = timestamp
                            self.update_representation()
        else:
            self._release_time = timestamp
        self.update_representation()


class ControllerDriver:
    def __init__(self, node: Node):
        pass

    @property
    def is_ready(self):
        raise NotImplementedError()

    async def start(self):
        raise NotImplementedError()

    def stop(self):
        raise NotImplementedError()

    def get_control(self, kind: str, control_id: Vector) -> Control:
        pass
