# cython: language_level=3, profile=False, boundscheck=False, wraparound=False, cdivision=True

"""
Flitter physics engine
"""

import asyncio
from loguru import logger

from .. import name_patch
from ..model cimport Vector, Node, StateDict, null_
from ..language.functions cimport Normal

from libc.math cimport sqrt, isinf, isnan, abs
from cpython cimport PyObject
from cpython.dict cimport PyDict_GetItem

cdef extern from "Python.h":
    # Note: I am explicitly (re)defining these as not requiring the GIL for speed.
    # This appears to work completely fine, but is obviously making assumptions
    # on the Python ABI that may not be correct.
    #
    Py_ssize_t PyList_GET_SIZE(object list) nogil
    PyObject* PyList_GET_ITEM(object list, Py_ssize_t i) nogil

logger = name_patch(logger, __name__)

cdef Vector VELOCITY = Vector('velocity')
cdef Vector CLOCK = Vector('clock')

cdef Normal RandomSource = Normal('_physics')
cdef unsigned long long RandomIndex = 0


cdef class Particle:
    cdef Vector id
    cdef Vector position_state_key
    cdef Vector position
    cdef Vector velocity_state_key
    cdef Vector velocity
    cdef Vector initial_force
    cdef Vector force
    cdef double radius
    cdef double mass
    cdef double charge
    cdef double ease

    def __cinit__(self, Node node, Vector id, Vector zero, Vector prefix, StateDict state):
        self.id = id
        self.position_state_key = prefix.concat(self.id).intern()
        cdef Vector position = state.get_item(self.position_state_key)
        if position.length == zero.length and position.numbers != NULL:
            self.position = Vector._copy(position)
        else:
            self.position = Vector._copy(node.get_fvec('position', zero.length, zero))
        self.velocity_state_key = self.position_state_key.concat(VELOCITY).intern()
        cdef Vector velocity = state.get_item(self.velocity_state_key)
        if velocity.length == zero.length and velocity.numbers != NULL:
            self.velocity = Vector._copy(velocity)
        else:
            self.velocity = Vector._copy(node.get_fvec('velocity', zero.length, zero))
        self.initial_force = node.get_fvec('force', zero.length, zero)
        self.force = Vector._copy(self.initial_force)
        self.radius = max(0, node.get_float('radius', 1))
        self.mass = max(0, node.get_float('mass', 1))
        self.charge = node.get_float('charge', 1)
        self.ease = node.get_float('ease', 0)

    cdef void update(self, double speed_of_light, double clock, double delta) noexcept nogil:
        cdef double speed, d, k
        cdef long i, n=self.force.length
        if self.mass:
            for i in range(n):
                if isinf(self.force.numbers[i]) or isnan(self.force.numbers[i]):
                    break
            else:
                k = delta / self.mass
                if self.ease > 0 and clock < self.ease:
                    k *= clock / self.ease
                speed = 0
                for i in range(n):
                    d = self.velocity.numbers[i] + self.force.numbers[i] * k
                    self.velocity.numbers[i] = d
                    speed += d * d
                if speed > speed_of_light * speed_of_light:
                    k = speed_of_light / sqrt(speed)
                    for i in range(n):
                        self.velocity.numbers[i] = self.velocity.numbers[i] * k
        for i in range(n):
            self.position.numbers[i] = self.position.numbers[i] + self.velocity.numbers[i] * delta
            self.force.numbers[i] = self.initial_force.numbers[i]


cdef class Anchor(Particle):
    def __cinit__(self, Node node, Vector id, Vector zero, Vector prefix, StateDict state):
        self.position = node.get_fvec('position', zero.length, zero)
        self.velocity = Vector._copy(zero)

    cdef void update(self, double speed_of_light, double clock, double delta) noexcept nogil:
        pass

cdef class ForceApplier:
    cdef double strength

    def __cinit__(self, Node node, double strength, Vector zero):
        self.strength = strength


cdef class PairForceApplier(ForceApplier):
    cdef void apply(self, Particle from_particle, Particle to_particle, Vector direction, double distance, double distance_squared) noexcept nogil:
        raise NotImplementedError()


cdef class ParticleForceApplier(ForceApplier):
    cdef void apply(self, Particle particle, double delta) noexcept nogil:
        raise NotImplementedError()


