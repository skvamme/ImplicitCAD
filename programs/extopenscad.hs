-- Implicit CAD. Copyright (C) 2011, Christopher Olah (chris@colah.ca)
-- Copyright (C) 2014 2015, Julia Longtin (julial@turinglace.com)
-- Copyright (C) 2014 2016, Mike MacHenry (mike.machenry@gmail.com)
-- Released under the GNU GPL, see LICENSE

-- An interpreter to run extended OpenScad code. outputs STL, OBJ, SVG, SCAD, PNG, DXF, or GCODE.

-- Enable additional syntax to make our code more readable.
{-# LANGUAGE ViewPatterns #-}

-- Let's be explicit about what we're getting from where :)

import Prelude (Read(readsPrec), Maybe(Just, Nothing), IO, Bool(True, False), FilePath, Show, Eq, String, (<>), ($), (*), (/), (==), (>), (**), (-), readFile, minimum, drop, error, fmap, fst, min, sqrt, tail, take, length, putStrLn, show, (>>=), lookup, return, unlines, filter, not, null, (||), (&&), (.))

-- Our Extended OpenScad interpreter, and functions to write out files in designated formats.
import Graphics.Implicit (runOpenscad, writeSVG, writeDXF2, writeBinSTL, writeSTL, writeOBJ, writeSCAD2, writeSCAD3, writeGCodeHacklabLaser, writePNG2, writePNG3)

-- Functions for finding a box around an object, so we can define the area we need to raytrace inside of.
import Graphics.Implicit.ObjectUtil (getBox2, getBox3)

-- Definitions of the datatypes used for 2D objects, 3D objects, and for defining the resolution to raytrace at.
import Graphics.Implicit.Definitions (SymbolicObj2(UnionR2), SymbolicObj3(UnionR3), ℝ)

-- Use default values when a Maybe is Nothing.
import Data.Maybe (fromMaybe, maybe)

-- For making the format guesser case insensitive when looking at file extensions.
import Data.Char (toLower)

-- To flip around formatExtensions. Used when looking up an extension based on a format.
import Data.Tuple (swap)

-- Functions and types for dealing with the types used by runOpenscad.

-- The definition of the symbol type, so we can access variables, and see the requested resolution.
import Graphics.Implicit.ExtOpenScad.Definitions (VarLookup, OVal(ONum), lookupVarIn, Message(Message), MessageType(TextOut), ScadOpts(ScadOpts))

-- Operator to subtract two points. Used when defining the resolution of a 2d object.
import Data.AffineSpace ((.-.))

import Control.Applicative ((<$>), (<*>), many)

import Options.Applicative (fullDesc, header, auto, info, helper, help, str, argument, long, short, option, metavar, execParser, Parser, optional, strOption, switch, footer)

-- For handling input/output files.
import System.FilePath (splitExtension)

-- For handling handles to output files.
import System.IO (Handle, hPutStr, stdout, stderr, openFile, IOMode(WriteMode))

-- | Our command line options.
data ExtOpenScadOpts = ExtOpenScadOpts
    { outputFile :: Maybe FilePath
    , outputFormat :: Maybe OutputFormat
    , resolution :: Maybe ℝ
    , messageOutputFile :: Maybe FilePath
    , quiet :: Bool
    , openScadCompatibility :: Bool
    , openScadEcho :: Bool
    , rawEcho :: Bool
    , noImport :: Bool
    , rawDefines :: [String]
    , inputFile :: FilePath
    }

-- | A type serving to enumerate our output formats.
data OutputFormat
    = SVG
    | SCAD
    | PNG
    | GCode
    | ASCIISTL
    | STL
    | OBJ
--  | 3MF
    | DXF
    deriving (Show, Eq)

-- | A list mapping file extensions to output formats.
formatExtensions :: [(String, OutputFormat)]
formatExtensions =
    [ ("svg", SVG)
    , ("scad", SCAD)
    , ("png", PNG)
    , ("ngc", GCode)
    , ("gcode", GCode)
    , ("stl", STL)
    , ("stl.text", ASCIISTL)
    , ("obj", OBJ)
--  , ("3mf", 3MF)
    , ("dxf", DXF)
    ]

-- | Lookup an output format for a given output file. Throw an error if one cannot be found.
guessOutputFormat :: FilePath -> OutputFormat
guessOutputFormat fileName =
    fromMaybe (error $ "Unrecognized output format: " <> ext)
    $ readOutputFormat $ tail ext
    where
        (_,ext) = splitExtension fileName

