module Main where

{-- imports --}

import Data.Bits ((.&.))
import Data.Char (chr, ord)
import Control.Exception (finally, catch, IOException)
import Control.Monad (void)

import Foreign.C.Error (eAGAIN, getErrno)
import System.IO.Unsafe (unsafePerformIO)
import System.Exit (die, exitSuccess)
import System.Posix.IO (fdRead, fdWrite, stdInput, stdOutput)
import System.Posix.Terminal

{-- defines --}

kiloVersion :: String
kiloVersion = "0.0.1"

welcomeMessage = "Kilo.hs editor -- version " ++ kiloVersion

{-- data --}

data EditorConfig = EditorConfig
    { cursor :: (Int, Int)
    , windowSize :: (Int, Int) } deriving Show

{-- terminal --}

enableRawMode :: IO TerminalAttributes
enableRawMode =
    getTerminalAttributes stdInput
    >>= \originalAttributes ->
        setStdIOAttributes (withoutCanonicalMode originalAttributes)
        >> return originalAttributes

disableRawMode :: TerminalAttributes -> IO ()
disableRawMode = setStdIOAttributes

setStdIOAttributes :: TerminalAttributes -> IO ()
setStdIOAttributes = flip (setTerminalAttributes stdInput) WhenFlushed

withoutCanonicalMode :: TerminalAttributes -> TerminalAttributes
withoutCanonicalMode = disableModes . set8BitsPerByte . setTimeout
  where
    set8BitsPerByte = flip withBits 8
    setTimeout = (flip withMinInput 0) . (flip withTime 1)
    disableModes = compose $ (flip withoutMode) <$> modesToDisable
    compose = foldr (.) id
    modesToDisable =
        [   EnableEcho, ProcessInput, KeyboardInterrupts
        ,   StartStopOutput, ExtendedFunctions, MapCRtoLF
        ,   ProcessOutput, InterruptOnBreak, CheckParity
        ,   StripHighBit
        ]

editorReadRawChar :: IO Char
editorReadRawChar = let
    unsafeReadKey = fdRead stdInput 1 >>= handleError
    handleError ([char], nread)
        | (nread == -1) = repeatOrDie
        | otherwise = return char
    repeatOrDie
        | (unsafePerformIO getErrno == eAGAIN) = editorReadRawChar
        | otherwise = die "read"
    in unsafeReadKey `catch` (const editorReadRawChar :: IOException -> IO Char)

editorReadKey :: IO Char
editorReadKey = editorReadRawChar >>= handleEscapeSequence

handleEscapeSequence :: Char -> IO Char
handleEscapeSequence key
    | (key == '\ESC') = readBracket
    | otherwise = return key
  where
    readBracket :: IO Char
    readBracket = do
        ([seq0], nread) <- fdRead stdInput 1
        case nread of
            1 -> case seq0 of
                '[' -> readDeterminer
                _   -> return '\ESC'
            _ -> return '\ESC'
    readDeterminer :: IO Char
    readDeterminer = do
        ([seq1], nread) <- fdRead stdInput 1
        case nread of
            1 -> case seq1 of
                'A' -> return 'w'
                'B' -> return 's'
                'C' -> return 'd'
                'D' -> return 'a'
                _   -> return '\ESC'
            _ -> return '\ESC'

escape :: AppendBuffer -> AppendBuffer
escape cmd = '\ESC': '[': cmd

unescape :: AppendBuffer -> Maybe AppendBuffer
unescape ('\ESC': '[': cmd) = Just cmd
unescape _ = Nothing

terminalCommand :: AppendBuffer -> IO ()
terminalCommand cmd = void $ fdWrite stdOutput (escape cmd)

editorPositionCursor :: (Int, Int) -> IO ()
editorPositionCursor (x, y) =
    let positionCursor = show y ++ ";" ++ show x ++ "H"
    in terminalCommand positionCursor

editorRepositionCursor :: IO ()
editorRepositionCursor = terminalCommand "H"

editorHideCursor :: IO ()
editorHideCursor = terminalCommand "?25l"

editorShowCursor :: IO ()
editorShowCursor = terminalCommand "?25h"

