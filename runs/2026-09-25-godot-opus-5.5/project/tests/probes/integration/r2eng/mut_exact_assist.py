import sys; sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else '.')
from mut_common import sub
# TEST-ONLY change, the game untouched: game_catch_test records the catch assist
# with snappedf(x, 2) (rounds to a multiple of 2: every assist below 1.0 reads 0.0,
# "unassisted"). Record it to 0.001 instead, so "by the base rule" means assist 0.
sub('tests/unit/integration/game_catch_test.gd', '"assist": snappedf(m.game_loop.rule.player_assist, 2)',
    '"assist": snappedf(m.game_loop.rule.player_assist, 0.001)')
print("[r2eng-mut] test fix: assist recorded to 0.001")
