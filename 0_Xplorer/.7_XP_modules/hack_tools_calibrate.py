"""
Hack copy of tools_calibrate.py adapted for IQEX/IDEX style motion.

Key changes vs original:
- Replace pins.error raises with standard Klipper gcode/command errors.
- All motion is routed via macros instead of direct toolhead.manual_move to
  allow the printer's macros to select the correct carriage and PRIMARY mode.

How to use (recommended):
- Provide macros ENTER_CAL_MODE, LEAVE_CAL_MODE, and CAL_SAFE_MOVE in your
  Klipper config. See hack_Calibration_offsets_idex.cfg for examples.
- In [tools_calibrate] section, you may optionally configure:
    move_via_macros: True/False (default True)
    macro_move: CAL_SAFE_MOVE
    macro_enter: ENTER_CAL_MODE
    macro_leave: LEAVE_CAL_MODE

This module keeps the same public commands as the original so your existing
macros can call TOOL_LOCATE_SENSOR, TOOL_CALIBRATE_TOOL_OFFSET, etc.
"""

import logging

direction_types = {'x+': [0, +1], 'x-': [0, -1], 'y+': [1, +1], 'y-': [1, -1],
                   'z+': [2, +1], 'z-': [2, -1]}

HINT_TIMEOUT = (
    "If the probe did not move far enough to trigger, then\n"
    "consider reducing/increasing the axis minimum/maximum\n"
    "position so the probe can travel further (the minimum\n"
    "position can be negative).\n"
)


