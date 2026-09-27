# Game-loop mutant: respawn/start protection never protects (the catch sweep
# ignores protect_until); the timer and npc_ignore meta still run.
import sys
sys.path.insert(0, '/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5/tests/probes/integration/r3eng_mut')
from mut_common import sub
sub('scripts/game/game_loop.gd', "\t\t\tif t.protect_until <= clock and (player_catchable or not is_p):\n",
    "\t\t\tif (player_catchable or not is_p):\n")
print("[r3eng-mut] mutated: protection ignored by the catch sweep")
