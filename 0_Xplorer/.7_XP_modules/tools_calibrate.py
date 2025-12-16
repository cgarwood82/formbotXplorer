
# Nozzle alignment module for 3d kinematic probes.
#
# This module has been adapted from code written by Kevin O'Connor <kevin@koconnor.net> and Martin Hierholzer <martin@hierholzer.info>
# Sourced from https://github.com/ben5459/Klipper_ToolChanger/blob/master/probe_multi_axis.py

import logging

direction_types = {
    'x+': [0, +1], 'x-': [0, -1],
    'y+': [1, +1], 'y-': [1, -1],
    'z+': [2, +1], 'z-': [2, -1]
}

HINT_TIMEOUT = """
If the probe did not move far enough to trigger, then
consider reducing/increasing the axis minimum/maximum
position so the probe can travel further (the minimum
position can be negative).
"""


class ToolsCalibrate:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.name = config.get_name()

        self.gcode_move = self.printer.load_object(config, "gcode_move")
        self.gcode = self.printer.lookup_object('gcode')

        self.probe_multi_axis = PrinterProbeMultiAxis(
            config,
            ProbeEndstopWrapper(config, 'x'),
            ProbeEndstopWrapper(config, 'y'),
            ProbeEndstopWrapper(config, 'z')
        )

        self.probe_name = config.get('probe', 'probe')
        self.travel_speed = config.getfloat('travel_speed', 10.0, above=0.)
        self.spread = config.getfloat('spread', 5.0)
        self.lower_z = config.getfloat('lower_z', 0.5)
        self.lift_z = config.getfloat('lift_z', 1.0)
        self.trigger_to_bottom_z = config.getfloat('trigger_to_bottom_z', default=0.0)
        self.lift_speed = config.getfloat('lift_speed', self.probe_multi_axis.lift_speed)
        self.final_lift_z = config.getfloat('final_lift_z', 4.0)

        self.sensor_location = None
        self.last_result = None
        self.last_probe_offset = 0.0
        self.calibration_probe_triggered = False

        self.gcode.register_command('TOOL_LOCATE_SENSOR',
                                    self.cmd_TOOL_LOCATE_SENSOR,
                                    desc="Locate the tool calibration sensor, use with tool 0.")
        self.gcode.register_command('TOOL_CALIBRATE_TOOL_OFFSET',
                                    self.cmd_TOOL_CALIBRATE_TOOL_OFFSET,
                                    desc="Calibrate current tool offset relative to tool 0")
        self.gcode.register_command('TOOL_CALIBRATE_SAVE_TOOL_OFFSET',
                                    self.cmd_TOOL_CALIBRATE_SAVE_TOOL_OFFSET,
                                    desc="Save tool offset calibration to config")
        self.gcode.register_command('TOOL_CALIBRATE_PROBE_OFFSET',
                                    self.cmd_TOOL_CALIBRATE_PROBE_OFFSET,
                                    desc="Calibrate the tool probe offset to nozzle tip")
        self.gcode.register_command('TOOL_CALIBRATE_QUERY_PROBE',
                                    self.cmd_TOOL_CALIBRATE_QUERY_PROBE,
                                    desc="Return the state of calibration probe")

    def probe_xy(self, toolhead, top_pos, direction, gcmd, samples=None):
        offset = direction_types[direction]
        start_pos = list(top_pos)
        start_pos[offset[0]] -= offset[1] * self.spread

        toolhead.manual_move([None, None, top_pos[2] + self.lift_z], self.lift_speed)
        toolhead.manual_move([start_pos[0], start_pos[1], None], self.travel_speed)
        toolhead.manual_move([None, None, top_pos[2] - self.lower_z], self.lift_speed)

        res = self.probe_multi_axis.run_probe(
            direction, gcmd, samples=samples,
            max_distance=self.spread * 1.8
        )
        return res[offset[0]]

    def calibrate_xy(self, toolhead, top_pos, gcmd, samples=None):
        left_x = self.probe_xy(toolhead, top_pos, 'x+', gcmd, samples=samples)
        right_x = self.probe_xy(toolhead, top_pos, 'x-', gcmd, samples=samples)
        near_y = self.probe_xy(toolhead, top_pos, 'y+', gcmd, samples=samples)
        far_y = self.probe_xy(toolhead, top_pos, 'y-', gcmd, samples=samples)
        return [(left_x + right_x) / 2., (near_y + far_y) / 2.]

    def locate_sensor(self, gcmd):
        toolhead = self.printer.lookup_object('toolhead')
        position = list(toolhead.get_position())

        downPos = self.probe_multi_axis.run_probe("z-", gcmd, samples=1)
        center_x, center_y = self.calibrate_xy(toolhead, downPos, gcmd, samples=1)

        toolhead.manual_move([None, None, downPos[2] + self.lift_z], self.lift_speed)
        toolhead.manual_move([center_x, center_y, None], self.travel_speed)
        center_z = self.probe_multi_axis.run_probe("z-", gcmd, speed_ratio=0.5)[2]

        center_x, center_y = self.calibrate_xy(toolhead, [center_x, center_y, center_z], gcmd)

        position[0] = center_x
        position[1] = center_y
        position[2] = center_z + self.final_lift_z

        toolhead.manual_move([None, None, position[2]], self.lift_speed)
        toolhead.manual_move([position[0], position[1], None], self.travel_speed)
        toolhead.set_position(position)
        return [center_x, center_y, center_z]

    def cmd_TOOL_LOCATE_SENSOR(self, gcmd):
        self.last_result = self.locate_sensor(gcmd)
        self.sensor_location = self.last_result
        self.gcode.respond_info("Sensor location at %.6f,%.6f,%.6f"
                                % (self.last_result[0], self.last_result[1], self.last_result[2]))

    def cmd_TOOL_CALIBRATE_TOOL_OFFSET(self, gcmd):
        if not self.sensor_location:
            raise gcmd.error("No recorded sensor location, please run TOOL_LOCATE_SENSOR first")
        location = self.locate_sensor(gcmd)
        self.last_result = [location[i] - self.sensor_location[i] for i in range(3)]
        self.gcode.respond_info("Tool offset is %.6f,%.6f,%.6f"
                                % (self.last_result[0], self.last_result[1], self.last_result[2]))

    def cmd_TOOL_CALIBRATE_SAVE_TOOL_OFFSET(self, gcmd):
        if self.last_result is None:
            raise gcmd.error("No offset result, please run TOOL_CALIBRATE_TOOL_OFFSET first")
        section_name = gcmd.get("SECTION")
        param_name = gcmd.get("ATTRIBUTE")
        template = gcmd.get("VALUE", "{x:0.6f}, {y:0.6f}, {z:0.6f}")
        value = template.format(x=self.last_result[0], y=self.last_result[1], z=self.last_result[2])
        configfile = self.printer.lookup_object('configfile')
        configfile.set(section_name, param_name, value)

    def cmd_TOOL_CALIBRATE_PROBE_OFFSET(self, gcmd):
        toolhead = self.printer.lookup_object('toolhead')
        probe = self.printer.lookup_object(self.probe_name)
        start_pos = list(toolhead.get_position())

        nozzle_z = self.probe_multi_axis.run_probe("z-", gcmd, speed_ratio=0.5)[2]

        probe_session = probe.start_probe_session(gcmd)
        probe_session.run_probe(gcmd)
        probe_z = probe_session.pull_probed_results()[0][2]
        probe_session.end_probe_session()

        z_offset = probe_z - nozzle_z + self.trigger_to_bottom_z
        self.last_probe_offset = z_offset

        self.gcode.respond_info(
            "%s: z_offset: %.3f\n"
            "The SAVE_CONFIG command will update the printer config file\n"
            "with the above and restart the printer." % (self.probe_name, z_offset)
        )

        config_name = gcmd.get("PROBE", default=self.probe_name)
        if config_name:
            configfile = self.printer.lookup_object('configfile')
            configfile.set(config_name, 'z_offset', "%.6f" % (z_offset,))

        toolhead.move(start_pos, self.travel_speed)
        toolhead.set_position(start_pos)

    def cmd_TOOL_CALIBRATE_QUERY_PROBE(self, gcmd):
        toolhead = self.printer.lookup_object('toolhead')
        print_time = toolhead.get_last_move_time()
        states = [p.query_endstop(print_time) for p in self.probe_multi_axis.mcu_probe]
        trig = any(states)
        self.calibration_probe_triggered = trig
        gcmd.respond_info("Calibration Probe: %s" % (["open", "TRIGGERED"][trig]))

    def get_status(self, eventtime):
        lr = self.last_result if self.last_result is not None else [0.0, 0.0, 0.0]
        return {
            'last_result': lr,
            'last_probe_offset': self.last_probe_offset,
            'calibration_probe_triggered': self.calibration_probe_triggered,
            'last_x_result': lr[0],
            'last_y_result': lr[1],
            'last_z_result': lr[2],
        }