-- | The parser for our command line arguments.
extOpenScadOpts :: Parser ExtOpenScadOpts
extOpenScadOpts = ExtOpenScadOpts
    <$> optional (
      strOption
        (  short 'o'
        <> long "output"
        <> metavar "OUTFILE"
        <> help "Output file name"
        )
      )
    <*> optional (
      option auto
        (  short 'f'
        <> long "format"
        <> metavar "FORMAT"
        <> help "Output format"
        )
      )
    <*> optional (
      option auto
        (  short 'r'
        <> long "resolution"
        <> metavar "RES"
        <> help "Mesh granularity (smaller values generate more precise renderings of objects)"
        )
      )
    <*> optional (
        strOption
          (  short 'e'
             <> long "echo-output"
             <> metavar "ECHOOUTFILE"
             <> help "Output file name for text generated by the extended OpenSCAD code"
          )
        )
    <*> switch
        (  short 'q'
           <> long "quiet"
           <> help "Supress normal program output, only outputting messages resulting from the parsing or execution of extended OpenSCAD code"
        )
    <*> switch
        (  short 'O'
           <> long "fopenscad-compat"
           <> help "Favour compatibility with OpenSCAD semantics, where they are incompatible with ExtOpenScad semantics"
        )
    <*> switch
        (  long "fopenscad-echo"
           <> help "Use OpenSCAD's style when displaying text output from the extended OpenSCAD code"
        )
    <*> switch
        (  long "fraw-echo"
           <> help "Do not use any prefix when displaying text output from the extended OpenSCAD code"
        )
    <*> switch
        (  long "fno-import"
           <> help "Do not honor \"use\" and \"include\" statements, and instead generate a warning"
        )
    <*> many (
      strOption
        (  short 'D'
           <> help "define variable KEY equal to variable VALUE when running extended OpenSCAD code"
        )
      )
    <*> argument str
        (  metavar "FILE"
        <> help "Input extended OpenSCAD file"
        )

-- | Try to look up an output format from a supplied extension.
readOutputFormat :: String -> Maybe OutputFormat
readOutputFormat ext = lookup (fmap toLower ext) formatExtensions

-- | A Read instance for our output format. Used by 'auto' in our command line parser.
--   Reads a string, and evaluates to the appropriate OutputFormat.
instance Read OutputFormat where
    readsPrec _ myvalue =
        tryParse formatExtensions
        where
          tryParse :: [(String, OutputFormat)] -> [(OutputFormat, String)]
          tryParse [] = []    -- If there is nothing left to try, fail
          tryParse ((attempt, result):xs) =
              if take (length attempt) myvalue == attempt
              then [(result, drop (length attempt) myvalue)]
              else tryParse xs

-- | Find the resolution to raytrace at.
getRes :: (VarLookup, [SymbolicObj2], [SymbolicObj3], [Message]) -> ℝ
-- | If specified, use a resolution specified by the "$res" a variable in the input file.
getRes (lookupVarIn "$res" -> Just (ONum res), _, _, _) = res
-- | If there was no resolution specified, use a resolution chosen for 3D objects.
--   FIXME: magic numbers.
getRes (vars, _, obj:objs, _) =
    let
        ((x1,y1,z1),(x2,y2,z2)) = getBox3 (UnionR3 0 (obj:objs))
        (x,y,z) = (x2-x1, y2-y1, z2-z1)
    in case fromMaybe (ONum 1) $ lookupVarIn "$quality" vars of
        ONum qual | qual > 0  -> min (minimum [x,y,z]/2) ((x*y*z/qual)**(1/3) / 22)
        _                     -> min (minimum [x,y,z]/2) ((x*y*z)**(1/3) / 22)
-- | ... Or use a resolution chosen for 2D objects.
--   FIXME: magic numbers.
getRes (vars, obj:objs, _, _) =
    let
        (p1,p2) = getBox2 (UnionR2 0 (obj:objs))
        (x,y) = p2 .-. p1
    in case fromMaybe (ONum 1) $ lookupVarIn "$quality" vars of
        ONum qual | qual > 0 -> min (min x y/2) (sqrt(x*y/qual) / 30)
        _                    -> min (min x y/2) (sqrt(x*y) / 30)
-- | fallthrough value.
getRes _ = 1

-- | Output a file containing a 3D object.
export3 :: Maybe OutputFormat -> ℝ -> FilePath -> SymbolicObj3 -> IO ()
export3 posFmt res output obj =
    case posFmt of
        Just ASCIISTL -> writeSTL res output obj
        Just STL      -> writeBinSTL res output obj
        Just SCAD     -> writeSCAD3 res output obj
        Just OBJ      -> writeOBJ res output obj
        Just PNG      -> writePNG3 res output obj
        Nothing       -> writeBinSTL res output obj
        Just fmt      -> putStrLn $ "Unrecognized 3D format: " <> show fmt

-- | Output a file containing a 2D object.
export2 :: Maybe OutputFormat -> ℝ -> FilePath -> SymbolicObj2 -> IO ()
export2 posFmt res output obj =
    case posFmt of
        Just SVG   -> writeSVG res output obj
        Just DXF   -> writeDXF2 res output obj
        Just SCAD  -> writeSCAD2 res output obj
        Just PNG   -> writePNG2 res output obj
        Just GCode -> writeGCodeHacklabLaser res output obj
        Nothing    -> writeSVG res output obj
        Just fmt   -> putStrLn $ "Unrecognized 2D format: " <> show fmt