cdef class MatrixPairForceApplier(PairForceApplier):
    cdef double max_distance

    def __cinit__(self, Node node, double strength, Vector zero):
        self.max_distance = max(0, node.get_float('max_distance', 0))


cdef class SpecificPairForceApplier(PairForceApplier):
    cdef Vector from_particle_id
    cdef Vector to_particle_id
    cdef long from_index
    cdef long to_index

    def __cinit__(self, Node node, double strength, Vector zero):
        self.from_particle_id = <Vector>node._attributes.get('from')
        self.to_particle_id = <Vector>node._attributes.get('to')


cdef class DistanceForceApplier(SpecificPairForceApplier):
    cdef double minimum
    cdef double maximum

    def __cinit__(self, Node node, double strength, Vector zero):
        cdef double fixed
        if (fixed := node.get_float('fixed', 0)) != 0:
            self.minimum = fixed
            self.maximum = fixed
        else:
            self.minimum = node.get_float('min', 0)
            self.maximum = node.get_float('max', 0)

    cdef void apply(self, Particle from_particle, Particle to_particle, Vector direction, double distance, double distance_squared) noexcept nogil:
        cdef double f, k
        cdef long i
        if self.minimum and distance < self.minimum:
            k = self.strength * (self.minimum - distance)
            for i in range(direction.length):
                f = direction.numbers[i] * k
                from_particle.force.numbers[i] = from_particle.force.numbers[i] - f
                to_particle.force.numbers[i] = to_particle.force.numbers[i] + f
        elif self.maximum and distance > self.maximum:
            k = self.strength * (distance - self.maximum)
            for i in range(direction.length):
                f = direction.numbers[i] * k
                from_particle.force.numbers[i] = from_particle.force.numbers[i] + f
                to_particle.force.numbers[i] = to_particle.force.numbers[i] - f


cdef class DragForceApplier(ParticleForceApplier):
    cdef void apply(self, Particle particle, double delta) noexcept nogil:
        cdef double speed_squared=0, v, k
        cdef long i
        if particle.radius:
            for i in range(particle.velocity.length):
                v = particle.velocity.numbers[i]
                speed_squared += v * v
            k = min(self.strength * sqrt(speed_squared) * (particle.radius * particle.radius), particle.mass / delta)
            for i in range(particle.velocity.length):
                particle.force.numbers[i] = particle.force.numbers[i] - particle.velocity.numbers[i] * k


cdef class ConstantForceApplier(ParticleForceApplier):
    cdef Vector force

    def __cinit__(self, Node node, double strength, Vector zero):
        cdef Vector force
        cdef long i
        force = node.get_fvec('force', zero.length, null_)
        if force.length == 0:
            force = node.get_fvec('direction', zero.length, zero).normalize()
            for i in range(force.length):
                force.numbers[i] = force.numbers[i] * self.strength
        self.force = force

    cdef void apply(self, Particle particle, double delta) noexcept nogil:
        cdef long i
        for i in range(self.force.length):
            particle.force.numbers[i] = particle.force.numbers[i] + self.force.numbers[i]


cdef class RandomForceApplier(ParticleForceApplier):
    cdef void apply(self, Particle particle, double delta) noexcept nogil:
        global RandomIndex
        cdef long i
        for i in range(particle.force.length):
            particle.force.numbers[i] = particle.force.numbers[i] + self.strength * RandomSource._item(RandomIndex)
            RandomIndex += 1


cdef class CollisionForceApplier(MatrixPairForceApplier):
    cdef void apply(self, Particle from_particle, Particle to_particle, Vector direction, double distance, double distance_squared) noexcept nogil:
        cdef double min_distance, f, k
        cdef long i
        if from_particle.radius and to_particle.radius:
            min_distance = from_particle.radius + to_particle.radius
            if distance < min_distance:
                k = self.strength * (min_distance - distance)
                for i in range(direction.length):
                    f = direction.numbers[i] * k
                    from_particle.force.numbers[i] = from_particle.force.numbers[i] - f
                    to_particle.force.numbers[i] = to_particle.force.numbers[i] + f


