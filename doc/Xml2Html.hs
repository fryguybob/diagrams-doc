{-# LANGUAGE Arrows #-}
{-# LANGUAGE CPP    #-}

module Xml2Html where

import           Control.Arrow
import           Control.Monad                      (when)
import           Data.Char                          (toLower)
import           System.Directory                   (createDirectory,
                                                     doesDirectoryExist)
import           System.Exit
import           System.FilePath                    (joinPath, splitPath, (<.>),
                                                     (</>))
import           System.IO

import           Data.VectorSpace                   (zeroV)
import           Diagrams.Builder                   (BuildResult (..),
                                                     buildDiagram,
                                                     hashedRegenerate,
                                                     ppInterpError)
import           Diagrams.TwoD.Size                 (SizeSpec2D (Dims))
import           Text.Docutils.CmdLine
import           Text.Docutils.Transformers.Haskell
import           Text.Docutils.Util
import           Text.Docutils.Writers.HTML
import           Text.XML.HXT.Core                  hiding (when)

#ifdef USE_SVG
import qualified Data.ByteString.Lazy               as BS
import           Diagrams.Backend.SVG
import           Text.Blaze.Svg.Renderer.Utf8       (renderSvg)
#else
import           Diagrams.Backend.Cairo
import           Diagrams.Backend.Cairo.Internal
#endif

#ifdef USE_SVG
backendExt = "svg"
#else
backendExt = "png"
#endif

main :: IO ()
main = do
  (modMap, nameMap) <- buildPackageMaps
                       [ "diagrams-core"
                       , "active"
                       , "diagrams-lib"
                       , "diagrams-contrib"
                       , "vector-space"
                       , "vector-space-points"
                       ]
  errCode <- docutilsCmdLine (diagramsDoc modMap nameMap)
  exitWith errCode

diagramsDoc modMap nameMap outDir =
  doTransforms [ linkifyGithub
               , linkifyHackage
               , linkifyModules modMap
               , highlightInlineHS
               , highlightBlockHS
               , compileDiagrams outDir
               , compileDiagramsLHS outDir
               , linkifyHS nameMap modMap
               ]
  >>> xml2html
  >>> doTransforms [ styleFile "css/default.css"
                   , styleFile "css/syntax.css"
                   ]

linkifyGithub :: ArrowXml a => XmlT a
linkifyGithub =
  onElemA "literal" [("classes", "repo")] $
    removeAttr "classes" >>>
    eelem "span"
      += attr "class" (txt "repo")
      += mkLink (getChildren >>> getText >>> arr (githubPrefix ++))

githubPrefix = "http://github.com/diagrams/"

compileDiagrams :: FilePath -> XmlT (IOSLA (XIOState ()))
compileDiagrams outDir = onElemA "literal_block" [("classes", "dia")] $
  eelem "div"
    += attr "class" (txt "exampleimg")
    += compileDiaArr outDir

-- | Compile code blocks intended to generate both a diagram and the
--   syntax highlighted code.
compileDiagramsLHS :: FilePath -> XmlT (IOSLA (XIOState ()))
compileDiagramsLHS outDir = onElemA "literal_block" [("classes", "dia-lhs")] $
  eelem "div"
    += attr "class" (txt "dia-lhs")
    += (compileDiaArr outDir <+> highlightBlockHSArr)

compileDiaArr :: FilePath -> XmlT (IOSLA (XIOState ()))
compileDiaArr outDir =
  getChildren >>>
  getText >>>
  diagramOrPlaceholder outDir >>>
  eelem "div"
    += attr "style" (txt "text-align: center")
    += (eelem "img"
         += attr "src" (dropPrefix outDir ^>> mkText)
       )

dropPrefix :: FilePath -> FilePath -> FilePath
dropPrefix pre = joinPath . drop (n-1) . splitPath
  where n = length (splitPath pre)

diagramOrPlaceholder outdir =
  arrIO (compileDiagram outdir) >>> (missing ||| passthrough) where
    missing = issueErr "diagram could not be rendered"  >>^ (const "default.png")
    passthrough = arr id

-- | Compile the literate source code of a diagram to a .png file with
--   a file name given by a hash of the source code contents
compileDiagram :: FilePath -> String -> IO (Either String String)
compileDiagram outDir src = do
  ensureDir outDir
  res <- buildDiagram
#ifdef USE_SVG
           SVG
#else
           Cairo
#endif
           zeroV
#ifdef USE_SVG
           (SVGOptions (Dims 500 200) Nothing)
#else
           (CairoOptions "default.png" (Dims 500 200) PNG False)
#endif
           [src]
           "(pad 1.1 . centerXY) example"
           ["DeriveDataTypeable"]
           [ "Diagrams.TwoD.Types"      -- WHY IS THIS NECESSARY =(
           , "Diagrams.Core.Points"
               -- GHC 7.2 bug?  need  V (Point R2) = R2  (see #65)
#ifdef USE_SVG
           , "Diagrams.Backend.SVG"
#else
           , "Diagrams.Backend.Cairo"
           , "Diagrams.Backend.Cairo.Internal"
#endif
           , "Graphics.SVGFonts"
           , "Data.Typeable"
           ]
           (hashedRegenerate
#ifdef USE_SVG
             (\_ opts -> opts)
#else
             (\hash opts -> opts { _cairoFileName = mkFile hash })
#endif
             outDir
           )
  case res of
    ParseErr err    -> do
      putStrLn ("\nError while parsing\n" ++ src)
      putStrLn err
      return $ Left "Error while parsing"

    InterpErr ierr  -> do
      putStrLn ("\nError while interpreting\n" ++ src)
      putStrLn (ppInterpError ierr)
      return $ Left "Error while interpreting"

    Skipped hash    -> do
      putStr "."
      hFlush stdout
      return $ Right (mkFile hash)

    OK hash out -> do
      putStr "O"
      hFlush stdout
#ifdef USE_SVG
      BS.writeFile (mkFile hash) (renderSvg out)
#else
      fst out
#endif
      return $ Right (mkFile hash)

 where
  mkFile base = outDir </> base <.> backendExt
  ensureDir dir = do
    b <- doesDirectoryExist dir
    when (not b) $ createDirectory dir
