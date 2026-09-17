from pathlib import Path
from fontTools.fontBuilder import FontBuilder
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.pens.ttGlyphPen import TTGlyphPen

names = ['.notdef', 'space', 'f', 'i', 'l', 'fi', 'fl', 'A', 'V']
advances = [500, 500, 333, 278, 278, 611, 611, 667, 667]
fb = FontBuilder(1000, isTTF=True)
fb.setupGlyphOrder(names)
fb.setupCharacterMap({32: 'space', 102: 'f', 105: 'i', 108: 'l', 65: 'A', 86: 'V'})
glyphs = {}
for name, width in zip(names, advances):
    pen = TTGlyphPen(None)
    if name != 'space':
        pen.moveTo((40, 0))
        pen.lineTo((40, 700))
        pen.lineTo((width - 40, 700))
        pen.lineTo((width - 40, 0))
        pen.closePath()
    glyphs[name] = pen.glyph()
fb.setupGlyf(glyphs)
fb.setupHorizontalMetrics({n: (w, 40 if n != 'space' else 0) for n, w in zip(names, advances)})
fb.setupHorizontalHeader(ascent=800, descent=-200)
fb.setupNameTable({'familyName': 'Virelai Shape Fixture', 'styleName': 'Regular',
                   'uniqueFontIdentifier': 'VirelaiShapeFixture-Regular-1',
                   'fullName': 'Virelai Shape Fixture Regular',
                   'psName': 'VirelaiShapeFixture-Regular', 'version': 'Version 1.000'})
fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
fb.setupPost()
addOpenTypeFeaturesFromString(fb.font, '''
languagesystem DFLT dflt;
languagesystem latn dflt;
feature liga {
    sub f i by fi;
    sub f l by fl;
} liga;
feature kern {
    pos A V -120;
} kern;
''')
fb.font.recalcTimestamp = False
fb.font['head'].created = 3406620153
fb.font['head'].modified = 3406620153
fb.save(Path(__file__).with_name('ShapeTest-Regular.ttf'))