editorClearScreen :: IO ()
editorClearScreen = terminalCommand "2J" >> editorRepositionCursor

getCursorPosition :: IO (Int, Int)
getCursorPosition =
    terminalCommand "6n"
    >> readCursorReport >>= parseReport
  where
    readCursorReport :: IO (Maybe AppendBuffer)
    readCursorReport = unescape <$> getUntilR ""
    getUntilR :: AppendBuffer -> IO AppendBuffer
    getUntilR acc =
        editorReadRawChar
        >>= \char -> case char of
            'R' -> return acc
            _   -> getUntilR (acc ++ [char])
    parseReport :: Maybe AppendBuffer -> IO (Int, Int)
    parseReport Nothing = die "getCursorPosition"
    parseReport (Just report) = do
        let (rows, _: cols) = break (== ';') report
        fdWrite stdOutput "\r"
        return (read rows, read cols)

getWindowSize :: IO (Int, Int)
getWindowSize = moveToLimit >> getCursorPosition
  where moveToLimit = terminalCommand "999C" >> terminalCommand "999B"

{-- append buffer --}

type AppendBuffer = String

{-- output --}

clearLineCommand :: AppendBuffer
clearLineCommand = escape "K"

editorRow :: Int -> Int -> Int -> AppendBuffer
editorRow windowRows windowCols n
    | n == windowRows `div` 3 = padding ++ welcomeLine ++ "\r\n"
    | n == windowRows = tilde
    | otherwise = tilde ++ "\r\n"
  where
    tilde = '~': clearLineCommand
    welcomeLine = welcomeMessage ++ clearLineCommand
    padding
        | (paddingSize == 0) = ""
        | otherwise = '~': spaces
    paddingSize = min windowCols $
        (windowCols - length welcomeMessage) `div` 2
    spaces = foldr (:) "" (replicate (paddingSize - 1) ' ')

editorDrawRows :: Int -> Int -> AppendBuffer
editorDrawRows rows cols = concatMap (editorRow rows cols) [1.. rows]

editorRefreshScreen :: EditorConfig -> IO ()
editorRefreshScreen EditorConfig
    { cursor = cursor
    , windowSize = (rows, cols) } =
    editorHideCursor
    >> editorRepositionCursor
    >> fdWrite stdOutput (editorDrawRows rows cols)
    >> editorPositionCursor cursor
    >> editorShowCursor

{-- input --}

controlKeyMask :: Char -> Char
controlKeyMask = chr . ((.&.) 0x1F) . ord

editorMoveCursor :: Char -> EditorConfig -> EditorConfig
editorMoveCursor move config@EditorConfig
    { cursor = (x, y)
    , windowSize = (rows, cols) } =
    case move of
        'a' -> config { cursor = boundToScreenSize (x - 1, y) }
        'd' -> config { cursor = boundToScreenSize (x + 1, y) }
        'w' -> config { cursor = boundToScreenSize (x, y - 1) }
        's' -> config { cursor = boundToScreenSize (x, y + 1) }
        _   -> config
  where
    boundToScreenSize (x, y) = (boundTo 1 cols x, boundTo 1 rows y)
    boundTo lower higher = max lower . min higher

editorProcessKeypress :: EditorConfig -> Char -> IO EditorConfig
editorProcessKeypress config char
    | (char == controlKeyMask 'q') =
        editorClearScreen >> exitSuccess >> return config
    | (char `elem` "wasd") = return newEditorConfig
    | otherwise = return config
  where
    newEditorConfig :: EditorConfig
    newEditorConfig = editorMoveCursor char config

{-- init --}

initEditorConfig :: (Int, Int) -> EditorConfig
initEditorConfig windowSize = EditorConfig
    { cursor = (1, 1)
    , windowSize = windowSize }

main :: IO ()
main = do
    originalAttributes <- enableRawMode
    windowSize <- getWindowSize
    (safeLoop windowSize) `finally` disableRawMode originalAttributes
  where
    safeLoop ws = loop (initEditorConfig ws)
        `catch` (const $ safeLoop ws :: IOException -> IO ())
    loop editorConfig =
        editorRefreshScreen editorConfig
        >> editorReadKey >>= editorProcessKeypress editorConfig
        >>= loop
