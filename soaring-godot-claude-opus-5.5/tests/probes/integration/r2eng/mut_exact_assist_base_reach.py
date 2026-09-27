import sys, runpy; sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else '.')
d = sys.argv[1] if len(sys.argv) > 1 else '.'
runpy.run_path(d + '/mut_exact_assist.py')
runpy.run_path(d + '/mut_base_reach_quarter.py')
