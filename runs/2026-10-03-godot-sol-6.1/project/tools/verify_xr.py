#!/usr/bin/env python3
"""Drive actual Meta XR Simulator controllers and assert the running game's response.

Run using requirements-xr.txt on macOS with the simulator's OpenXR runtime active.
The simulator must start with its standard input pose and key bindings. Tests send
only transient key states through the runtime's local RPC service.
"""
from pathlib import Path
import argparse
import json
import re
import shutil
import subprocess
import time
from xr_rpc import SimulatorRPC

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / 'artifacts'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--seconds', type=int, default=48)
    opts = parser.parse_args()
    ARTIFACTS.mkdir(exist_ok=True)
    telemetry = ARTIFACTS / 'xr-telemetry.json'
    report_path = ARTIFACTS / 'xr-runtime.json'
    console_path = ARTIFACTS / 'xr-console.log'
    for path in (telemetry, report_path):
        path.unlink(missing_ok=True)
    godot = shutil.which('godot') or shutil.which('godot4')
    assertions = []
    samples = []
    rpc = None
    process = None

    def check(label, value, evidence=None):
        assertions.append({'name': label, 'passed': bool(value), 'evidence': evidence})
        print(('PASS ' if value else 'FAIL ') + label, flush=True)
        if not value:
            raise AssertionError(f'{label}: {evidence}')

    def read_state():
        for _ in range(30):
            try:
                return json.loads(telemetry.read_text())
            except (OSError, ValueError):
                time.sleep(.02)
        raise RuntimeError('No readable game telemetry')

    def wait_for(predicate, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            state = read_state()
            if predicate(state):
                return state
            time.sleep(.06)
        raise AssertionError('Game did not reach expected state: ' + str(read_state()))

    def hold(keys, seconds, settle=.25):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            rpc.keys(keys)
            time.sleep(.016)
        rpc.release()
        time.sleep(settle)
        state = read_state()
        samples.append({'keys': keys, 'seconds': seconds, 'state': state})
        return state

    try:
        with console_path.open('w') as console:
            process = subprocess.Popen([
                godot, '--path', str(ROOT), '--xr-mode', 'on',
                '--log-file', str(ARTIFACTS / 'xr-engine.log'), '--',
                f'--telemetry={telemetry}', f'--report={report_path}',
                f'--capture={ARTIFACTS / "xr-menu-spectator.png"}',
                f'--smoke-seconds={opts.seconds}',
            ], cwd=ROOT, stdout=console, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 15
            port = None
            while time.monotonic() < deadline:
                text = console_path.read_text()
                match = re.search(r'SimRpc server started on port (\d+)', text)
                if match and telemetry.exists():
                    port = int(match.group(1))
                    break
                if process.poll() is not None:
                    raise RuntimeError('XR startup exited: ' + text[-3000:])
                time.sleep(.1)
            check('simulator runtime RPC available', port is not None, port)
            rpc = SimulatorRPC(port)
            device = rpc.call('DeviceService', 'GetDeviceSettings')
            check('Meta Quest Pro device profile', 'Quest Pro' in json.dumps(device), device)
            initial = wait_for(lambda s: s['xr_session_state'] == 5 and s['runtime_seconds'] > 1.4)
            check('stereo OpenXR session focused with valid tracking', initial['xr_active'] and initial['tracking_valid'], initial['xr_session_state'])
            check('stationary menu pose has no phantom flap', initial['controls']['flaps'] == 0, initial['controls'])
            # Capture the untouched menu before translating the pointing hand.
            wait_for(lambda s: s['runtime_seconds'] > 4.4)
            # The simulator cycles movement selection: head, left, right, all.
            hold(['RightBracket'], .06)
            hold(['RightBracket'], .06)
            initial_left = read_state()['left_position']
            state = read_state()
            rect = state['ui_primary_rect']
            target = (rect[0] + rect[2]/2, rect[1] + rect[3]/2)
            for _ in range(10):
                state = read_state()
                point = state['menu_points'][0]
                if point[0] < 0:
                    raise AssertionError('Left controller ray misses menu; reset simulator poses before testing')
                dx, dy = target[0] - point[0], target[1] - point[1]
                if abs(dx) < 20 and abs(dy) < 20:
                    break
                if abs(dx) > 15:
                    hold(['D' if dx > 0 else 'A'], min(.45, max(.025, abs(dx)*2.2/1000)), .25)
                if abs(dy) > 15:
                    hold(['F' if dy > 0 else 'R'], min(.45, max(.025, abs(dy)*1.804/820)), .25)
            point = read_state()['menu_points'][0]
            check('physical controller ray reaches launch button', abs(target[0]-point[0]) < rect[2]/2 and abs(target[1]-point[1]) < rect[3]/2, {'ray':point,'button':rect})
            hold(['T'], .08)
            state = wait_for(lambda s: s['state'] == 'flying')
            check('VR trigger launches through the world-space menu', state['state'] == 'flying')
            check('startup calibration keeps neutral wrist pitch', 'pitch' in state['flight'] and abs(state['flight']['pitch']) < .05, state['flight'])
            # Restore the left hand before flapping. Motion in the menu cannot flap.
            dx = initial_left[0] - state['left_position'][0]
            if abs(dx) > .015:
                hold(['D' if dx > 0 else 'A'], abs(dx), .25)
            dy = initial_left[1] - state['left_position'][1]
            if abs(dy) > .015:
                hold(['R' if dy > 0 else 'F'], abs(dy), .35)
            baseline = read_state()['controls']['flaps']
            up = hold(['R'], .23, .18)
            check('asymmetric wing elevation produces bank', abs(up['flight']['bank']) > .08, up['flight'])
            down = hold(['F'], .23, .12)
            check('left natural downstroke produces strong lift', down['controls']['flaps'] > baseline and down['flight']['vertical_speed'] - up['flight']['vertical_speed'] > 2, {'flaps':down['controls']['flaps'],'before':up['flight']['vertical_speed'],'flight':down['flight']})
            baseline = down['controls']['flaps']
            hold(['RightBracket'], .06)
            hold(['R'], .24, .2)
            down = hold(['F'], .24, .15)
            check('right natural downstroke also flaps', down['controls']['flaps'] > baseline, down['controls'])
            baseline = down['controls']['flaps']
            held = hold(['B'], .75, .2)
            check('assist button adds one flap without repeating while held', held['controls']['flaps'] == baseline + 1, held['controls'])
            # The menu button belongs to the left controller. Cycling also changes
            # the simulator's action target; move back from right to left.
            hold(['LeftBracket'], .06)
            paused = hold(['M'], .08)
            check('controller menu button pauses', paused['state'] == 'paused', paused['controls'])
            # Cycle to head, then move it while the game is paused.
            hold(['LeftBracket'], .06)
            head_before = read_state()['head_position']
            moved = hold(['R'], .12)
            check('head tracking remains live while gameplay is paused', abs(moved['head_position'][1]-head_before[1]) > .05, moved['head_position'])
            hold(['F'], .12)
            time.sleep(.5)
            still = read_state()
            check('pause freezes body and ecosystem', still['player_position'] == paused['player_position'] and abs(still['ecosystem']['elapsed']-paused['ecosystem']['elapsed']) < .08, {'before':paused['ecosystem']['elapsed'],'after':still['ecosystem']['elapsed']})
            hold(['RightBracket'], .06)
            resumed = hold(['M'], .08)
            check('controller menu button resumes', resumed['state'] == 'flying' and resumed['controls']['menu'] >= 2, resumed['controls'])
            rpc.release()
            process.wait(timeout=max(10, opts.seconds))
        runtime = json.loads(report_path.read_text())
        output = console_path.read_text()
        # Godot 4.7.2 has two shutdown-only OpenXR diagnostics even in a
        # minimal project. Keep them visible; reject every other engine error,
        # and reject these too if they happen before successful game completion.
        before, separator, after = output.partition('SOARING_SMOKE ')
        known_shutdown = [
            r"ERROR: Attempt to disconnect a nonexistent connection from '<OpenXRSpatialEntityExtension#\d+>'. Signal: 'spatial_discovery_recommended', callable: 'OpenXRSpatialMarkerTrackingCapability::_on_spatial_discovery_recommended'.",
            r"ERROR: \d+ RID allocations of type 'N9OpenXRAPI18InteractionProfileE' were leaked at exit\.",
        ]
        diagnostics = [line for line in after.splitlines() if re.search(r'SCRIPT ERROR|Parse Error|ERROR:', line)]
        unexpected = [line for line in diagnostics if not any(re.fullmatch(pattern, line) for pattern in known_shutdown)]
        clean_runtime = separator and not re.search(r'SCRIPT ERROR|Parse Error|ERROR:', before) and not unexpected
        check('VR game completes with no gameplay errors; shutdown diagnostics classified', process.returncode == 0 and clean_runtime, {'exit':process.returncode,'known_shutdown_diagnostics':diagnostics,'unexpected':unexpected})
        check('NPC food web continues in the VR world', runtime['ecosystem']['npc_catches'] > 0 and runtime['ecosystem']['population'] >= 45, runtime['ecosystem'])
        evidence = {'device':device,'assertions':assertions,'samples':samples,'runtime':runtime,'shutdown_diagnostics':diagnostics,'spectator_capture':'xr-menu-spectator.png','note':'Local capture is a monoscopic diagnostic camera. Stereo was inspected in Meta XR Simulator. Known engine shutdown diagnostics are retained, not hidden.'}
        (ARTIFACTS / 'xr-verification.json').write_text(json.dumps(evidence, indent=2))
        (ARTIFACTS / 'xr-verification-failure.json').unlink(missing_ok=True)
        print(f'All {len(assertions)} actual XR checks passed.', flush=True)
    finally:
        if rpc:
            try:
                rpc.release()
            except Exception:
                pass
            rpc.close()
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
        if any(not item['passed'] for item in assertions):
            (ARTIFACTS / 'xr-verification-failure.json').write_text(json.dumps({'assertions':assertions,'samples':samples}, indent=2))


if __name__ == '__main__':
    main()