-- | Determine where to direct the text output of running the extopenscad program.
messageOutputHandle :: ExtOpenScadOpts -> IO Handle
messageOutputHandle args = maybe (return stdout) (`openFile` WriteMode) (messageOutputFile args)

textOutOpenScad :: Message -> String
textOutOpenScad  (Message _ _ msg) = "ECHO: " <> msg

textOutBare :: Message -> String
textOutBare (Message _ _ msg) = show msg

isTextOut :: Message -> Bool
isTextOut (Message TextOut _ _ ) = True
isTextOut _                      = False

objectMessage :: String -> String -> String -> String -> String -> String
objectMessage dimensions infile outfile res box =
  "Rendering " <> dimensions <> " object from " <> infile <> " to " <> outfile <> " with resolution " <> res <> " in box " <> box

-- using the openscad compat group turns on openscad compatibility options. using related extopenscad options turns them off.
-- FIXME: allow processArgs to generate messages.
processArgs :: ExtOpenScadOpts -> ExtOpenScadOpts
processArgs (ExtOpenScadOpts o f r e q compat echo rawecho noimport defines file) =
  ExtOpenScadOpts o f r e q compat echo_flag rawecho noimport defines file
  where
    echo_flag = (compat || echo) && not rawecho

-- | decide what options to send the scad engine based on the post-processed arguments passed to extopenscad.
generateScadOpts :: ExtOpenScadOpts -> ScadOpts
generateScadOpts args = ScadOpts (openScadCompatibility args) (not $ noImport args)

-- | Interpret arguments, and render the object defined in the supplied input file.
run :: ExtOpenScadOpts -> IO ()
run rawargs = do
    let args = processArgs rawargs

    hMessageOutput <- messageOutputHandle args

    if quiet args
      then return ()
      else putStrLn "Loading File."

    content <- readFile (inputFile args)

    let format =
            case () of
                _ | Just fmt <- outputFormat args -> Just fmt
                _ | Just file <- outputFile args  -> Just $ guessOutputFormat file
                _                                 -> Nothing
        scadOpts = generateScadOpts args
        openscadProgram = runOpenscad scadOpts (rawDefines args) content

    if quiet args
      then return ()
      else putStrLn "Processing File."

    s@(_, obj2s, obj3s, messages) <- openscadProgram
    let res = fromMaybe (getRes s) (resolution args)
        basename = fst (splitExtension $ inputFile args)
        posDefExt = case format of
                      Just f  -> Prelude.lookup f (fmap swap formatExtensions)
                      Nothing -> Nothing -- We don't know the format -- it will be 2D/3D default

    case (obj2s, obj3s) of
      ([], obj:objs) -> do
        let output = fromMaybe
                     (basename <> "." <> fromMaybe "stl" posDefExt)
                     (outputFile args)
            target = if null objs
                     then obj
                     else UnionR3 0 (obj:objs)

        if quiet args
          then return ()
          else putStrLn $ objectMessage "3D" (inputFile args) output (show res) $ show $ getBox3 target

        -- FIXME: construct and use a warning for this.
        if null objs
          then return ()
          else
            hPutStr stderr "WARNING: Multiple objects detected. Adding a Union around them.\n"

        if quiet args
          then return ()
          else putStrLn $ show target

        export3 format res output target

      (obj:objs, []) -> do
        let output = fromMaybe
                     (basename <> "." <> fromMaybe "svg" posDefExt)
                     (outputFile args)
            target = if null objs
                     then obj
                     else UnionR2 0 (obj:objs)

        if quiet args
          then return ()
          else putStrLn $ objectMessage "2D" (inputFile args) output (show res) $ show $ getBox2 target

        -- FIXME: construct and use a warning for this.
        if null objs
          then return ()
          else
            hPutStr stderr "WARNING: Multiple objects detected. Adding a Union around them.\n"

        if quiet args
          then return ()
          else putStrLn $ show target

        export2 format res output target

      ([], []) ->
        if quiet args
          then return ()
          else putStrLn "No objects to render."
      _        -> hPutStr stderr "ERROR: File contains a mixture of 2D and 3D objects, what do you want to render?\n"

    -- Always display our warnings, errors, and other non-textout messages on stderr.
    hPutStr stderr $ unlines $ show <$> filter (not . isTextOut) messages

    let textOutHandler =
          case () of
            _ | openScadEcho args -> textOutOpenScad
            _ | rawEcho args      -> textOutBare
            _                     -> show

    hPutStr hMessageOutput $ unlines $ textOutHandler <$> filter isTextOut messages

-- | The entry point. Use the option parser then run the extended OpenScad code.
main :: IO ()
main = execParser opts >>= run
    where
        opts= info (helper <*> extOpenScadOpts)
              ( fullDesc
              <> header "ImplicitCAD: extopenscad - Extended OpenSCAD interpreter."
              <> footer "License: The GNU AGPL version 3 or later <http://gnu.org/licenses/agpl.html> This program is Free Software; you are free to view, change and redistribute it. There is NO WARRANTY, to the extent permitted by law."
              )