class ToolsCalibrate:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.name = config.get_name()
        self.gcode_move = self.printer.load_object(config, "gcode_move")
        self.gcode = self.printer.lookup_object('gcode')

        # Motion macro integration
        self.move_via_macros = config.getboolean('move_via_macros', True)
        self.macro_move = config.get('macro_move', 'CAL_SAFE_MOVE')
        self.macro_enter = config.get('macro_enter', 'ENTER_CAL_MODE')
        self.macro_leave = config.get('macro_leave', 'LEAVE_CAL_MODE')

        # Probe wrapper (same as original but with patched error type)
        self.probe_multi_axis = PrinterProbeMultiAxis(
            config,
            ProbeEndstopWrapper(config, 'x'),
            ProbeEndstopWrapper(config, 'y'),
            ProbeEndstopWrapper(config, 'z'),
            move_via_macros=self.move_via_macros,
            macro_move=self.macro_move,
        )

        self.probe_name = config.get('probe', 'probe')
        self.travel_speed = config.getfloat('travel_speed', 10.0, above=0.)
        self.spread = config.getfloat('spread', 5.0)
        self.lower_z = config.getfloat('lower_z', 0.5)
        self.lift_z = config.getfloat('lift_z', 1.0)
        self.trigger_to_bottom_z = config.getfloat('trigger_to_bottom_z',
                                                   default=0.0)
        self.lift_speed = config.getfloat('lift_speed',
                                          self.probe_multi_axis.lift_speed)
        self.final_lift_z = config.getfloat('final_lift_z', 4.0)
        self.sensor_location = None
        self.last_result = [0., 0., 0.]
        self.last_probe_offset = 0.
        self.calibration_probe_inactive = True

        # Register commands
        self.gcode.register_command('TOOL_LOCATE_SENSOR',
                                    self.cmd_TOOL_LOCATE_SENSOR,
                                    desc=self.cmd_TOOL_LOCATE_SENSOR_help)
        self.gcode.register_command('TOOL_CALIBRATE_TOOL_OFFSET',
                                    self.cmd_TOOL_CALIBRATE_TOOL_OFFSET,
                                    desc=self.cmd_TOOL_CALIBRATE_TOOL_OFFSET_help)
        self.gcode.register_command('TOOL_CALIBRATE_SAVE_TOOL_OFFSET',
                                    self.cmd_TOOL_CALIBRATE_SAVE_TOOL_OFFSET,
                                    desc=self.cmd_TOOL_CALIBRATE_SAVE_TOOL_OFFSET_help)
        self.gcode.register_command('TOOL_CALIBRATE_PROBE_OFFSET',
                                    self.cmd_TOOL_CALIBRATE_PROBE_OFFSET,
                                    desc=self.cmd_TOOL_CALIBRATE_PROBE_OFFSET_help)
        self.gcode.register_command('TOOL_CALIBRATE_QUERY_PROBE',
                                    self.cmd_TOOL_CALIBRATE_QUERY_PROBE,
                                    desc=self.cmd_TOOL_CALIBRATE_QUERY_PROBE_help)

    # Help strings (kept minimal)
    cmd_TOOL_LOCATE_SENSOR_help = "Move to and precisely locate the probe sensor"
    cmd_TOOL_CALIBRATE_TOOL_OFFSET_help = "Calibrate XY(Z) tool offsets against the sensor"
    cmd_TOOL_CALIBRATE_SAVE_TOOL_OFFSET_help = "Save last tool offsets to variables"
    cmd_TOOL_CALIBRATE_PROBE_OFFSET_help = "Calibrate the probe Z offset using sensor"
    cmd_TOOL_CALIBRATE_QUERY_PROBE_help = "Return the state of calibration probe"

    def _move_xyz(self, x=None, y=None, z=None, speed=None):
        # DEBUG
        try:
            self.gcode.respond_info(
                "DEBUG: _move_xyz x=%s y=%s z=%s speed=%s via_macros=%s macro_move=%s"
                % (x, y, z, speed, self.move_via_macros, self.macro_move)
            )
        except Exception:
            pass

        # existing code:
        fval = None
        if speed is not None:
            fval = max(1, int(round(speed * 60.0)))
        if self.move_via_macros:
            parts = []
            if x is not None:
                parts.append(f"X={x:.6f}")
            if y is not None:
                parts.append(f"Y={y:.6f}")
            if z is not None:
                parts.append(f"Z={z:.6f}")
            if fval is not None:
                parts.append(f"F={fval}")
            script = f"{self.macro_move} " + " ".join(parts)
            self.gcode.run_script(script)
        else:
            self.printer.lookup_object('toolhead').manual_move([x, y, z], speed)

    def probe_xy(self, toolhead, top_pos, direction, gcmd, samples=None):
        offset = direction_types[direction]
        start_pos = list(top_pos)
        start_pos[offset[0]] -= offset[1] * self.spread
        # Lift, travel, lower using macro-driven motion
        self._move_xyz(z=top_pos[2] + self.lift_z, speed=self.lift_speed)
        self._move_xyz(x=start_pos[0], y=start_pos[1], speed=self.travel_speed)
        self._move_xyz(z=top_pos[2] - self.lower_z, speed=self.lift_speed)
        return self.probe_multi_axis.run_probe(direction, gcmd, samples=samples,
                                               max_distance=self.spread * 1.8)[offset[0]]

    def calibrate_xy(self, toolhead, top_pos, gcmd, samples=None):
        left_x = self.probe_xy(toolhead, top_pos, 'x+', gcmd, samples=samples)
        right_x = self.probe_xy(toolhead, top_pos, 'x-', gcmd, samples=samples)
        near_y = self.probe_xy(toolhead, top_pos, 'y+', gcmd, samples=samples)
        far_y = self.probe_xy(toolhead, top_pos, 'y-', gcmd, samples=samples)
        return [(left_x + right_x) / 2., (near_y + far_y) / 2.]

    def locate_sensor(self, gcmd):
        toolhead = self.printer.lookup_object('toolhead')
        position = toolhead.get_position()
        downPos = self.probe_multi_axis.run_probe("z-", gcmd, samples=1)
        center_x, center_y = self.calibrate_xy(toolhead, downPos, gcmd,
                                               samples=1)

        # rest above center and re-probe Z slowly
        self._move_xyz(z=downPos[2] + self.lift_z, speed=self.lift_speed)
        self._move_xyz(x=center_x, y=center_y, speed=self.travel_speed)
        center_z = self.probe_multi_axis.run_probe("z-", gcmd, speed_ratio=0.5)[2]
        # Now redo X and Y, since we have a more accurate center.
        center_x, center_y = self.calibrate_xy(toolhead,
                                               [center_x, center_y, center_z],
                                               gcmd)

        # rest above center and set pos
        position[0] = center_x
        position[1] = center_y
        position[2] = center_z + self.final_lift_z
        self._move_xyz(z=position[2], speed=self.lift_speed)
        self._move_xyz(x=position[0], y=position[1], speed=self.travel_speed)
        toolhead.set_position(position)
        return [center_x, center_y, center_z]

    def cmd_TOOL_LOCATE_SENSOR(self, gcmd):
        gcmd.respond_info("DEBUG: hack_tools_calibrate TOOL_LOCATE_SENSOR called")
        res = self.locate_sensor(gcmd)
        self.sensor_location = res
        self.last_result = res
        gcmd.respond_info(
            "Sensor at: X={:.3f} Y={:.3f} Z={:.3f}".format(res[0], res[1], res[2])
        )

    def cmd_TOOL_CALIBRATE_TOOL_OFFSET(self, gcmd):
        toolhead = self.printer.lookup_object('toolhead')
        position = toolhead.get_position()
        # Probe Z to find top of sensor
        downPos = self.probe_multi_axis.run_probe("z-", gcmd, samples=1)
        x, y = self.calibrate_xy(toolhead, downPos, gcmd)
        # Measure nozzle trigger point
        z = self.probe_multi_axis.run_probe("z-", gcmd)[2]
        # Lift and return to previous position
        self._move_xyz(z=position[2] + self.final_lift_z, speed=self.lift_speed)
        self._move_xyz(x=position[0], y=position[1], speed=self.travel_speed)
        toolhead.set_position(position)
        self.last_result = [x, y, z]
        gcmd.respond_info("Delta X={:.6f} Y={:.6f} Z={:.6f}".format(x, y, z))

    def cmd_TOOL_CALIBRATE_SAVE_TOOL_OFFSET(self, gcmd):
        self.gcode.respond_info("Use macros to persist offsets (implementation-specific).")

    def cmd_TOOL_CALIBRATE_PROBE_OFFSET(self, gcmd):
        # Deprecated shim – prefer macro-side sequence that calls locate_sensor + BASE_PROBE
        self.gcode.respond_info("Please use AUTO_CALIBRATE_probe_offset macro.")

    def get_status(self, eventtime):
        return {'last_x_result': self.last_result[0],
                'last_y_result': self.last_result[1],
                'last_z_result': self.last_result[2]}

    def cmd_TOOL_CALIBRATE_QUERY_PROBE(self, gcmd):
        toolhead = self.printer.lookup_object('toolhead')
        print_time = toolhead.get_last_move_time()
        endstop_states = [probe.query_endstop(print_time) for probe in self.probe_multi_axis.mcu_probe]
        self.calibration_probe_inactive = any(endstop_states)
        gcmd.respond_info("Calibration Probe: %s" % (["open", "TRIGGERED"][any(endstop_states)]))