class PrinterProbeMultiAxis:
    def __init__(self, config, mcu_probe_x, mcu_probe_y, mcu_probe_z):
        self.printer = config.get_printer()
        self.name = config.get_name()
        self.mcu_probe = [mcu_probe_x, mcu_probe_y, mcu_probe_z]

        self.speed = config.getfloat('speed', 5.0, above=0.)
        self.lift_speed = config.getfloat('lift_speed', self.speed, above=0.)

        self.sample_count = config.getint('samples', 1, minval=1)
        self.sample_retract_dist = config.getfloat('sample_retract_dist', 2., above=0.)
        atypes = {'median': 'median', 'average': 'average'}
        self.samples_result = config.getchoice('samples_result', atypes, 'average')
        self.samples_tolerance = config.getfloat('samples_tolerance', 0.100, minval=0.)
        self.samples_retries = config.getint('samples_tolerance_retries', 0, minval=0)

        self.gcode = self.printer.lookup_object('gcode')
        self.gcode_move = self.printer.load_object(config, "gcode_move")

        self.printer.lookup_object('pins').register_chip('probe_multi_axis', self)

    def setup_pin(self, pin_type, pin_params):
        if pin_type != 'endstop' or pin_params['pin'] != 'xy_virtual_endstop':
            raise self.printer.lookup_object('pins').error("Probe virtual endstop only useful as endstop pin")
        if pin_params.get('invert') or pin_params.get('pullup'):
            raise self.printer.lookup_object('pins').error("Can not pullup/invert probe virtual endstop")
        return self.mcu_probe

    def get_lift_speed(self, gcmd=None):
        if gcmd is not None:
            return gcmd.get_float("LIFT_SPEED", self.lift_speed, above=0.)
        return self.lift_speed

    def _get_target_position(self, axis, sense, max_distance):
        toolhead = self.printer.lookup_object('toolhead')
        curtime = self.printer.get_reactor().monotonic()

        homed = toolhead.get_status(curtime).get('homed_axes', '')
        if 'x' not in homed or 'y' not in homed or 'z' not in homed:
            raise self.printer.command_error("Must home before probe")

        pos = list(toolhead.get_position())
        kin_status = toolhead.get_kinematics().get_status(curtime)
        if 'axis_minimum' not in kin_status or 'axis_maximum' not in kin_status:
            raise self.gcode.error("Tools calibrate only works with cartesian-like kinematics")

        if sense > 0:
            pos[axis] = min(pos[axis] + max_distance, kin_status['axis_maximum'][axis])
        else:
            pos[axis] = max(pos[axis] - max_distance, kin_status['axis_minimum'][axis])

        return pos

    def _probe(self, speed, axis, sense, max_distance, direction_label):
        phoming = self.printer.lookup_object('homing')
        toolhead = self.printer.lookup_object('toolhead')

        try:
            pre = self.mcu_probe[axis].query_endstop(toolhead.get_last_move_time())
        except Exception:
            pre = None

        self.gcode.respond_info(
            "DEBUG probe begin dir=%s axis=%d sense=%d pre_endstop=%s"
            % (direction_label, axis, sense, str(pre))
        )

        pos = self._get_target_position(axis, sense, max_distance)

        try:
            epos = phoming.probing_move(self.mcu_probe[axis], pos, speed)
        except self.printer.command_error as e:
            reason = str(e)
            if "Timeout during endstop homing" in reason:
                reason += HINT_TIMEOUT
            raise self.printer.command_error(reason)

        self.gcode.respond_info("Probe made contact at %.6f,%.6f,%.6f"
                                % (epos[0], epos[1], epos[2]))
        return epos[:3]

    def _calc_mean(self, positions):
        count = float(len(positions))
        return [sum([p[i] for p in positions]) / count for i in range(3)]

    def _calc_median(self, positions, axis):
        axis_sorted = sorted(positions, key=(lambda p: p[axis]))
        middle = len(positions) // 2
        if (len(positions) & 1) == 1:
            return axis_sorted[middle]
        return self._calc_mean(axis_sorted[middle - 1:middle + 1])

    def run_probe(self, direction, gcmd, speed_ratio=1.0, samples=None, max_distance=100.0):
        speed = gcmd.get_float("PROBE_SPEED", self.speed, above=0.) * speed_ratio
        if direction not in direction_types:
            raise self.printer.command_error("Wrong value for DIRECTION.")

        (axis, sense) = direction_types[direction]

        sample_count = gcmd.get_int("SAMPLES", samples if samples else self.sample_count, minval=1)
        samples_tolerance = gcmd.get_float("SAMPLES_TOLERANCE", self.samples_tolerance, minval=0.)
        samples_retries = gcmd.get_int("SAMPLES_TOLERANCE_RETRIES", self.samples_retries, minval=0)
        samples_result = gcmd.get("SAMPLES_RESULT", self.samples_result)

        retries = 0
        positions = []

        while len(positions) < sample_count:
            pos = self._probe(speed, axis, sense, max_distance, direction)
            positions.append(pos)

            axis_positions = [p[axis] for p in positions]
            if max(axis_positions) - min(axis_positions) > samples_tolerance:
                if retries >= samples_retries:
                    raise gcmd.error("Probe samples exceed samples_tolerance")
                gcmd.respond_info("Probe samples exceed tolerance. Retrying...")
                retries += 1
                positions = []
                continue

        if samples_result == 'median':
            return self._calc_median(positions, axis)
        return self._calc_mean(positions)


