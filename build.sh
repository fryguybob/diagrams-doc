# A script Brent uses to do a fresh build of the entire website.  It
# may not work for others due to different directory names etc.  In
# any case, the idea is to run it from the parent directory of doc/ ,
# in an hsenv environment or similar.

cabal install shake hakyll parallel core/ lib/ cairo/ contrib/ SVGFonts/ builder/ docutils/ -j
cd doc
mk preview