cdef class GravityForceApplier(MatrixPairForceApplier):
    cdef void apply(self, Particle from_particle, Particle to_particle, Vector direction, double distance, double distance_squared) noexcept nogil:
        cdef double f, k
        cdef long i
        if from_particle.mass and to_particle.mass:
            k = self.strength * from_particle.mass * to_particle.mass / distance_squared
            for i in range(direction.length):
                f = direction.numbers[i] * k
                from_particle.force.numbers[i] = from_particle.force.numbers[i] + f
                to_particle.force.numbers[i] = to_particle.force.numbers[i] - f


cdef class ElectrostaticForceApplier(MatrixPairForceApplier):
    cdef void apply(self, Particle from_particle, Particle to_particle, Vector direction, double distance, double distance_squared) noexcept nogil:
        cdef double f, k
        cdef long i
        if from_particle.charge and to_particle.charge:
            k = self.strength * -from_particle.charge * to_particle.charge / distance_squared
            for i in range(direction.length):
                f = direction.numbers[i] * k
                from_particle.force.numbers[i] = from_particle.force.numbers[i] + f
                to_particle.force.numbers[i] = to_particle.force.numbers[i] - f


cdef class PhysicsSystem:
    def destroy(self):
        pass

    def purge(self):
        pass

    async def update(self, engine, Node node, double clock, **kwargs):
        cdef long dimensions = node.get_int('dimensions', 0)
        if dimensions < 1:
            return
        cdef Vector state_prefix = <Vector>node._attributes.get('state')
        if state_prefix is None:
            return
        cdef double time = node.get_float('time', clock)
        cdef double resolution = node.get_float('resolution', 1/engine.target_fps)
        if resolution <= 0:
            return
        cdef double speed_of_light = node.get_float('speed_of_light', 1e9)
        if speed_of_light <= 0:
            return
        cdef StateDict state = engine.state
        cdef Vector time_vector = state.get_item(state_prefix.concat(CLOCK))
        if time_vector.length == 1 and time_vector.numbers != NULL:
            clock = time_vector.numbers[0]
        else:
            clock = 0
        cdef Vector zero = Vector.__new__(Vector)
        zero.allocate_numbers(dimensions)
        cdef long i
        for i in range(dimensions):
            zero.numbers[i] = 0
        cdef list particles=[], particle_forces=[], matrix_forces=[], specific_forces=[]
        cdef Node child = node.first_child
        cdef Vector id
        cdef double strength, ease
        cdef dict particles_by_id = {}
        cdef Particle particle
        while child is not None:
            if child.kind == 'particle':
                id = <Vector>child._attributes.get('id')
                if id is not None:
                    particle = Particle.__new__(Particle, child, id, zero, state_prefix, state)
                    particles_by_id[id] = len(particles)
                    particles.append(particle)
            elif child.kind == 'anchor':
                id = <Vector>child._attributes.get('id')
                if id is not None:
                    particle = Anchor.__new__(Anchor, child, id, zero, state_prefix, state)
                    particles_by_id[id] = len(particles)
                    particles.append(particle)
            else:
                strength = child.get_float('strength', 1)
                ease = child.get_float('ease', 0)
                if ease > 0 and ease < clock:
                    strength *= clock/ease;
                if child.kind == 'distance':
                    specific_forces.append(DistanceForceApplier.__new__(DistanceForceApplier, child, strength, zero))
                elif child.kind == 'drag':
                    particle_forces.append(DragForceApplier.__new__(DragForceApplier, child, strength, zero))
                elif child.kind == 'constant':
                    particle_forces.append(ConstantForceApplier.__new__(ConstantForceApplier, child, strength, zero))
                elif child.kind == 'random':
                    particle_forces.append(RandomForceApplier.__new__(RandomForceApplier, child, strength, zero))
                elif child.kind == 'collision':
                    matrix_forces.append(CollisionForceApplier.__new__(CollisionForceApplier, child, strength, zero))
                elif child.kind == 'gravity':
                    matrix_forces.append(GravityForceApplier.__new__(GravityForceApplier, child, strength, zero))
                elif child.kind == 'electrostatic':
                    matrix_forces.append(ElectrostaticForceApplier.__new__(ElectrostaticForceApplier, child, strength, zero))
            child = child.next_sibling
        cdef SpecificPairForceApplier specific_force
        for specific_force in specific_forces:
            specific_force.from_index = particles_by_id.get(specific_force.from_particle_id, -1)
            specific_force.to_index = particles_by_id.get(specific_force.to_particle_id, -1)
        cdef double last_time
        time_vector = state.get_item(state_prefix)
        if time_vector.length == 1 and time_vector.numbers != NULL:
            last_time = min(time, time_vector.numbers[0])
        else:
            logger.debug("New physics {!r} with {} particles and {} forces", state_prefix, len(particles),
                         len(particle_forces) + len(matrix_forces) + len(specific_forces))
            last_time = time
        clock = await asyncio.to_thread(self.calculate, particles, particle_forces, matrix_forces, specific_forces,
                                        dimensions, engine.realtime, speed_of_light, time, last_time, resolution, clock)
        for particle in particles:
            state.set_item(particle.position_state_key, particle.position)
            state.set_item(particle.velocity_state_key, particle.velocity)
        time_vector = Vector.__new__(Vector)
        time_vector.allocate_numbers(1)
        time_vector.numbers[0] = time
        state.set_item(state_prefix, time_vector)
        time_vector = Vector.__new__(Vector)
        time_vector.allocate_numbers(1)
        time_vector.numbers[0] = clock
        state.set_item(state_prefix.concat(CLOCK), time_vector)

    cdef double calculate(self, list particles, list particle_forces, list matrix_forces, list specific_forces,
                          int dimensions, bint realtime, double speed_of_light,
                          double time, double last_time, double resolution, double clock):
        cdef long i, j, k, m, n=len(particles)
        cdef double delta
        cdef Vector direction = Vector.__new__(Vector)
        direction.allocate_numbers(dimensions)
        cdef double d, distance, distance_squared
        cdef PyObject* from_index
        cdef PyObject* to_index
        cdef PyObject* from_particle
        cdef PyObject* to_particle
        cdef PyObject* force
        with nogil:
            while True:
                delta = min(resolution, time-last_time)
                m = PyList_GET_SIZE(particle_forces)
                for i in range(m):
                    for j in range(n):
                        (<ParticleForceApplier>PyList_GET_ITEM(particle_forces, i)).apply((<Particle>PyList_GET_ITEM(particles, j)), delta)
                m = PyList_GET_SIZE(specific_forces)
                for i in range(m):
                    force = PyList_GET_ITEM(specific_forces, i)
                    if (<SpecificPairForceApplier>force).from_index != -1 and (<SpecificPairForceApplier>force).to_index != -1:
                        from_particle = PyList_GET_ITEM(particles, (<SpecificPairForceApplier>force).from_index)
                        to_particle = PyList_GET_ITEM(particles, (<SpecificPairForceApplier>force).to_index)
                        distance_squared = 0
                        for k in range(dimensions):
                            d = (<Particle>to_particle).position.numbers[k] - (<Particle>from_particle).position.numbers[k]
                            direction.numbers[k] = d
                            distance_squared += d * d
                        distance = sqrt(distance_squared)
                        for k in range(dimensions):
                            direction.numbers[k] /= distance
                        (<SpecificPairForceApplier>force).apply(<Particle>from_particle, <Particle>to_particle, direction, distance, distance_squared)
                m = PyList_GET_SIZE(matrix_forces)
                if m:
                    for i in range(1, n):
                        from_particle = PyList_GET_ITEM(particles, i)
                        for j in range(i):
                            to_particle = PyList_GET_ITEM(particles, j)
                            distance_squared = 0
                            for k in range(dimensions):
                                d = (<Particle>to_particle).position.numbers[k] - (<Particle>from_particle).position.numbers[k]
                                direction.numbers[k] = d
                                distance_squared += d * d
                            distance = sqrt(distance_squared)
                            for k in range(dimensions):
                                direction.numbers[k] /= distance
                            for k in range(m):
                                force = PyList_GET_ITEM(matrix_forces, k)
                                if not (<MatrixPairForceApplier>force).max_distance or \
                                        distance < (<MatrixPairForceApplier>force).max_distance:
                                    (<MatrixPairForceApplier>force).apply(<Particle>from_particle, <Particle>to_particle,
                                                                          direction, distance, distance_squared)
                for i in range(n):
                    (<Particle>PyList_GET_ITEM(particles, i)).update(speed_of_light, clock, delta)
                last_time += delta
                clock += delta
                if realtime or last_time >= time:
                    break
        return clock


RENDERER_CLASS = PhysicsSystem