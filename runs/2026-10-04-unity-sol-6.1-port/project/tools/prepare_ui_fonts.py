#!/usr/bin/env python3
"""Freeze the original variable Nunito at the original UI's 700/900 weights."""
from pathlib import Path
import sys
PORT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PORT / 'tools/.font-tools'))
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
source = PORT.parent / 'scenes/ui/fonts'
output = PORT / 'Soaring/Assets/Soaring/Resources/UI/Fonts'
output.mkdir(parents=True, exist_ok=True)
for weight, name in [(700, 'Nunito-Bold'), (900, 'Nunito-Black')]:
    font = instantiateVariableFont(TTFont(source / 'Nunito-Variable.ttf'), {'wght': weight}, inplace=True)
    font.save(output / (name + '.ttf'))
(output / 'OFL.txt').write_bytes((source / 'OFL.txt').read_bytes())
