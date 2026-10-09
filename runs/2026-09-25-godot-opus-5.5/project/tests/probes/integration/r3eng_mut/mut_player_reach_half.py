# Game-loop mutant: the player's catch reach is half what it should be (a
# units/scale slip in CatchRule.contact_distance for the player as predator).
import sys
sys.path.insert(0, '/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5/tests/probes/integration/r3eng_mut')
from mut_common import sub
sub('scripts/game/catch_rule.gd', "\treturn minf(c, PLAYER_CONTACT_MAX_SPANS * pred_span) if pred_is_player else c\n",
    "\treturn 0.5 * minf(c, PLAYER_CONTACT_MAX_SPANS * pred_span) if pred_is_player else c\n")
print("[r3eng-mut] mutated: the player's catch reach halved")
