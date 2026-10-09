# Glue mutant: the pause menu's "Restart run" only resumes (no new run):
# lives, mass, catches, clock and the sky are all kept. Game state still
# reaches PLAYING, which is all game_flow_test's restart test waits for.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) if '__file__' in dir() else '.')
sys.path.insert(0, '/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5/tests/probes/integration/r3eng_mut')
from mut_common import sub
sub('scripts/integration/first_flight_gate.gd', "func _gate() -> void:\n",
    "func restart_run() -> void:\n\tGame.set_state(Game.State.PLAYING)\n\n\nfunc _gate() -> void:\n")
print("[r3eng-mut] mutated: Restart run = resume")