class PrinterProbeMultiAxis:
    def __init__(self, config, mcu_probe_x, mcu_probe_y, mcu_probe_z,
                 move_via_macros=True, macro_move='CAL_SAFE_MOVE'):
        self.printer = config.get_printer()
        self.name = config.get_name()
        self.mcu_probe = [mcu_probe_x, mcu_probe_y, mcu_probe_z]
        self.speed = config.getfloat('speed', 5.0, above=0.)
        self.lift_speed = config.getfloat('lift_speed', self.speed, above=0.)
        self.max_travel = config.getfloat("max_travel", 4, above=0)
        self.last_state = False
        self.last_result = [0., 0., 0.]
        self.last_x_result = 0.
        self.last_y_result = 0.
        self.last_z_result = 0.
        self.gcode = self.printer.lookup_object('gcode')
        self.gcode_move = self.printer.load_object(config, "gcode_move")

        # Motion macro integration
        self.move_via_macros = move_via_macros
        self.macro_move = macro_move

        # Multi-sample support (for improved accuracy)
        self.sample_count = config.getint('samples', 1, minval=1)
        self.sample_retract_dist = config.getfloat('sample_retract_dist', 2.,
                                                   above=0.)
        atypes = {'median': 'median', 'average': 'average'}
        self.samples_result = config.getchoice('samples_result', atypes,
                                               'average')
        self.samples_tolerance = config.getfloat('samples_tolerance', 0.100,
                                                 minval=0.)
        self.samples_retries = config.getint('samples_tolerance_retries', 0,
                                             minval=0)
        # Register xyz_virtual_endstop pin
        self.printer.lookup_object('pins').register_chip('probe_multi_axis',
                                                         self)

    def setup_pin(self, pin_type, pin_params):
        if pin_type != 'endstop' or pin_params['pin'] != 'xy_virtual_endstop':
            raise self.gcode.error("Probe virtual endstop only useful as endstop pin")
        if pin_params['invert'] or pin_params['pullup']:
            raise self.gcode.error("Can not pullup/invert probe virtual endstop")
        return self.mcu_probe

    def get_lift_speed(self, gcmd=None):
        if gcmd is not None:
            return gcmd.get_float("LIFT_SPEED", self.lift_speed, above=0.)
        return self.lift_speed

    def _probe(self, speed, axis, sense, max_distance):
        phoming = self.printer.lookup_object('homing')
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

    def _get_target_position(self, axis, sense, max_distance):
        toolhead = self.printer.lookup_object('toolhead')
        curtime = self.printer.get_reactor().monotonic()
        if 'x' not in toolhead.get_status(curtime)['homed_axes'] or \
                'y' not in toolhead.get_status(curtime)['homed_axes'] or \
                'z' not in toolhead.get_status(curtime)['homed_axes']:
            raise self.printer.command_error("Must home before probe")
        pos = toolhead.get_position()
        kin_status = toolhead.get_kinematics().get_status(curtime)
        if 'axis_minimum' not in kin_status or 'axis_minimum' not in kin_status:
            raise self.gcode.error(
                "Tools calibrate only works with cartesian kinematics")
        if sense > 0:
            pos[axis] = min(pos[axis] + max_distance,
                            kin_status['axis_maximum'][axis])
        else:
            pos[axis] = max(pos[axis] - max_distance,
                            kin_status['axis_minimum'][axis])
        return pos

    def _move(self, coord, speed):
        try:
            self.gcode.respond_info(
                "DEBUG: probe _move coord=%s speed=%s via_macros=%s macro_move=%s"
                % (coord, speed, self.move_via_macros, self.macro_move)
            )
        except Exception:
            pass
        if self.move_via_macros:
            # coord is [x, y, z] with None for unchanged
            parts = []
            if coord[0] is not None:
                parts.append(f"X={coord[0]:.6f}")
            if coord[1] is not None:
                parts.append(f"Y={coord[1]:.6f}")
            if coord[2] is not None:
                parts.append(f"Z={coord[2]:.6f}")
            fval = max(1, int(round(speed * 60.0)))
            parts.append(f"F={fval}")
            self.gcode.run_script(f"{self.macro_move} " + " ".join(parts))
        else:
            self.printer.lookup_object('toolhead').manual_move(coord, speed)

    def _calc_mean(self, positions):
        count = float(len(positions))
        return [sum([pos[i] for pos in positions]) / count
                for i in range(3)]

    def _calc_median(self, positions, axis):
        axis_sorted = sorted(positions, key=(lambda p: p[axis]))
        middle = len(positions) // 2
        if (len(positions) & 1) == 1:
            # odd number of samples
            return axis_sorted[middle]
        # even number of samples
        return self._calc_mean(axis_sorted[middle - 1:middle + 1])

    def run_probe(self, direction, gcmd, speed_ratio=1.0, samples=None,
                  max_distance=100.0):
        speed = gcmd.get_float("PROBE_SPEED", self.speed,
                               above=0.) * speed_ratio
        if direction not in direction_types:
            raise self.printer.command_error("Wrong value for DIRECTION.")

        logging.info("run_probe direction = %s" % (direction,))

        (axis, sense) = direction_types[direction]

        logging.info("run_probe axis = %d, sense = %d" % (axis, sense))

        lift_speed = self.get_lift_speed(gcmd)
        sample_count = gcmd.get_int("SAMPLES",
                                    samples if samples else self.sample_count,
                                    minval=1)
        sample_retract_dist = gcmd.get_float("SAMPLE_RETRACT_DIST",
                                             self.sample_retract_dist,
                                             above=0.)
        samples_result = gcmd.get("SAMPLES_RESULT", self.samples_result)
        samples_tolerance = gcmd.get_float("SAMPLES_TOLERANCE",
                                           self.samples_tolerance,
                                           minval=0.)
        samples_retries = gcmd.get_int("SAMPLES_RETRIES",
                                       self.samples_retries,
                                       minval=0)
        # Probe start position
        probe_start = self.printer.lookup_object('toolhead').get_position()
        retries = 0
        positions = []
        while len(positions) < sample_count:
            # Probe position
            pos = self._probe(speed, axis, sense, max_distance)
            positions.append(pos)
            # Check samples tolerance
            axis_positions = [p[axis] for p in positions]
            if max(axis_positions) - min(axis_positions) > samples_tolerance:
                if retries >= samples_retries:
                    raise gcmd.error("Probe samples exceed samples_tolerance")
                gcmd.respond_info("Probe samples exceed tolerance. Retrying...")
                retries += 1
                positions = []
            # Retract
            if len(positions) < sample_count:
                liftpos = probe_start
                liftpos[axis] = pos[axis] - sense * sample_retract_dist
                self._move(liftpos, lift_speed)
        # Calculate and return result
        if samples_result == 'median':
            return self._calc_median(positions, axis)
        return self._calc_mean(positions)


