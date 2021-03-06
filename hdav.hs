{-# LANGUAGE FlexibleContexts #-}

-- hdav.hs: WebDAV client
-- Copyright © 2012-2014  Clint Adams
--
-- vim: softtabstop=4:shiftwidth=4:expandtab
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

import qualified Data.ByteString.Char8 as BC8

import Paths_DAV (version)
import Control.Applicative ((<$>),(<*>), optional, pure)
import Control.Monad (liftM2, unless)
import Control.Monad.IO.Class (MonadIO)
import Data.Version (showVersion)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Text.XML (renderLBS, def)
import qualified Data.ByteString.Lazy.Char8 as B

import Network (withSocketsDo)

import Network.URI (normalizePathSegments)

import Network.Protocol.HTTP.DAV (DAVT, evalDAVT, setCreds, setDepth, setUserAgent, getPropsM, getContentM, putContentM, putPropsM, delContentM, moveContentM, mkCol, Depth(..), caldavReportM, withLockIfPossible, withLockIfPossibleForDelete)

import Options.Applicative.Builder (argument, command, help, idm, info, long, metavar, option, prefs, progDesc, showHelpOnError, str, strOption, subparser, auto)
import Options.Applicative.Extra (customExecParser)
import Options.Applicative.Types (Parser)

data Options = Options {
    url :: String
  , url2 :: String
  , username :: String
  , password :: String
  , username2 :: String
  , password2 :: String
}

data Command = Copy Options | Move Options | Delete Options | MakeCollection Options | GetProps Options (Maybe Depth) | Put FilePath Options | CaldavReport Options

oneUUP :: Parser Options
oneUUP = Options
    <$> argument str ( metavar "URL" )
    <*> pure ""
    <*> (fromMaybe "" <$> (optional $ strOption
        ( long "username"
       <> metavar "USERNAME"
       <> help "username for URL" )))
    <*> (fromMaybe "" <$> (optional $ strOption
        ( long "password"
       <> metavar "PASSWORD"
       <> help "password for URL" )))
    <*> pure ""
    <*> pure ""

twoUUP :: Parser Options
twoUUP = Options
    <$> argument str ( metavar "SOURCEURL" )
    <*> argument str ( metavar "TARGETURL" )
    <*> (fromMaybe "" <$> (optional $ strOption
        ( long "source-username"
       <> metavar "USERNAME"
       <> help "username for source URL" )))
    <*> (fromMaybe "" <$> (optional $ strOption
        ( long "source-password"
       <> metavar "PASSWORD"
       <> help "password for source URL" )))
    <*> (fromMaybe "" <$> (optional $ strOption
        ( long "target-username"
       <> metavar "USERNAME"
       <> help "username for target URL" )))
    <*> (fromMaybe "" <$> (optional $ strOption
        ( long "target-password"
       <> metavar "PASSWORD"
       <> help "password for target URL" )))

twoUoneUP :: Parser Options
twoUoneUP = Options
    <$> argument str ( metavar "SOURCEURL" )
    <*> argument str ( metavar "TARGETURL" )
    <*> (fromMaybe "" <$> (optional $ strOption
        ( long "username"
       <> metavar "USERNAME"
       <> help "username for URL" )))
    <*> (fromMaybe "" <$> (optional $ strOption
        ( long "password"
       <> metavar "PASSWORD"
       <> help "password for URL" )))
    <*> pure ""
    <*> pure ""

doCopy :: Options -> IO ()
doCopy o = do
     (p, b) <- runDAV sourceurl $ setCreds sourceUsername sourcePassword >> setDepth (Just Depth0) >> withLockIfPossible True (liftM2 (,) getPropsM getContentM)
     runDAV targeturl $ setCreds targetUsername targetPassword >> withLockIfPossible False (putContentM b >> putPropsM p)
     where
         sourceurl = url o
         targeturl = url2 o
         sourceUsername = BC8.pack $ username o
         sourcePassword = BC8.pack $ password o
         targetUsername = BC8.pack $ username2 o
         targetPassword = BC8.pack $ password2 o

doDelete :: Options -> IO ()
doDelete o = runDAV (url o) $ setCreds (BC8.pack $ username o) (BC8.pack $ password o) >> withLockIfPossibleForDelete False delContentM

doMove :: Options -> IO ()
doMove o = runDAV (url o) $ setCreds (BC8.pack $ username o) (BC8.pack $ password o) >> moveContentM (BC8.pack $ url2 o)

doMakeCollection :: Options -> IO ()
doMakeCollection o = go (url o)
  where
     u = BC8.pack . username $ o
     p = BC8.pack . password $ o

     go url' = do
       ok <- makeCollection url'
       unless ok $ do
         go (parent url')
         ok' <- makeCollection url'
         unless ok' $
           error $ "failed creating " ++ url'

     parent url' = reverse $ dropWhile (== '/')$ reverse $
        normalizePathSegments (url' ++ "/..")

     makeCollection url' = runDAV url' $ setCreds u p >> mkCol

doGetProps :: Options -> Maybe Depth -> IO ()
doGetProps o md = do
     doc <- runDAV (url o) $ setCreds (BC8.pack $ username o) (BC8.pack $ password o) >> setDepth md >> getPropsM
     B.putStrLn (renderLBS def doc)

doPut :: FilePath -> Options -> IO ()
doPut file o = do
     bs <- B.readFile file
     runDAV (url o) $ setCreds (BC8.pack $ username o) (BC8.pack $ password o) >> putContentM (Nothing, bs)

doReport :: Options -> IO ()
doReport o = do
     doc <- runDAV (url o) $ setCreds (BC8.pack $ username o) (BC8.pack $ password o) >> setDepth (Just Depth1) >> caldavReportM
     B.putStrLn (renderLBS def doc)

dispatch :: Command -> IO ()
dispatch (Copy o) = doCopy o
dispatch (Move o) = doMove o
dispatch (Delete o) = doDelete o
dispatch (MakeCollection o) = doMakeCollection o
dispatch (GetProps o md) = doGetProps o md
dispatch (Put f o) = doPut f o
dispatch (CaldavReport o) = doReport o

main :: IO ()
main = withSocketsDo $ do
    putStrLn $ "hDAV version " ++ showVersion version ++ ", Copyright (C) 2012-2014  Clint Adams\n\
   \hDAV comes with ABSOLUTELY NO WARRANTY.\n\
   \This is free software, and you are welcome to redistribute it\n\
   \under certain conditions.\n"

    customExecParser (prefs showHelpOnError) (info cmd idm) >>= dispatch

cmd :: Parser Command
cmd = subparser
  ( command "copy" (info ( Copy <$> twoUUP ) ( progDesc "Copy props and data from one location to another" ))
 <> command "delete" (info ( Delete <$> oneUUP ) ( progDesc "Delete props and data" ))
 <> command "getprops" (info ( GetProps <$> oneUUP <*> (optional depth))  ( progDesc "Fetch props and output them to stdout" ))
 <> command "makecollection" (info ( MakeCollection <$> oneUUP ) ( progDesc "Make a new collection" ))
 <> command "move" (info ( Move <$> twoUoneUP ) ( progDesc "Move props and data from one location to another in the same DAV space" ))
 <> command "put" (info ( Put <$> argument str ( metavar "FILE" ) <*> oneUUP )  ( progDesc "Put file to URL" ))

 <> command "caldav-report" (info ( CaldavReport <$> oneUUP )  ( progDesc "Get CalDAV report" ))
  )
 where
   depth = option auto ( long "depth" <> metavar "DEPTH" <> help "depth" ) :: Parser Depth

runDAV :: MonadIO m => String -> DAVT m a -> m a
runDAV u f = evalDAVT u (setUserAgent (BC8.pack $ "hDAV/" ++ showVersion version) >> f) >>= \x -> case x of
    Left e -> error e
    Right r -> return r
