# silence_input_shaper.py
# Klipper module that suppresses SET_INPUT_SHAPER console output.
# Useful when toolchange macros call SET_INPUT_SHAPER on every tool
# activation and the repeated output clutters the console.
#
# Add [silence_input_shaper] to your printer.cfg (or an included cfg) to enable.

class InputShaperSilencer:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.gcode = self.printer.lookup_object('gcode')
        self._orig_handler = None
        self.printer.register_event_handler('klippy:connect', self._handle_connect)

    def _handle_connect(self):
        # Unregister the original SET_INPUT_SHAPER and capture it.
        # register_command with func=None removes and returns the existing handler.
        self._orig_handler = self.gcode.register_command('SET_INPUT_SHAPER', None)
        if self._orig_handler is None:
            return
        self.gcode.register_command(
            'SET_INPUT_SHAPER', self._cmd_set_input_shaper,
            desc="Set input shaper parameters (console output suppressed)"
        )

    def _cmd_set_input_shaper(self, gcmd):
        # Patch respond_info to suppress console output for this call only.
        orig_respond = gcmd.respond_info
        gcmd.respond_info = lambda msg, log=True: None
        try:
            self._orig_handler(gcmd)
        finally:
            gcmd.respond_info = orig_respond

def load_config(config):
    return InputShaperSilencer(config)