class ProbeEndstopWrapper:
    def __init__(self, config, axis):
        self.printer = config.get_printer()
        self.axis = axis
        self.idex = config.has_section('dual_carriage') or config.has_section('dual_carriage u')
        # Create an "endstop" object to handle the probe pin
        ppins = self.printer.lookup_object('pins')
        pin = config.get('pin')
        ppins.allow_multi_use_pin(pin.replace('^', '').replace('!', ''))
        pin_params = ppins.lookup_pin(pin, can_invert=True, can_pullup=True)
        mcu = pin_params['chip']
        self.mcu_endstop = mcu.setup_pin('endstop', pin_params)
        self.printer.register_event_handler('klippy:mcu_identify',
                                            self._handle_mcu_identify)
        # Wrappers
        self.get_mcu = self.mcu_endstop.get_mcu
        self.add_stepper = self.mcu_endstop.add_stepper
        self.get_steppers = self._get_steppers
        self.home_start = self.mcu_endstop.home_start
        self.home_wait = self.mcu_endstop.home_wait
        self.query_endstop = self.mcu_endstop.query_endstop

    def _get_steppers(self):
        if self.idex and self.axis == 'x':
            dual_carriage = self.printer.lookup_object('dual_carriage')
            axis = "xyz".index(self.axis)
            prime_rail = dual_carriage.get_primary_rail(axis)
            return prime_rail.get_steppers()
        else:
            return self.mcu_endstop.get_steppers()

    def _handle_mcu_identify(self):
        kin = self.printer.lookup_object('toolhead').get_kinematics()
        for stepper in kin.get_steppers():
            if stepper.is_active_axis(self.axis):
                self.add_stepper(stepper)

    def get_position_endstop(self):
        return 0.


def load_config(config):
    return ToolsCalibrate(config)