class ProbeEndstopWrapper:
    def __init__(self, config, axis):
        self.printer = config.get_printer()
        self.axis = axis

        ppins = self.printer.lookup_object('pins')
        pin = config.get('pin')
        ppins.allow_multi_use_pin(pin.replace('^', '').replace('!', ''))
        pin_params = ppins.lookup_pin(pin, can_invert=True, can_pullup=True)
        mcu = pin_params['chip']
        self.mcu_endstop = mcu.setup_pin('endstop', pin_params)

        self.printer.register_event_handler('klippy:mcu_identify', self._handle_mcu_identify)

        self.get_mcu = self.mcu_endstop.get_mcu
        self.add_stepper = self.mcu_endstop.add_stepper
        self.get_steppers = self._get_steppers
        self.home_start = self.mcu_endstop.home_start
        self.home_wait = self.mcu_endstop.home_wait
        self.query_endstop = self.mcu_endstop.query_endstop

    def _active_extruder_name(self):
        toolhead = self.printer.lookup_object('toolhead')
        try:
            return toolhead.get_extruder().get_name()
        except Exception:
            curtime = self.printer.get_reactor().monotonic()
            return toolhead.get_status(curtime).get('extruder')

    def _get_steppers(self):
        if self.axis == 'x':
            extr = self._active_extruder_name()
            want = {
                'extruder':  'stepper x',
                'extruder1': 'stepper x1',
                'extruder2': 'stepper x2',
                'extruder3': 'stepper x3',
            }.get(extr)

            toolhead = self.printer.lookup_object('toolhead')
            kin = toolhead.get_kinematics()

            all_names = []
            for s in kin.get_steppers():
                try:
                    all_names.append(s.get_name())
                except Exception:
                    all_names.append(str(s))

            if want is None:
                st = self.mcu_endstop.get_steppers()
                chosen = [s.get_name() for s in st]
                self.printer.lookup_object('gcode').respond_info(
                    f"DEBUG get_steppers axis=x extr={extr} want=None fallback={chosen} all={all_names}"
                )
                return st

            chosen = []
            for s in kin.get_steppers():
                try:
                    nm = s.get_name()
                except Exception:
                    continue
                if nm == want:
                    chosen.append(s)

            if not chosen:
                raise self.printer.command_error(
                    f"tools_calibrate: active extruder={extr} expected '{want}' but couldn't find it. "
                    f"Available steppers: {all_names}"
                )

            self.printer.lookup_object('gcode').respond_info(
                f"DEBUG get_steppers axis=x extr={extr} chosen={[s.get_name() for s in chosen]} all={all_names}"
            )
            return chosen

        st = self.mcu_endstop.get_steppers()
        try:
            chosen = [s.get_name() for s in st]
        except Exception:
            chosen = [str(s) for s in st]
        self.printer.lookup_object('gcode').respond_info(
            f"DEBUG get_steppers axis={self.axis} chosen={chosen}"
        )
        return st

    def _handle_mcu_identify(self):
        kin = self.printer.lookup_object('toolhead').get_kinematics()
        for stepper in kin.get_steppers():
            if stepper.is_active_axis(self.axis):
                self.add_stepper(stepper)

    def get_position_endstop(self):
        return 0.


def load_config(config):
    return ToolsCalibrate(config)
