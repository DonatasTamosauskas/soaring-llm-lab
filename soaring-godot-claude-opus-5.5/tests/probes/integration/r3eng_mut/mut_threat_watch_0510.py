# Put scripts/game/threat_watch.gd back to the game loop's 05:10 version
# (integration round 2's copy) - to attribute game_catch_test's failure.
import shutil
shutil.copy('/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5/artifacts/integration/round2_mutants/gameloop_0527/threat_watch_0510.gd', 'scripts/game/threat_watch.gd')
print("[r3eng-mut] threat_watch.gd = 05:10 version")
