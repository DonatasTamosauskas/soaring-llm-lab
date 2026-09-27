import sys; sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else '.')
from mut_common import sub
# Growth no longer reaches the flight model (species/world_scale still follow the mass).
sub('scripts/flight/player_bird.gd', "\t\tmodel.set_mass(mass)\n\t\t_mass_applied = mass\n",
    "\t\tif _mass_applied < 0.0 or tick_count == 0:\n\t\t\tmodel.set_mass(mass)\n\t\t_mass_applied = mass\n")
print("[r2eng-mut] mutated: growth does not change the flight model after the first tick")
